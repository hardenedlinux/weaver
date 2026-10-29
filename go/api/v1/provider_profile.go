package v1

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
)

const ChatTextSSE = "openai.chat-text-sse.v1"

// ProviderProfile is source data; registration and execution have distinct owners.
type ProviderProfile struct {
	ID              string `json:"id"`
	Protocol        string `json:"protocol"`
	MaxOutputTokens uint64 `json:"max_output_tokens"`
	MaxMessages     uint64 `json:"max_messages"`
	MaxBodyBytes    uint64 `json:"max_body_bytes"`
}

type ProviderRequestFacts struct {
	Model                          string
	OutputTokenLimit, MessageCount uint64
}

func (p ProviderProfile) Validate() error {
	if !providerIdentifier(p.ID) || p.Protocol != ChatTextSSE || p.MaxOutputTokens == 0 || p.MaxOutputTokens > 4096 ||
		p.MaxMessages == 0 || p.MaxMessages > 64 || p.MaxBodyBytes == 0 || p.MaxBodyBytes > 1<<20 {
		return errors.New("provider profile bounds or protocol")
	}
	return nil
}
func providerIdentifier(value string) bool {
	if value == "" || len(value) > 128 {
		return false
	}
	for _, c := range []byte(value) {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '.' || c == '_' || c == ':' || c == '-') {
			return false
		}
	}
	return true
}

func (p ProviderProfile) Digest() (string, error) {
	if err := p.Validate(); err != nil {
		return "", err
	}
	var out bytes.Buffer
	encoder := json.NewEncoder(&out)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode([]any{"weaver.provider-profile.v1", p.ID, p.Protocol, p.MaxOutputTokens, p.MaxMessages, p.MaxBodyBytes}); err != nil {
		return "", err
	}
	digest := sha256.Sum256(bytes.TrimSuffix(out.Bytes(), []byte{'\n'}))
	return hex.EncodeToString(digest[:]), nil
}
