package gatewayclient

import (
	"bytes"
	"strings"
	"testing"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	"github.com/apache/arrow-go/v18/arrow"
	"github.com/apache/arrow-go/v18/arrow/array"
	"github.com/apache/arrow-go/v18/arrow/ipc"
	"github.com/apache/arrow-go/v18/arrow/memory"
)

func encodedObservation(t *testing.T, sequences []uint64, text string, compressed bool) *pb.ProviderFrame {
	t.Helper()
	schema := arrow.NewSchema([]arrow.Field{
		{Name: "sequence", Type: arrow.PrimitiveTypes.Uint64},
		{Name: "kind", Type: arrow.BinaryTypes.String},
		{Name: "text", Type: arrow.BinaryTypes.String},
		{Name: "tokens", Type: arrow.PrimitiveTypes.Uint64},
	}, nil)
	builder := array.NewRecordBuilder(memory.DefaultAllocator, schema)
	defer builder.Release()
	for _, sequence := range sequences {
		builder.Field(0).(*array.Uint64Builder).Append(sequence)
		builder.Field(1).(*array.StringBuilder).Append("delta")
		builder.Field(2).(*array.StringBuilder).Append(text)
		builder.Field(3).(*array.Uint64Builder).Append(0)
	}
	record := builder.NewRecordBatch()
	defer record.Release()
	var output bytes.Buffer
	options := []ipc.Option{ipc.WithSchema(schema)}
	if compressed {
		options = append(options, ipc.WithZstd())
	}
	writer := ipc.NewWriter(&output, options...)
	if err := writer.Write(record); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	return &pb.ProviderFrame{Payload: &pb.ProviderFrame_Arrow{Arrow: &pb.ArrowBatch{
		Ipc: output.Bytes(), FirstSequence: 0, Rows: uint32(len(sequences)),
	}}}
}

// Bounded counterexample to a resource assumption, not a performance benchmark
// or proof of peak allocation. No production compression feature is enabled.
func TestArrowWireBoundDoesNotBoundDecodedText(t *testing.T) {
	frame := encodedObservation(t, []uint64{0, 1, 2, 3}, strings.Repeat("x", 64*1024), true)
	events, err := Events(frame, pb.Encoding_ARROW_IPC)
	if err != nil {
		t.Fatal(err)
	}
	decoded := 0
	for _, event := range events {
		decoded += len(event.Text)
	}
	wire := len(frame.GetArrow().Ipc)
	if decoded != 256*1024 || wire*8 >= decoded {
		t.Fatalf("fixture must expose expansion: wire=%d decoded-text=%d", wire, decoded)
	}
	t.Logf("bounded resource counterexample: IPC=%d bytes, decoded text=%d bytes; no peak-memory claim", wire, decoded)
}

func TestArrowInvalidLaterRowReturnsNoPartialBatch(t *testing.T) {
	frame := encodedObservation(t, []uint64{0, 8}, "small", false)
	events, err := Events(frame, pb.Encoding_ARROW_IPC)
	if err == nil || events != nil {
		t.Fatalf("invalid later row escaped as a prefix: events=%v error=%v", events, err)
	}
}

func TestArrowFrameCannotChangeNegotiatedEncoding(t *testing.T) {
	frame := encodedObservation(t, []uint64{0}, "small", false)
	events, err := Events(frame, pb.Encoding_PROTOBUF)
	if err == nil || events != nil {
		t.Fatalf("encoding mismatch adopted: events=%v error=%v", events, err)
	}
}
