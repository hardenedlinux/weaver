// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package v1

// QualifiedDeltaCatalog is an immutable deployment artifact from actual SPEC.
// Its digest must be provisioned independently of a publication request.
type QualifiedDeltaCatalog struct {
	Engine        string                `json:"engine"`
	Qualification string                `json:"qualification"`
	Entries       []QualifiedDeltaEntry `json:"entries"`
}

// QualifiedDeltaEntry preserves exact analyzed bytes, epoch and solver scope.
type QualifiedDeltaEntry struct {
	Name           string `json:"name"`
	BeforePolicy   string `json:"before_policy"`
	AfterPolicy    string `json:"after_policy"`
	Schema         string `json:"schema"`
	Epoch          uint64 `json:"epoch"`
	Environments   uint64 `json:"environments"`
	Gains          uint64 `json:"gains"`
	Losses         uint64 `json:"losses"`
	Classification string `json:"classification"`
}
