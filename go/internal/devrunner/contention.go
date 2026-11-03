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
	OwnerGateWait    TimingSample `json:"owner_gate_wait"`
	DomainKeys       TimingSample `json:"domain_keys"`
	DomainWait       TimingSample `json:"domain_wait"`
	TransactionBegin TimingSample `json:"transaction_begin"`
	OwnerGateHold    TimingSample `json:"owner_gate_hold"`
	DomainHold       TimingSample `json:"domain_hold"`
	TransactionHold  TimingSample `json:"transaction_hold"`
	Commit           TimingSample `json:"commit"`
	Rollback         TimingSample `json:"rollback"`
	ProviderRequest  TimingSample `json:"provider_request"`
	ProviderQueue    TimingSample `json:"provider_queue"`
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
				if publication && i == 1 {
					attempts = 1
					requests = 0
				}
				if timing.TransactionBegin.Attempts != attempts || timing.Commit.Attempts != attempts || timing.TransactionHold.Attempts != attempts || timing.ProviderRequest.Attempts != requests || timing.ProviderQueue.Attempts != 0 || timing.Rollback.Attempts != 0 || timing.TransactionHold.Nanos < timing.ProviderRequest.Nanos {
					return nil, fmt.Errorf("invalid deciding-scope observation")
				}
				if row.Profile == "wal-writer" {
					if timing.DomainWait.Attempts != 0 || timing.OwnerGateWait.Attempts != 0 {
						return nil, fmt.Errorf("WAL observations claim MVCC locks")
					}
				} else {
					if timing.OwnerGateWait.Attempts != attempts || timing.OwnerGateHold.Attempts != attempts {
						return nil, fmt.Errorf("missing publication gate observation")
					}
					domains := attempts
					if publication && i == 1 {
						domains = 0
					}
					if timing.DomainWait.Attempts != domains || timing.DomainHold.Attempts != domains || timing.DomainKeys.Attempts != domains {
						return nil, fmt.Errorf("missing shared-domain observation")
					}
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
