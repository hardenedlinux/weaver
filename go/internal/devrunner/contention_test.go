package devrunner

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math/rand"
	"strings"
	"testing"
	"testing/quick"
)

func contentionFixture(t *testing.T) []ContentionSample {
	t.Helper()
	var rows []ContentionSample
	for _, profile := range contentionProfiles {
		for block := 0; block < 6; block++ {
			for slot := 0; slot < 4; slot++ {
				timing := TransactionTimings{TransactionBegin: TimingSample{Attempts: 2, Nanos: 1}, TransactionHold: TimingSample{Attempts: 2, Nanos: 2}, Commit: TimingSample{Attempts: 2, Nanos: 1}, ProviderRequest: TimingSample{Attempts: 1, Nanos: 1}}
				if profile != "wal-writer" {
					timing.OwnerGateWait.Attempts = 2
					timing.OwnerGateHold.Attempts = 2
					timing.DomainWait.Attempts = 2
					timing.DomainKeys.Attempts = 2
					timing.DomainHold.Attempts = 2
				}
				second := timing
				if profile == "mvcc-publication" {
					second = TransactionTimings{OwnerGateWait: TimingSample{Attempts: 1}, OwnerGateHold: TimingSample{Attempts: 1}, TransactionBegin: TimingSample{Attempts: 1}, TransactionHold: TimingSample{Attempts: 1}, Commit: TimingSample{Attempts: 1}}
				}
				rows = append(rows, ContentionSample{Profile: profile, Optimized: true, Block: block, Slot: slot, Contended: slot == 1 || slot == 2, Observation: ContentionObservation{First: timing, Second: second}})
			}
		}
	}
	return rows
}
func contentionLog(t *testing.T, rows []ContentionSample) string {
	t.Helper()
	var out bytes.Buffer
	fmt.Fprintf(&out, "weaver-contention-image sha256=%s profile=release\n", strings.Repeat("a", 64))
	for _, row := range rows {
		data, err := json.Marshal(row)
		if err != nil {
			t.Fatal(err)
		}
		fmt.Fprintf(&out, "weaver-contention %s\n", data)
	}
	return out.String()
}
func TestContentionEvidenceRejectsPartialReorderedOrDebugObservations(t *testing.T) {
	original := contentionFixture(t)
	if _, err := ReadContentionEvidence(strings.NewReader(contentionLog(t, original))); err != nil {
		t.Fatal(err)
	}
	property := func(raw uint8, fault uint8) bool {
		rows := append([]ContentionSample(nil), original...)
		index := int(raw) % len(rows)
		switch fault % 5 {
		case 0:
			rows = append(rows[:index], rows[index+1:]...)
		case 1:
			rows[index].Optimized = false
		case 2:
			rows[index].Observation.First.ProviderRequest.Attempts = 0
		case 3:
			rows[index].Slot = 99
		case 4:
			rows = append(rows, rows[index])
		}
		_, err := ReadContentionEvidence(strings.NewReader(contentionLog(t, rows)))
		return err != nil
	}
	if err := quick.Check(property, &quick.Config{MaxCount: 64, Rand: rand.New(rand.NewSource(293))}); err != nil {
		t.Fatal(err)
	}
	for _, bad := range []string{
		strings.Replace(contentionLog(t, original), `,"nanos":0`, "", 1),
		strings.Replace(contentionLog(t, original), "profile=release", "profile=dev", 1),
		strings.Replace(contentionLog(t, original), "weaver-contention-image", "missing-image", 1),
		contentionLog(t, original) + "weaver-contention-image sha256=" + strings.Repeat("a", 64) + " profile=release\n",
	} {
		if _, err := ReadContentionEvidence(strings.NewReader(bad)); err == nil {
			t.Fatal("invalid image evidence admitted")
		}
	}
}
