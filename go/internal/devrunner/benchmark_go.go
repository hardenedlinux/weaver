package devrunner

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
	"strings"
)

// Keep every measured RPC row independently of verbose fixture logs. These
// latency/allocation values describe the Go client and selected service build;
// they are not per-request tail latency or Rust allocation measurements.
type GoBenchmark struct {
	Name             string  `json:"name"`
	CPUs             int     `json:"cpus"`
	Iterations       uint64  `json:"iterations"`
	NanosecondsPerOp float64 `json:"nanosecondsPerOp"`
	BytesPerOp       uint64  `json:"bytesPerOp"`
	AllocsPerOp      uint64  `json:"allocsPerOp"`
}

func readGoBenchmarks(path string, cpus int) ([]GoBenchmark, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	counts := map[string]int{"BenchmarkGatewayInspect": 0, "BenchmarkGatewayInspectReconnect": 0, "BenchmarkGatewayAuthorityPublish": 0}
	var rows []GoBenchmark
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) < 2 || !strings.HasPrefix(fields[0], "Benchmark") {
			continue
		}
		if len(fields) != 8 || fields[3] != "ns/op" || fields[5] != "B/op" || fields[7] != "allocs/op" {
			return nil, fmt.Errorf("invalid Go benchmark measurement: %q", scanner.Text())
		}
		name, cpuText, ok := strings.Cut(fields[0], "-")
		if !ok {
			return nil, fmt.Errorf("missing benchmark CPU count")
		}
		if _, ok := counts[name]; !ok {
			return nil, fmt.Errorf("unmapped Go benchmark: %s", name)
		}
		cores, e0 := strconv.Atoi(cpuText)
		iterations, e1 := strconv.ParseUint(fields[1], 10, 64)
		elapsed, e2 := strconv.ParseFloat(fields[2], 64)
		bytes, e3 := strconv.ParseUint(fields[4], 10, 64)
		allocs, e4 := strconv.ParseUint(fields[6], 10, 64)
		if e0 != nil || e1 != nil || e2 != nil || e3 != nil || e4 != nil || cores != cpus || iterations == 0 || !positiveFinite(elapsed) {
			return nil, fmt.Errorf("invalid benchmark coordinates or values: %q", scanner.Text())
		}
		counts[name]++
		rows = append(rows, GoBenchmark{name, cores, iterations, elapsed, bytes, allocs})
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	for name, count := range counts {
		if count != 3 {
			return nil, fmt.Errorf("Go benchmark %s has %d measurements, expected three", name, count)
		}
	}
	return rows, nil
}
