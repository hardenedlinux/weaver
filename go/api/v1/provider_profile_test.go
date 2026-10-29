package v1

import (
	"encoding/json"
	"os"
	"testing"
)

func sourceProfile(t testing.TB) ProviderProfile {
	t.Helper()
	data, err := os.ReadFile("../../../dev/policies/provider/profile.json")
	if err != nil {
		t.Fatal(err)
	}
	profile, err := Decode[ProviderProfile](data)
	if err != nil {
		t.Fatal(err)
	}
	return profile
}

func TestProviderProfileSharedClosedRequestCorpus(t *testing.T) {
	data, err := os.ReadFile("../../../dev/policies/provider/request-cases.json")
	if err != nil {
		t.Fatal(err)
	}
	cases, err := Decode[[]struct {
		Name   string                     `json:"name"`
		Patch  map[string]json.RawMessage `json:"patch"`
		Remove []string                   `json:"remove"`
		Valid  bool                       `json:"valid"`
	}](data)
	if err != nil {
		t.Fatal(err)
	}
	for _, test := range cases {
		t.Run(test.Name, func(t *testing.T) {
			body := map[string]json.RawMessage{"model": []byte(`"model-a"`), "stream": []byte(`true`),
				"messages": []byte(`[{"role":"user","content":"hello"}]`), "max_completion_tokens": []byte(`32`)}
			for _, key := range test.Remove {
				delete(body, key)
			}
			for key, value := range test.Patch {
				body[key] = value
			}
			encoded, err := json.Marshal(body)
			if err != nil {
				t.Fatal(err)
			}
			_, err = sourceProfile(t).RequestFacts(string(encoded))
			if (err == nil) != test.Valid {
				t.Fatalf("shared semantic contract disagrees: %v", err)
			}
		})
	}
}

func TestProviderProfileCommitmentBindsAllLimits(t *testing.T) {
	original := sourceProfile(t)
	digest, err := original.Digest()
	if err != nil {
		t.Fatal(err)
	}
	for _, mutate := range []func(*ProviderProfile){
		func(p *ProviderProfile) { p.ID = "another-profile" }, func(p *ProviderProfile) { p.MaxOutputTokens-- },
		func(p *ProviderProfile) { p.MaxMessages-- }, func(p *ProviderProfile) { p.MaxBodyBytes-- },
	} {
		changed := original
		mutate(&changed)
		got, err := changed.Digest()
		if err != nil || got == digest {
			t.Fatal("semantic limit missing from commitment", err)
		}
	}
	original.Protocol = "unknown-protocol"
	if _, err := original.Digest(); err == nil {
		t.Fatal("unknown protocol admitted")
	}
}

func FuzzProviderProfileRequestFacts(f *testing.F) {
	source := sourceProfile(f)
	f.Add(uint16(4095), uint64(32), uint8(63), uint8(1), false)
	f.Add(uint16(31), uint64(33), uint8(0), uint8(2), true)
	f.Fuzz(func(t *testing.T, tokens uint16, wanted uint64, limit, count uint8, extension bool) {
		profile := source
		profile.MaxOutputTokens = uint64(tokens%4096) + 1
		profile.MaxMessages = uint64(limit%64) + 1
		messages := make([]map[string]string, int(count%66))
		for i := range messages {
			messages[i] = map[string]string{"role": "user", "content": "hello"}
		}
		body := map[string]any{"model": "model-a", "stream": true, "messages": messages, "max_completion_tokens": wanted}
		if extension {
			body["max_output_tokens"] = 1000000
		}
		encoded, err := json.Marshal(body)
		if err != nil {
			t.Fatal(err)
		}
		facts, err := profile.RequestFacts(string(encoded))
		want := wanted > 0 && wanted <= profile.MaxOutputTokens && len(messages) > 0 && uint64(len(messages)) <= profile.MaxMessages && !extension
		if (err == nil) != want {
			t.Fatalf("source profile bound bypass: %v", err)
		}
		if err == nil && (facts.OutputTokenLimit != wanted || facts.MessageCount != uint64(len(messages))) {
			t.Fatal("request facts changed")
		}
	})
}
