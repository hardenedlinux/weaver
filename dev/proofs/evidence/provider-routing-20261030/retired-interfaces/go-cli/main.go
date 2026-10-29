// weaverctl emits a canonical proposal; only the Rust broker can execute it.
package main

import (
	"encoding/json"
	"fmt"
	contract "github.com/HardenedLinux/weaver/go/api/v1"
	"github.com/HardenedLinux/weaver/go/internal/routing"
	"os"
	"strconv"
)

func run(args []string) error {
	if len(args) > 0 && args[0] == "stream" {
		return runStream(args[1:])
	}
	if len(args) != 4 {
		return fmt.Errorf("usage: weaverctl TASK.json REQUEST.json REVISION FENCE")
	}
	taskBytes, err := os.ReadFile(args[0])
	if err != nil {
		return err
	}
	requestBytes, err := os.ReadFile(args[1])
	if err != nil {
		return err
	}
	task, err := contract.Decode[contract.Task](taskBytes)
	if err != nil {
		return err
	}
	request, err := contract.Decode[contract.Request](requestBytes)
	if err != nil {
		return err
	}
	revision, err := strconv.ParseUint(args[2], 10, 63)
	if err != nil {
		return err
	}
	fence, err := strconv.ParseUint(args[3], 10, 63)
	if err != nil {
		return err
	}
	proposal, err := routing.Compile(task, request, contract.View{Revision: revision, Fence: fence})
	if err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(proposal)
}
func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
