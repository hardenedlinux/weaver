package v1

import (
	"bytes"
	"testing"
)

func TestSourceDecodeKeepsSeparateDeclaredBounds(t *testing.T) {
	type Source struct {
		Name string `json:"name"`
	}
	value := append([]byte(`{"name":"source"}`), bytes.Repeat([]byte(" "), 8*1024*1024-len(`{"name":"source"}`))...)
	if _, err := Decode[Source](value); err == nil {
		t.Fatal("ordinary input limit expanded with source limit")
	}
	if result, err := DecodeSource[Source](value); err != nil || result.Name != "source" {
		t.Fatal("declared source bound rejected", err)
	}
	for _, invalid := range [][]byte{append(value, ' '), []byte(`{"name":"first","name":"second"}`), []byte(`{"name":"source","approved":true}`)} {
		if _, err := DecodeSource[Source](invalid); err == nil {
			t.Fatal("invalid source input accepted")
		}
	}
}
