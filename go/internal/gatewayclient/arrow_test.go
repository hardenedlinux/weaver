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

func encodedObservation(t testing.TB, sequences []uint64, text string, compressed bool) *pb.ProviderFrame {
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

func TestArrowCompressedAllocationLimitReturnsNoBatch(t *testing.T) {
	// A small valid IPC envelope asks the real reader for more than its entire
	// buffer allowance. The check must happen before the decompression allocation.
	frame := encodedObservation(t, []uint64{0}, strings.Repeat("x", arrowBufferBudget+1), true)
	if len(frame.GetArrow().Ipc) >= 4<<20 {
		t.Fatal("fixture exceeds wire cap")
	}
	events, err := Events(frame, pb.Encoding_ARROW_IPC)
	if err == nil || events != nil {
		t.Fatal("compressed allocation escaped budget")
	}
	if !strings.Contains(err.Error(), "allocation budget exceeded") {
		t.Fatalf("wrong refusal: %v", err)
	}
	// A refused batch must not poison another stream's independent allowance.
	valid := encodedObservation(t, []uint64{0}, "after refusal", false)
	if events, err = Events(valid, pb.Encoding_ARROW_IPC); err != nil || len(events) != 1 {
		t.Fatalf("fresh decoder failed: %v", err)
	}
}

func TestArrowSequenceCannotWrap(t *testing.T) {
	frame := encodedObservation(t, []uint64{^uint64(0), 0}, "small", false)
	frame.GetArrow().FirstSequence = ^uint64(0)
	if events, err := Events(frame, pb.Encoding_ARROW_IPC); err == nil || events != nil {
		t.Fatal("wrapped sequence accepted")
	}
}

func TestArrowEnvelopeRejectsOversizedMetadataAndTrailingBytes(t *testing.T) {
	for _, data := range [][]byte{{255, 255, 255, 255, 255, 255, 255, 127}, {0, 0, 0, 0, 1}} {
		if arrowEnvelope(data) == nil {
			t.Fatal("invalid framing admitted")
		}
	}
	frame := encodedObservation(t, []uint64{0}, "small", false)
	frame.GetArrow().Ipc = append(frame.GetArrow().Ipc, 1)
	if events, err := Events(frame, pb.Encoding_ARROW_IPC); err == nil || events != nil {
		t.Fatal("trailing bytes admitted")
	}
}

func TestArrowDecodedTextLimitReturnsNoBatch(t *testing.T) {
	frame := encodedObservation(t, []uint64{0}, strings.Repeat("x", arrowTextBudget), true)
	// Kind bytes count too, even though the text column alone is exactly at cap.
	if events, err := Events(frame, pb.Encoding_ARROW_IPC); err == nil || events != nil ||
		!strings.Contains(err.Error(), "decoded text bound") {
		t.Fatalf("decoded text cap was not enforced: %v", err)
	}
}

func BenchmarkArrowObservationDecode(b *testing.B) {
	for _, rows := range []int{1, 32} {
		name := "single"
		if rows == 32 {
			name = "batch32"
		}
		b.Run(name, func(b *testing.B) {
			sequences := make([]uint64, rows)
			for i := range sequences {
				sequences[i] = uint64(i)
			}
			frame := encodedObservation(b, sequences, strings.Repeat("x", 1024), false)
			b.ReportAllocs()
			b.SetBytes(int64(rows * 1024))
			b.ResetTimer()
			for range b.N {
				events, err := Events(frame, pb.Encoding_ARROW_IPC)
				if err != nil || len(events) != rows {
					b.Fatalf("decode: %v", err)
				}
			}
		})
	}
}

func FuzzArrowObservationRoundTrip(f *testing.F) {
	f.Add("delta", uint8(2), true, false)
	f.Add("", uint8(0), false, true)
	f.Fuzz(func(t *testing.T, text string, count uint8, compressed, corrupt bool) {
		if len(text) > 4096 {
			text = text[:4096]
		}
		rows := int(count%32) + 1
		sequences := make([]uint64, rows)
		for i := range sequences {
			sequences[i] = uint64(i)
		}
		if corrupt {
			sequences[rows-1] += 8
		}
		frame := encodedObservation(t, sequences, text, compressed)
		events, err := Events(frame, pb.Encoding_ARROW_IPC)
		if corrupt {
			if err == nil || events != nil {
				t.Fatal("invalid batch returned a prefix")
			}
			return
		}
		if err != nil || len(events) != rows {
			t.Fatalf("valid observation refused: %v", err)
		}
		for i, event := range events {
			if event.Sequence != uint64(i) || event.Text != text || event.Kind != "delta" || event.Tokens != 0 {
				t.Fatal("observation changed")
			}
		}
	})
}
