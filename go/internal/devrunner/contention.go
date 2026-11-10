// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package devrunner

import (
	"bufio"
	"bytes"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"
)

type TimingSample struct {
	Attempts uint64 `json:"attempts"`
	Nanos    uint64 `json:"nanos"`
}

// Missing elapsed data is not a zero-wait observation.
func (sample *TimingSample) UnmarshalJSON(data []byte) error {
	var fields struct {
		Attempts *uint64 `json:"attempts"`
		Nanos    *uint64 `json:"nanos"`
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&fields); err != nil {
		return err
	}
	if fields.Attempts == nil || fields.Nanos == nil {
		return fmt.Errorf("incomplete timing observation")
	}
	sample.Attempts = *fields.Attempts
	sample.Nanos = *fields.Nanos
	return nil
}

type TransactionTimings struct {
	OwnerGateWait              TimingSample  `json:"owner_gate_wait"`
	DomainKeys                 TimingSample  `json:"domain_keys"`
	DomainWait                 TimingSample  `json:"domain_wait"`
	AuthoritySpan              TimingSample  `json:"authority_span"`
	TransactionBegin           TimingSample  `json:"transaction_begin"`
	TransactionBeginPoll       *TimingSample `json:"transaction_begin_poll,omitempty"`
	TransactionBeginCPU        *TimingSample `json:"transaction_begin_cpu,omitempty"`
	TransactionBeginPrepare    *TimingSample `json:"transaction_begin_prepare,omitempty"`
	TransactionBeginPrepareCPU *TimingSample `json:"transaction_begin_prepare_cpu,omitempty"`
	TransactionBeginPending    *uint64       `json:"transaction_begin_pending,omitempty"`
	OwnerGateHold              TimingSample  `json:"owner_gate_hold"`
	DomainHold                 TimingSample  `json:"domain_hold"`
	TransactionHold            TimingSample  `json:"transaction_hold"`
	Commit                     TimingSample  `json:"commit"`
	CommitPoll                 *TimingSample `json:"commit_poll,omitempty"`
	CommitCPU                  *TimingSample `json:"commit_cpu,omitempty"`
	CommitSync                 *TimingSample `json:"commit_sync,omitempty"`
	CommitPending              *uint64       `json:"commit_pending,omitempty"`
	Rollback                   TimingSample  `json:"rollback"`
	ProviderOAuthPrepare       TimingSample  `json:"provider_oauth_prepare"`
	ProviderOAuthCheck         TimingSample  `json:"provider_oauth_check"`
	ProviderDomain             TimingSample  `json:"provider_domain"`
	ProviderDomainPrepare      TimingSample  `json:"provider_domain_prepare"`
	ProviderPending            TimingSample  `json:"provider_pending"`
	ProviderReview             TimingSample  `json:"provider_review"`
	ProviderBirth              TimingSample  `json:"provider_birth"`
	ProviderPublicationPrepare TimingSample  `json:"provider_publication_prepare"`
	ProviderProfile            TimingSample  `json:"provider_profile"`
	ProviderClaim              TimingSample  `json:"provider_claim"`
	ProviderHistory            TimingSample  `json:"provider_history"`
	ProviderManifest           TimingSample  `json:"provider_manifest"`
	ProviderOriginal           TimingSample  `json:"provider_original"`
	ProviderOriginalPrepare    TimingSample  `json:"provider_original_prepare"`
	ProviderCedar              TimingSample  `json:"provider_cedar"`
	ProviderRequest            TimingSample  `json:"provider_request"`
	ProviderQueue              TimingSample  `json:"provider_queue"`
}
type ContentionObservation struct {
	First  TransactionTimings `json:"first"`
	Second TransactionTimings `json:"second"`
}
type ContentionSample struct {
	Profile     string                `json:"profile"`
	Optimized   bool                  `json:"optimized"`
	Block       int                   `json:"block"`
	Slot        int                   `json:"slot"`
	Contended   bool                  `json:"contended"`
	Observation ContentionObservation `json:"observation"`
}
type ContentionEvidence struct {
	ImageSHA256 string             `json:"imageSha256"`
	Samples     []ContentionSample `json:"samples"`
}

