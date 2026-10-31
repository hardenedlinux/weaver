package gatewayclient

import (
	"bytes"
	"errors"
	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	"github.com/apache/arrow-go/v18/arrow"
	"github.com/apache/arrow-go/v18/arrow/array"
	"github.com/apache/arrow-go/v18/arrow/ipc"
	"github.com/apache/arrow-go/v18/arrow/memory"
	"math"
	"strings"
)

func Events(frame *pb.ProviderFrame, encoding pb.Encoding) ([]*pb.Event, error) {
	if encoding == pb.Encoding_PROTOBUF {
		event := frame.GetEvent()
		if event == nil {
			return nil, errors.New("protobuf event required")
		}
		return []*pb.Event{event}, nil
	}
	batch := frame.GetArrow()
	if encoding != pb.Encoding_ARROW_IPC || batch == nil || batch.Rows == 0 || batch.Rows > 32 || len(batch.Ipc) > 4*1024*1024 {
		return nil, errors.New("Arrow batch bound or encoding mismatch")
	}
	if batch.FirstSequence > math.MaxUint64-uint64(batch.Rows-1) {
		return nil, errors.New("Arrow sequence overflow")
	}
	if err := arrowEnvelope(batch.Ipc); err != nil {
		return nil, err
	}
	allocator := &arrowAllocator{base: memory.NewGoAllocator(), limit: arrowBufferBudget}
	reader, err := ipc.NewReader(bytes.NewReader(batch.Ipc), ipc.WithAllocator(allocator))
	if err != nil {
		return nil, err
	}
	defer reader.Release()
	schema := arrow.NewSchema([]arrow.Field{{Name: "sequence", Type: arrow.PrimitiveTypes.Uint64}, {Name: "kind", Type: arrow.BinaryTypes.String}, {Name: "text", Type: arrow.BinaryTypes.String}, {Name: "tokens", Type: arrow.PrimitiveTypes.Uint64}}, nil)
	if !reader.Schema().Equal(schema) {
		return nil, errors.New("Arrow schema or record missing")
	}
	if !reader.Next() {
		if err := reader.Err(); err != nil {
			return nil, err
		}
		return nil, errors.New("Arrow record missing")
	}
	record := reader.RecordBatch()
	if record.NumRows() != int64(batch.Rows) {
		return nil, errors.New("Arrow row count differs")
	}
	seq := record.Column(0).(*array.Uint64)
	kind := record.Column(1).(*array.String)
	text := record.Column(2).(*array.String)
	tokens := record.Column(3).(*array.Uint64)
	result := make([]*pb.Event, batch.Rows)
	remaining := arrowTextBudget
	for i := range result {
		if seq.IsNull(i) || kind.IsNull(i) || text.IsNull(i) || tokens.IsNull(i) || seq.Value(i) != batch.FirstSequence+uint64(i) {
			return nil, errors.New("Arrow nullable or unordered event")
		}
		k, value := kind.Value(i), text.Value(i)
		if len(k) > remaining || len(value) > remaining-len(k) {
			return nil, errors.New("Arrow decoded text bound")
		}
		remaining -= len(k) + len(value)
		// Return owned strings; no Event retains an entire IPC data buffer.
		result[i] = &pb.Event{Sequence: seq.Value(i), Kind: strings.Clone(k), Text: strings.Clone(value), Tokens: tokens.Value(i)}
	}
	if reader.Next() || reader.Err() != nil {
		return nil, errors.New("Arrow trailing or invalid record")
	}
	return result, nil
}
