package devrunner

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestBenchmarkGoRowsRequireEveryRepetitionAndCorrectUnits(t *testing.T) {
	var complete strings.Builder
	for _, name := range []string{"BenchmarkGatewayInspect", "BenchmarkGatewayInspectReconnect", "BenchmarkGatewayAuthorityPublish"} {
		fmt.Fprintf(&complete, "%s-12\n--- BENCH: %s-12\n", name, name)
		for range 3 {
			fmt.Fprintf(&complete, "%s-12 100 123.5 ns/op 24 B/op 2 allocs/op\n", name)
		}
	}
	valid := complete.String()
	for _, tc := range []struct {
		name, output string
		accepted     bool
	}{
		{"complete", valid, true},
		{"one repetition missing", strings.Replace(valid, "BenchmarkGatewayInspect-12 100 123.5 ns/op 24 B/op 2 allocs/op\n", "", 1), false},
		{"extra duplicate", valid + "BenchmarkGatewayInspect-12 100 123.5 ns/op 24 B/op 2 allocs/op\n", false},
		{"wrong unit", strings.Replace(valid, "ns/op", "ms/op", 1), false},
		{"wrong CPU count", strings.Replace(valid, "-12 100", "-1 100", 1), false},
		{"zero iterations", strings.Replace(valid, "100 123.5", "0 123.5", 1), false},
		{"nonfinite latency", strings.Replace(valid, "123.5 ns/op", "NaN ns/op", 1), false},
		{"negative allocation", strings.Replace(valid, "24 B/op", "-1 B/op", 1), false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "bench.log")
			if err := os.WriteFile(path, []byte(tc.output), 0600); err != nil {
				t.Fatal(err)
			}
			rows, err := readGoBenchmarks(path, 12)
			if (err == nil) != tc.accepted {
				t.Fatal("incorrect measurement admission", err)
			}
			if tc.accepted && len(rows) != 9 {
				t.Fatal("a measured row was lost")
			}
		})
	}
}
