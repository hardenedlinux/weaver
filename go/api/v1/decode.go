package v1

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
)

const MaxInput = 2 * 1024 * 1024

// Decode rejects duplicate/unknown keys and trailing data before using a record.
func Decode[T any](source []byte) (T, error) {
	return decodeBounded[T](source, MaxInput)
}

// DecodeSource preserves the separately declared eight-MiB inert source limit.
// Ordinary protocol messages retain MaxInput; neither decoder grants authority.
func DecodeSource[T any](source []byte) (T, error) {
	return decodeBounded[T](source, 8*1024*1024)
}

func decodeBounded[T any](source []byte, limit int) (T, error) {
	var out T
	if len(source) > limit {
		return out, errors.New("input size exceeded")
	}
	decoder := json.NewDecoder(bytes.NewReader(source))
	decoder.UseNumber()
	if err := unique(decoder, 0); err != nil {
		return out, err
	}
	if _, err := decoder.Token(); err != io.EOF {
		return out, errors.New("trailing JSON")
	}
	typed := json.NewDecoder(bytes.NewReader(source))
	typed.DisallowUnknownFields()
	if err := typed.Decode(&out); err != nil {
		return out, err
	}
	return out, nil
}

func unique(d *json.Decoder, depth int) error {
	if depth > 64 {
		return errors.New("nesting exceeded")
	}
	t, err := d.Token()
	if err != nil {
		return err
	}
	delimiter, container := t.(json.Delim)
	if !container {
		return nil
	}
	switch delimiter {
	case '{':
		seen := map[string]bool{}
		for d.More() {
			keyToken, err := d.Token()
			if err != nil {
				return err
			}
			key, ok := keyToken.(string)
			if !ok || seen[key] {
				return errors.New("duplicate or nonstring key")
			}
			seen[key] = true
			if err := unique(d, depth+1); err != nil {
				return err
			}
		}
	case '[':
		for d.More() {
			if err := unique(d, depth+1); err != nil {
				return err
			}
		}
	default:
		return errors.New("invalid delimiter")
	}
	_, err = d.Token()
	return err
}
