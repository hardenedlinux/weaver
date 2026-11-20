// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package gatewayclient

import (
	"bytes"
	"testing"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	"github.com/apache/arrow-go/v18/arrow"
	"github.com/apache/arrow-go/v18/arrow/array"
	"github.com/apache/arrow-go/v18/arrow/ipc"
	"github.com/apache/arrow-go/v18/arrow/memory"
	"google.golang.org/protobuf/proto"
)

func TestVersionedTurnEnvelopePreservesOpaquePayload(t *testing.T) {
	payload := []byte(`{"version":1,"payload":{"kind":"thinking","text":"retained"}}`)
	frame := &pb.ProviderFrame{Payload: &pb.ProviderFrame_Event{Event: &pb.Event{Kind: "turn.v1", TurnJson: payload}}}
	wire, err := proto.Marshal(frame)
	if err != nil {
		t.Fatal(err)
	}
	var received pb.ProviderFrame
	if err := proto.Unmarshal(wire, &received); err != nil {
		t.Fatal(err)
	}
	events, err := Events(&received, pb.Encoding_PROTOBUF)
	if err != nil || len(events) != 1 || !bytes.Equal(events[0].TurnJson, payload) {
		t.Fatalf("rich payload changed: %v", err)
	}
}

func richArrowObservation(t *testing.T, kind, text string, payload []byte) *pb.ProviderFrame {
	t.Helper()
	schema := arrow.NewSchema([]arrow.Field{
		{Name: "sequence", Type: arrow.PrimitiveTypes.Uint64},
		{Name: "kind", Type: arrow.BinaryTypes.String},
		{Name: "text", Type: arrow.BinaryTypes.String},
		{Name: "tokens", Type: arrow.PrimitiveTypes.Uint64},
		{Name: "turn_json", Type: arrow.BinaryTypes.Binary},
	}, nil)
	builder := array.NewRecordBuilder(memory.DefaultAllocator, schema)
	defer builder.Release()
	builder.Field(0).(*array.Uint64Builder).Append(7)
	builder.Field(1).(*array.StringBuilder).Append(kind)
	builder.Field(2).(*array.StringBuilder).Append(text)
	builder.Field(3).(*array.Uint64Builder).Append(0)
	builder.Field(4).(*array.BinaryBuilder).Append(payload)
	record := builder.NewRecordBatch()
	defer record.Release()
	var wire bytes.Buffer
	writer := ipc.NewWriter(&wire, ipc.WithSchema(schema))
	if err := writer.Write(record); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	return &pb.ProviderFrame{Payload: &pb.ProviderFrame_Arrow{Arrow: &pb.ArrowBatch{Ipc: wire.Bytes(), FirstSequence: 7, Rows: 1}}}
}

func TestRichArrowPreservesOwnedPayloadAndRejectsMixedFields(t *testing.T) {
	payload := []byte(`{"version":1,"payload":{"kind":"thinking","text":"retained"}}`)
	frame := richArrowObservation(t, "turn.v1", "", payload)
	events, err := Events(frame, pb.Encoding_ARROW_IPC)
	if err != nil || len(events) != 1 || !bytes.Equal(events[0].TurnJson, payload) {
		t.Fatalf("rich Arrow payload changed: %v", err)
	}
	clear(frame.GetArrow().Ipc)
	if !bytes.Equal(events[0].TurnJson, payload) {
		t.Fatal("event retained released IPC storage")
	}
	for _, malformed := range []*pb.ProviderFrame{
		richArrowObservation(t, "delta", "", payload),
		richArrowObservation(t, "turn.v1", "mixed", payload),
		richArrowObservation(t, "turn.v1", "", make([]byte, 65537)),
	} {
		if _, err := Events(malformed, pb.Encoding_ARROW_IPC); err == nil {
			t.Fatal("invalid rich Arrow accepted")
		}
	}
}

func TestVersionedTurnEnvelopeRejectsMixedAndOversizedPayloads(t *testing.T) {
	for _, event := range []*pb.Event{
		{Kind: "delta", TurnJson: []byte(`{}`)},
		{Kind: "turn.v1"},
		{Kind: "turn.v1", TurnJson: []byte(`{}`), Text: "mixed"},
		{Kind: "turn.v1", TurnJson: []byte(`{}`), Tokens: 1},
		{Kind: "turn.v1", TurnJson: make([]byte, 65537)},
	} {
		frame := &pb.ProviderFrame{Payload: &pb.ProviderFrame_Event{Event: event}}
		if _, err := Events(frame, pb.Encoding_PROTOBUF); err == nil {
			t.Fatalf("invalid envelope accepted: %s", event.Kind)
		}
	}
}
