package devrunner

import (
	"encoding/hex"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"runtime"
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

// The Go fuzz engine owns corpus generation, coverage, shrinking and replay.
// The oracle is the typed data used to construct the log, not another parser.
func FuzzBenchmarkGoRowsPreserveMeasurements(f *testing.F) {
	f.Add(uint64(100), float64(123.5), uint64(24), uint64(2), uint8(0), []byte{0, 1, 2})
	f.Add(uint64(1), float64(0.25), uint64(0), uint64(0), uint8(6), []byte{8, 7, 6})
	f.Add(uint64(0), float64(1), uint64(0), uint64(0), uint8(1), []byte{})
	f.Fuzz(func(t *testing.T, iterations uint64, latency float64, allocated, allocs uint64, mutation uint8, order []byte) {
		cores := runtime.NumCPU()
		var expected []GoBenchmark
		for _, name := range []string{"BenchmarkGatewayInspect", "BenchmarkGatewayInspectReconnect", "BenchmarkGatewayAuthorityPublish"} {
			for repetition := range 3 {
				expected = append(expected, GoBenchmark{name, cores, iterations, latency, allocated ^ uint64(repetition), allocs ^ uint64(repetition+3)})
			}
		}
		// Input bytes define a bounded permutation; the framework can shrink it.
		if len(order) > 32 {
			order = order[:32]
		}
		for i, v := range order {
			a := i % len(expected)
			b := int(v) % len(expected)
			expected[a], expected[b] = expected[b], expected[a]
		}
		var lines []string
		for _, row := range expected {
			lines = append(lines, fmt.Sprintf("%s-%d %d %g ns/op %d B/op %d allocs/op\n", row.Name, row.CPUs, row.Iterations, row.NanosecondsPerOp, row.BytesPerOp, row.AllocsPerOp))
		}
		want := iterations > 0 && latency > 0 && !math.IsNaN(latency) && !math.IsInf(latency, 0)
		switch mutation % 8 {
		case 0:
		case 1:
			lines = lines[1:]
			want = false
		case 2:
			lines = append(lines, lines[0])
			want = false
		case 3:
			lines[0] = strings.Replace(lines[0], "ns/op", "ms/op", 1)
			want = false
		case 4:
			lines[0] = strings.Replace(lines[0], fmt.Sprintf("-%d ", cores), fmt.Sprintf("-%d ", cores+1), 1)
			want = false
		case 5:
			lines[0] = strings.Replace(lines[0], fmt.Sprintf(" %g ns/op", latency), " NaN ns/op", 1)
			want = false
		case 6:
			// Valid rows survive a fixture log longer than the retention tail.
			lines = append(lines, strings.Repeat("fixture "+hex.EncodeToString(order)+" completed\n", 512))
		case 7:
			lines[0] = strings.Replace(lines[0], expected[0].Name, "BenchmarkUnregistered", 1)
			want = false
		}
		path := filepath.Join(t.TempDir(), "measurement.log")
		if err := os.WriteFile(path, []byte(strings.Join(lines, "")), 0600); err != nil {
			t.Fatal(err)
		}
		actual, err := readGoBenchmarks(path, cores)
		if (err == nil) != want {
			t.Fatalf("measurement property mismatch: mutation=%d error=%v", mutation%8, err)
		}
		if !want {
			return
		}
		if len(actual) != len(expected) {
			t.Fatal("a complete measurement was lost")
		}
		for i, row := range actual {
			if row != expected[i] {
				t.Fatalf("typed measurement changed at %d: got %+v want %+v", i, row, expected[i])
			}
		}
	})
}
