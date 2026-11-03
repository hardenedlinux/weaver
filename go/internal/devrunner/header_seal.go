package devrunner

import (
	"bufio"
	"bytes"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"strings"
)

type HeaderSealSample struct {
	Block     int                 `json:"block"`
	Slot      int                 `json:"slot"`
	Delayed   bool                `json:"delayed"`
	Optimized bool                `json:"optimized"`
	CPUs      int                 `json:"cpus"`
	Wall      uint64              `json:"wall_ns"`
	Held      uint64              `json:"held"`
	Events    int                 `json:"events"`
	Calls     int                 `json:"calls"`
	Timings   *TransactionTimings `json:"timings"`
}
type HeaderSealEvidence struct {
	Image   string             `json:"image"`
	Samples []HeaderSealSample `json:"samples"`
}

func ReadHeaderSealEvidence(input io.Reader, cpus int) (*HeaderSealEvidence, error) {
	result := &HeaderSealEvidence{}
	scan := bufio.NewScanner(input)
	for scan.Scan() {
		line := strings.TrimSpace(scan.Text())
		if index := strings.Index(line, "weaver-header-seal-image "); index >= 0 {
			fields := strings.Fields(line[index:])
			if len(fields) != 3 || fields[2] != "profile=release" || !strings.HasPrefix(fields[1], "sha256=") || result.Image != "" {
				return nil, fmt.Errorf("invalid header-seal image")
			}
			value := strings.TrimPrefix(fields[1], "sha256=")
			digest, err := hex.DecodeString(value)
			if err != nil || len(digest) != 32 {
				return nil, fmt.Errorf("invalid header-seal digest")
			}
			result.Image = value
		}
		if index := strings.Index(line, "weaver-header-seal {"); index >= 0 {
			var row HeaderSealSample
			decoder := json.NewDecoder(bytes.NewBufferString(line[index+len("weaver-header-seal "):]))
			decoder.DisallowUnknownFields()
			if err := decoder.Decode(&row); err != nil {
				return nil, err
			}
			if err := decoder.Decode(&struct{}{}); err != io.EOF {
				return nil, fmt.Errorf("trailing header-seal data")
			}
			n := len(result.Samples)
			if n >= 24 || row.Block != n/4 || row.Slot != n%4 || row.Delayed != (n%4 == 1 || n%4 == 2) || !row.Optimized || row.CPUs != cpus || row.Wall == 0 || row.Held != 4 || row.Events != 3 || row.Calls != n+1 || row.Timings == nil {
				return nil, fmt.Errorf("invalid header-seal coordinates/exposure at %d", n)
			}
			timing := row.Timings
			if timing.ProviderRequest.Attempts != 1 || timing.ProviderQueue.Attempts != 3 || timing.Commit.Attempts == 0 || timing.Rollback.Attempts != 0 || timing.ProviderRequest.Nanos == 0 || timing.TransactionHold.Nanos < timing.ProviderRequest.Nanos || row.Wall < timing.TransactionHold.Nanos {
				return nil, fmt.Errorf("invalid header-seal timing scope")
			}
			result.Samples = append(result.Samples, row)
		}
	}
	if err := scan.Err(); err != nil {
		return nil, err
	}
	if result.Image == "" || len(result.Samples) != 24 {
		return nil, fmt.Errorf("incomplete header-seal pair")
	}
	return result, nil
}
