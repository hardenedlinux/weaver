// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

package gatewayclient

import (
	"encoding/binary"
	"errors"

	"github.com/apache/arrow-go/v18/arrow/ipc"
	"github.com/apache/arrow-go/v18/arrow/memory"
)

// Validate bounded framing before the IPC reader allocates metadata from its
// declared length. Use Arrow's public Message API for body length and type;
// neither this check nor the allocator verifies arbitrary FlatBuffer graphs.
func arrowEnvelope(data []byte) (err error) {
	defer func() {
		if recover() != nil {
			err = errors.New("invalid Arrow envelope metadata")
		}
	}()
	for index := 0; ; index++ {
		if len(data) < 4 {
			return errors.New("Arrow end marker required")
		}
		length := binary.LittleEndian.Uint32(data)
		data = data[4:]
		if length == ^uint32(0) {
			if len(data) < 4 {
				return errors.New("Arrow metadata length missing")
			}
			length = binary.LittleEndian.Uint32(data)
			data = data[4:]
		}
		if length == 0 {
			if index != 2 || len(data) != 0 {
				return errors.New("Arrow trailing or missing message")
			}
			return nil
		}
		if index >= 2 || length > 64<<10 || uint64(length) > uint64(len(data)) {
			return errors.New("Arrow metadata envelope bound")
		}
		body, kind := arrowMessageEnvelope(data[:length])
		data = data[length:]
		if body < 0 || uint64(body) > uint64(len(data)) ||
			(index == 0 && (kind != ipc.MessageSchema || body != 0)) ||
			(index == 1 && kind != ipc.MessageRecordBatch) {
			return errors.New("Arrow message envelope mismatch")
		}
		data = data[int(body):]
	}
}

func arrowMessageEnvelope(metadata []byte) (int64, ipc.MessageType) {
	meta, body := memory.NewBufferBytes(metadata), memory.NewBufferBytes(nil)
	defer meta.Release()
	defer body.Release()
	message := ipc.NewMessage(meta, body)
	defer message.Release()
	return message.BodyLen(), message.Type()
}
