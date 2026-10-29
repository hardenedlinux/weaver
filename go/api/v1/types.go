// Package contract defines proposals shared with the Rust deciding owner.
package v1

type Task struct {
	Family          string            `json:"family"`
	Principal       string            `json:"principal"`
	Profile         string            `json:"profile"`
	Nodes           []string          `json:"nodes"`
	Targets         []string          `json:"targets"`
	Endpoints       map[string]string `json:"endpoints"`
	BodyDigests     map[string]string `json:"body_digests"`
	NodeCostBounds  map[string]uint64 `json:"node_cost_bounds"`
	StreamContracts map[string]string `json:"stream_contracts"`
	Models          []string          `json:"models"`
	Budget          uint64            `json:"budget"`
}

type Proposal struct {
	Family   string `json:"family"`
	Node     string `json:"node"`
	Profile  string `json:"profile"`
	Target   string `json:"target"`
	Endpoint string `json:"endpoint"`
	Model    string `json:"model"`
	Body     string `json:"body"`
	Ceiling  uint64 `json:"ceiling"`
	Revision uint64 `json:"revision"`
	Fence    uint64 `json:"fence"`
}

// Request contains preferences, never original authority or an endpoint override.
type Request struct {
	Node    string   `json:"node"`
	Targets []string `json:"targets"`
	Model   string   `json:"model"`
	Body    string   `json:"body"`
	Ceiling uint64   `json:"ceiling"`
}

// View is a proposal observation; Rust rechecks it at each deciding transaction.
type View struct{ Revision, Fence uint64 }
