package devrunner

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
	"strings"
)

// Native Go benchmark rows retain each stage cost; none is a tail percentile.
type PipelineBenchmark struct {
	Name       string  `json:"name"`
	CPUs       int     `json:"cpus"`
	Iterations uint64  `json:"iterations"`
	Total      float64 `json:"nanosecondsPerOp"`
	Activation float64 `json:"activationNanosecondsPerOp"`
	Send       float64 `json:"sendNanosecondsPerOp"`
	Bytes      uint64  `json:"bytesPerOp"`
	Allocs     uint64  `json:"allocsPerOp"`
}

func readPipelineBenchmarks(path string, cpus int) ([]PipelineBenchmark, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	counts := map[string]int{"BenchmarkGatewayCompiledPipeline/inline": 0, "BenchmarkGatewayCompiledPipeline/assets": 0}
	rows := []PipelineBenchmark{}
	scan := bufio.NewScanner(file)
	for scan.Scan() {
		fields := strings.Fields(scan.Text())
		if len(fields) < 3 || !strings.HasPrefix(fields[0], "BenchmarkGatewayCompiledPipeline/") {
			continue
		}
		if len(fields) != 12 {
			return nil, fmt.Errorf("invalid pipeline measurement: %q", scan.Text())
		}
		index := strings.LastIndex(fields[0], "-")
		if index < 0 {
			return nil, fmt.Errorf("missing pipeline CPU count")
		}
		name := fields[0][:index]
		cores, e0 := strconv.Atoi(fields[0][index+1:])
		iterations, e1 := strconv.ParseUint(fields[1], 10, 64)
		if _, ok := counts[name]; !ok || e0 != nil || e1 != nil || cores != cpus || iterations != 1 {
			return nil, fmt.Errorf("invalid pipeline sample coordinates")
		}
		metrics := map[string]string{}
		for i := 2; i < len(fields); i += 2 {
			if _, exists := metrics[fields[i+1]]; exists {
				return nil, fmt.Errorf("duplicate pipeline unit")
			}
			metrics[fields[i+1]] = fields[i]
		}
		total, e2 := strconv.ParseFloat(metrics["ns/op"], 64)
		activation, e3 := strconv.ParseFloat(metrics["activation-ns/op"], 64)
		send, e4 := strconv.ParseFloat(metrics["send-ns/op"], 64)
		bytes, e5 := strconv.ParseUint(metrics["B/op"], 10, 64)
		allocs, e6 := strconv.ParseUint(metrics["allocs/op"], 10, 64)
		if e2 != nil || e3 != nil || e4 != nil || e5 != nil || e6 != nil || !positiveFinite(total) || !positiveFinite(activation) || !positiveFinite(send) || activation+send > total*1.01 {
			return nil, fmt.Errorf("invalid pipeline units or intervals")
		}
		counts[name]++
		rows = append(rows, PipelineBenchmark{name, cores, iterations, total, activation, send, bytes, allocs})
	}
	if err := scan.Err(); err != nil {
		return nil, err
	}
	for name, count := range counts {
		if count != 3 {
			return nil, fmt.Errorf("pipeline %s has %d samples, expected three", name, count)
		}
	}
	return rows, nil
}

var sourceAdmissionBenchmarks = []string{
	"BenchmarkCompiledSourceAdmission/projection/128",
	"BenchmarkCompiledSourceAdmission/projection/16384",
	"BenchmarkCompiledSourceAdmission/projection/524288",
	"BenchmarkCompiledSourceAdmission/bootstrap/128",
	"BenchmarkCompiledSourceAdmission/bootstrap/16384",
	"BenchmarkCompiledSourceAdmission/bootstrap/524288",
}