var contentionProfiles = []string{"wal-writer", "mvcc-disjoint", "mvcc-shared-budget", "mvcc-shared-history", "mvcc-publication"}

// All 120 ordered observations and their single immutable image are mandatory.
// Durations overlap and are statistical observations, never execution evidence.
func ReadContentionEvidence(input io.Reader) (*ContentionEvidence, error) {
	result := &ContentionEvidence{}
	scan := bufio.NewScanner(input)
	images := 0
	for scan.Scan() {
		line := scan.Text()
		if index := strings.Index(line, "weaver-contention-image "); index >= 0 {
			fields := strings.Fields(line[index:])
			if len(fields) != 3 || !strings.HasPrefix(fields[1], "sha256=") || fields[2] != "profile=release" {
				return nil, fmt.Errorf("invalid contention image profile")
			}
			result.ImageSHA256 = strings.TrimPrefix(fields[1], "sha256=")
			hash, err := hex.DecodeString(result.ImageSHA256)
			if err != nil || len(hash) != 32 {
				return nil, fmt.Errorf("invalid contention image identity")
			}
			images++
		}
		if index := strings.Index(line, "weaver-contention {"); index >= 0 {
			var row ContentionSample
			decoder := json.NewDecoder(strings.NewReader(line[index+len("weaver-contention "):]))
			decoder.DisallowUnknownFields()
			if err := decoder.Decode(&row); err != nil {
				return nil, err
			}
			if err := decoder.Decode(&struct{}{}); err != io.EOF {
				return nil, fmt.Errorf("contention row has trailing data")
			}
			n := len(result.Samples)
			if n >= 120 || row.Profile != contentionProfiles[n/24] || row.Block != (n%24)/4 || row.Slot != n%4 || row.Contended != (n%4 == 1 || n%4 == 2) || !row.Optimized {
				return nil, fmt.Errorf("invalid contention coordinates at %d", n)
			}
			publication := row.Profile == "mvcc-publication"
			for i, timing := range []TransactionTimings{row.Observation.First, row.Observation.Second} {
				attempts := uint64(2)
				requests := uint64(1)
				global := publication && i == 1
				if global {
					attempts = 1
					requests = 0
				}
				if timing.TransactionBegin.Attempts != attempts || timing.Commit.Attempts != attempts || timing.TransactionHold.Attempts != attempts || timing.AuthoritySpan.Attempts != attempts || timing.ProviderRequest.Attempts != requests || timing.ProviderQueue.Attempts != 0 || timing.Rollback.Attempts != 0 || timing.TransactionHold.Nanos < timing.ProviderRequest.Nanos || timing.AuthoritySpan.Nanos < timing.TransactionHold.Nanos {
					return nil, fmt.Errorf("invalid deciding-scope observation")
				}
				// The MVCC scheduler grants one scope per transaction.
				// Publication takes the global scope, provider sends take
				// domain scopes, and WAL takes neither.
				var owners, domains uint64
				if global {
					owners = attempts
				} else if row.Profile != "wal-writer" {
					domains = attempts
				}
				if timing.OwnerGateWait.Attempts != owners || timing.OwnerGateHold.Attempts != owners {
					return nil, fmt.Errorf("invalid publication gate observation")
				}
				if timing.DomainWait.Attempts != domains || timing.DomainHold.Attempts != domains || timing.DomainKeys.Attempts != domains {
					return nil, fmt.Errorf("invalid shared-domain observation")
				}
			}
			result.Samples = append(result.Samples, row)
		}
	}
	if err := scan.Err(); err != nil {
		return nil, err
	}
	if images != 1 || len(result.Samples) != 120 {
		return nil, fmt.Errorf("incomplete contention experiment: images=%d samples=%d", images, len(result.Samples))
	}
	return result, nil
}
func readContentionEvidence(path string) (*ContentionEvidence, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return ReadContentionEvidence(bytes.NewReader(data))
}
