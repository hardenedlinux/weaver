package main

import (
	"encoding/json"
	"errors"
	contract "github.com/HardenedLinux/weaver/go/api/v1"
	"github.com/HardenedLinux/weaver/go/internal/streaming"
	"os"
	"strconv"
)

func runStream(args []string) error {
	if len(args) != 7 {
		return errors.New("usage: weaverctl stream TASK CONTRACT MESSAGE PAYLOAD CEILING REVISION FENCE")
	}
	source, err := os.ReadFile(args[0])
	if err != nil {
		return err
	}
	task, err := contract.Decode[contract.Task](source)
	if err != nil {
		return err
	}
	source, err = os.ReadFile(args[1])
	if err != nil {
		return err
	}
	c, err := contract.Decode[streaming.Contract](source)
	if err != nil {
		return err
	}
	payload, err := os.ReadFile(args[3])
	if err != nil {
		return err
	}
	ceiling, err := strconv.ParseUint(args[4], 10, 63)
	if err != nil {
		return err
	}
	revision, err := strconv.ParseUint(args[5], 10, 63)
	if err != nil {
		return err
	}
	fence, err := strconv.ParseUint(args[6], 10, 63)
	if err != nil {
		return err
	}
	p, err := streaming.Compile(task, c, args[2], string(payload), ceiling, contract.View{Revision: revision, Fence: fence})
	if err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(p)
}
