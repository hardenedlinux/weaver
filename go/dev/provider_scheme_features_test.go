//go:build integration && schemeintegration && !windows

package dev

// The explicit qualification graph tests production ABI/lifecycle code without
// pretending that the fixture Governor/Profile is a production application.
const providerRuntimeFeatures = "arrow,governance-qualification"
