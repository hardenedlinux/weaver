package devrunner

import (
	"fmt"
	"os"
)

const proofToolchain = "leanprover/lean4:v4.34.1"

func schemeTool() string {
	if tool := os.Getenv("WEAVER_SCHEME_TOOL"); tool != "" {
		return tool
	}
	return "gerbil"
}

func Plan(goBinary string) []Stage {
	return []Stage{
		{"rust-environment", "rustc", []string{"-vV"}},
		{"go-environment", goBinary, []string{"-C", "go", "version"}},
		{"quint-environment", "quint", []string{"--version"}},
		{"proof-environment", "elan", []string{"run", proofToolchain, "lean", "--version"}},
		{"project-architecture", goBinary, []string{"-C", "go", "test", "-count=1", "./dev", "-run", "^Test(ProjectArchitecture|SysMLSDKAndRequirementTrace|CargoWorkspaceAndDevelopmentGates|SchemeModuleOwnership|CIWorkflows)", "-v"}},
		{"workflow-contract", "actionlint", nil},
		{"rust-format", "cargo", []string{"fmt", "--all", "--", "--check"}},
		{"rust-default-profile", "cargo", []string{"check", "--workspace", "--all-targets", "--locked", "--offline"}},
		{"rust-tests", "cargo", []string{"test", "--workspace", "--all-features", "--locked", "--offline"}},
		{"rust-clippy", "cargo", []string{"clippy", "--workspace", "--all-features", "--all-targets", "--locked", "--offline", "--", "-D", "warnings"}},
		{"go-fuzz-control-build", goBinary, []string{"-C", "go", "test", "-c", "./internal/devrunner/testdata/fuzzcontrol", "-o", "../.cache/fuzz-control.test"}},
		{"go-tests", goBinary, []string{"-C", "go", "test", "-count=1", "-race", "./..."}},
		{"go-routing-pbt", goBinary, []string{"-C", "go", "test", "./internal/routing", "-run", "^$", "-fuzz", "FuzzCeilingNeverExpands", "-fuzztime=3s", "-parallel=1"}},
		{"go-decoder-pbt", goBinary, []string{"-C", "go", "test", "./api/v1", "-run", "^$", "-fuzz", "FuzzDecoderNeverPanics", "-fuzztime=3s", "-parallel=1"}},
		{"go-stream-pbt", goBinary, []string{"-C", "go", "test", "./internal/streaming", "-run", "^$", "-fuzz", "FuzzMessageBounds", "-fuzztime=3s", "-parallel=1"}},
		{"quint-stream-tests", "quint", []string{"test", "dev/proofs/quint/StreamingExecution.qnt", "--main", "StreamingExecution", "--seed", "293"}},
		{"quint-stream-safety", "quint", []string{"run", "dev/proofs/quint/StreamingExecution.qnt", "--main", "StreamingExecution", "--invariant", "safe", "--max-samples", "1000", "--max-steps", "60", "--seed", "293"}},
		{"quint-lifecycle-tests", "quint", []string{"test", "dev/proofs/quint/RuntimeLifecycle.qnt", "--main", "RuntimeLifecycle", "--seed", "293"}},
		{"quint-lifecycle-safety", "quint", []string{"run", "dev/proofs/quint/RuntimeLifecycle.qnt", "--main", "RuntimeLifecycle", "--invariant", "safe", "--max-samples", "1000", "--max-steps", "60", "--seed", "293"}},
		{"lean-stream", "elan", []string{"run", proofToolchain, "lean", "dev/proofs/lean/StreamingExecution.lean"}},
		{"cedar-proof-bridge", "elan", []string{"run", proofToolchain, "lake", "-d", "dev/proofs/cedar", "build", "WeaverPolicyBridge"}},
		{"quint-typecheck", "quint", []string{"typecheck", "dev/proofs/quint/RuntimeAdmission.qnt"}},
		{"quint-tests", "quint", []string{"test", "dev/proofs/quint/RuntimeAdmission.qnt", "--main", "RuntimeAdmission", "--seed", "293"}},
		{"quint-safety", "quint", []string{"run", "dev/proofs/quint/RuntimeAdmission.qnt", "--main", "RuntimeAdmission", "--invariant", "safety", "--max-samples", "1000", "--max-steps", "50", "--seed", "293"}},
		{"lean", "elan", []string{"run", proofToolchain, "lean", "dev/proofs/lean/RuntimeAdmission.lean"}},
		{"provider-routing-pbt", goBinary, []string{"-C", "go", "test", "./internal/routing", "-run", "^$", "-fuzz", "FuzzProviderPlanCannotExpandAuthority", "-fuzztime=3s", "-parallel=1"}},
		{"provider-request-bounds-pbt", goBinary, []string{"-C", "go", "test", "./internal/routing", "-run", "^$", "-fuzz", "FuzzProviderRequestBounds", "-fuzztime=3s", "-parallel=1"}},
		{"provider-profile-schema-pbt", goBinary, []string{"-C", "go", "test", "./api/v1", "-run", "^$", "-fuzz", "FuzzProviderProfileRequestFacts", "-fuzztime=3s", "-parallel=1"}},
		{"provider-profile-config-pbt", goBinary, []string{"-C", "go", "test", "./internal/config", "-run", "^$", "-fuzz", "FuzzProviderProfileConfiguration", "-fuzztime=3s", "-parallel=1"}},
		{"profile-registry-quint-tests", "quint", []string{"test", "dev/proofs/quint/ProviderProfile.qnt", "--main", "ProviderProfile", "--seed", "293"}},
		{"profile-registry-quint-safety", "quint", []string{"run", "dev/proofs/quint/ProviderProfile.qnt", "--main", "ProviderProfile", "--invariant", "safe", "--max-samples", "1000", "--max-steps", "60", "--seed", "293"}},
		{"provider-quint-tests", "quint", []string{"test", "dev/proofs/quint/ProviderRpc.qnt", "--main", "ProviderRpc", "--seed", "293"}},
		{"provider-quint-safety", "quint", []string{"run", "dev/proofs/quint/ProviderRpc.qnt", "--main", "ProviderRpc", "--invariant", "safe", "--max-samples", "1000", "--max-steps", "60", "--seed", "293"}},
		{"provider-lean", "elan", []string{"run", proofToolchain, "lean", "dev/proofs/lean/ProviderRpc.lean"}},
		{"dispatch-cancellation-tests", "quint", []string{"test", "dev/proofs/quint/DispatchCancellation.qnt", "--main", "DispatchCancellation", "--seed", "293"}},
		{"dispatch-cancellation-safety", "quint", []string{"run", "dev/proofs/quint/DispatchCancellation.qnt", "--main", "DispatchCancellation", "--invariant", "safe", "--max-samples", "1000", "--max-steps", "60", "--seed", "293"}},
		{"release-binding-tests", "quint", []string{"test", "dev/proofs/quint/ReleaseBinding.qnt", "--main", "ReleaseBinding", "--seed", "293"}},
		{"release-binding-safety", "quint", []string{"run", "dev/proofs/quint/ReleaseBinding.qnt", "--main", "ReleaseBinding", "--invariant", "safe", "--max-samples", "1000", "--max-steps", "60", "--seed", "293"}},
		{"admission-quint-tests", "quint", []string{"test", "dev/proofs/quint/AuthorityAdmission.qnt", "--main", "AuthorityAdmission", "--seed", "293"}},
		{"admission-quint-safety", "quint", []string{"run", "dev/proofs/quint/AuthorityAdmission.qnt", "--main", "AuthorityAdmission", "--invariant", "safe", "--max-samples", "1000", "--max-steps", "60", "--seed", "293"}},
		{"connection-quint-tests", "quint", []string{"test", "dev/proofs/quint/ConnectionAdmission.qnt", "--main", "ConnectionAdmission", "--seed", "293"}},
		{"connection-quint-safety", "quint", []string{"run", "dev/proofs/quint/ConnectionAdmission.qnt", "--main", "ConnectionAdmission", "--invariant", "safe", "--max-samples", "1000", "--max-steps", "60", "--seed", "293"}},
		{"gateway-composition-tests", "quint", []string{"test", "dev/proofs/quint/GatewayComposition.qnt", "--main", "GatewayComposition", "--seed", "293"}},
		{"gateway-composition-safety", "quint", []string{"run", "dev/proofs/quint/GatewayComposition.qnt", "--main", "GatewayComposition", "--invariant", "safe", "--max-samples", "1000", "--max-steps", "60", "--seed", "293"}},
		{"source-ingress-quint-tests", "quint", []string{"test", "dev/proofs/quint/SourceIngress.qnt", "--main", "SourceIngress", "--seed", "293"}},
		{"source-ingress-quint-safety", "quint", []string{"run", "dev/proofs/quint/SourceIngress.qnt", "--main", "SourceIngress", "--invariant", "safe", "--max-samples", "1000", "--max-steps", "60", "--seed", "293"}},
		{"publication-quint-tests", "quint", []string{"test", "dev/proofs/quint/PublicationRecovery.qnt", "--main", "PublicationRecovery", "--seed", "293"}},
		{"publication-quint-safety", "quint", []string{"run", "dev/proofs/quint/PublicationRecovery.qnt", "--main", "PublicationRecovery", "--invariant", "safe", "--max-samples", "1000", "--max-steps", "60", "--seed", "293"}},
		{"publication-lean", "elan", []string{"run", proofToolchain, "lean", "dev/proofs/lean/PublicationRecovery.lean"}},
		{"source-owner-quint-tests", "quint", []string{"test", "dev/proofs/quint/SourceOwner.qnt", "--main", "SourceOwner", "--seed", "293"}},
		{"source-owner-quint-safety", "quint", []string{"run", "dev/proofs/quint/SourceOwner.qnt", "--main", "SourceOwner", "--invariant", "safe", "--max-samples", "1000", "--max-steps", "60", "--seed", "293"}},
		{"go-provider-grpc-integration", goBinary, []string{"-C", "go", "test", "-count=1", "-race", "-tags=integration", "./dev", "-run", "TestProvider", "-v"}},
		{"control-bundle-pbt", goBinary, []string{"-C", "go", "test", "./internal/config", "-run", "^$", "-fuzz", "FuzzSourceBundleCannotExpandOriginalSelection", "-fuzztime=3s", "-parallel=1"}},
		{"authority-publication-quint-tests", "quint", []string{"test", "dev/proofs/quint/AuthorityPublication.qnt", "--main", "AuthorityPublication", "--seed", "293", "--match", "^authority[A-Z]"}},
		{"authority-publication-quint-safety", "quint", []string{"run", "dev/proofs/quint/AuthorityPublication.qnt", "--main", "AuthorityPublication", "--invariant", "safe", "--max-samples", "1000", "--max-steps", "60", "--seed", "293"}},
	}
}
func Stages(mode, goBinary string) ([]Stage, error) {
	switch mode {
	case "bootstrap":
		return []Stage{
			{"rust-dependencies", "cargo", []string{"fetch", "--locked"}},
			{"go-dependencies", goBinary, []string{"-C", "go", "mod", "download"}},
			{"proof-toolchain", "elan", []string{"run", "--install", proofToolchain, "lean", "--version"}},
			{"proof-dependencies", "elan", []string{"run", proofToolchain, "lake", "-d", "dev/proofs/cedar", "build", "WeaverPolicyBridge"}},
		}, nil
	case "check":
		return Plan(goBinary), nil
	case "bootstrap-build", "bootstrap-proofs":
		stages, err := Stages("bootstrap", goBinary)
		if err != nil {
			return nil, err
		}
		if mode == "bootstrap-build" {
			return stages[:2], nil
		}
		return stages[2:], nil
	case "check-rust", "check-go", "check-policy", "check-architecture":
		var selected []Stage
		for _, stage := range Plan(goBinary) {
			common := stage.Name == "project-architecture" || stage.Name == "workflow-contract"
			language := mode == "check-rust" && (stage.Binary == "cargo" || stage.Binary == "rustc") ||
				mode == "check-go" && stage.Binary == goBinary ||
				mode == "check-policy" && (stage.Binary == "quint" || stage.Binary == "elan")
			if common || language {
				selected = append(selected, stage)
			}
		}
		return selected, nil
	case "check-scheme":
		return []Stage{
			{"project-architecture", goBinary, []string{"-C", "go", "test", "-count=1", "./dev", "-run", "^Test(ProjectArchitecture|SysMLSDKAndRequirementTrace|CargoWorkspaceAndDevelopmentGates|SchemeModuleOwnership|CIWorkflows)", "-v"}},
			{"scheme-policy-library", "cargo", []string{"build", "-p", "weaver-policy-ffi", "--locked", "--offline"}},
			{"scheme-build-capacity", "cargo", []string{"run", "-p", "weaver-policy-ffi", "--example", "compile_scheme", "--locked", "--offline", "--", "resources"}},
			{"scheme-declared-poo-library", "cargo", []string{"run", "-p", "weaver-policy-ffi", "--example", "compile_scheme", "--locked", "--offline", "--", "dependencies"}},
			{"scheme-core-library", "cargo", []string{"run", "-p", "weaver-policy-ffi", "--example", "compile_scheme", "--locked", "--offline", "--", "core"}},
			{"scheme-module-build", "cargo", []string{"run", "-p", "weaver-policy-ffi", "--example", "compile_scheme", "--locked", "--offline"}},
			{"scheme-build-environment-tests", goBinary, []string{"-C", "go", "test", "-count=1", "-race", "-tags=schemeintegration", "./internal/devrunner", "-run", "^Test(SchemePkgConfig|ImageTool|SourceInputsWithArchived)", "-v"}},
			// Package tools own discovery, execution and result reporting. Historical
			// direct-gxi image experiments are not a prerequisite for gerbil test.
			{"scheme-unit-tests", schemeTool(), []string{"test", "-g", "-v", "5", "t"}},
			{"scheme-grpc-stream-integration", goBinary, []string{"-C", "go", "test", "-count=1", "-race", "-tags=integration,schemeintegration", "./dev", "-run", "^TestProviderControl", "-v"}},
		}, nil
	case "bench":
		return []Stage{
			{"project-architecture", goBinary, []string{"-C", "go", "test", "-count=1", "./dev", "-run", "^Test(ProjectArchitecture|SysMLSDKAndRequirementTrace|CargoWorkspaceAndDevelopmentGates|SchemeModuleOwnership|CIWorkflows)", "-v"}},
			{"rust-environment", "rustc", []string{"-vV"}},
			{"go-environment", goBinary, []string{"-C", "go", "version"}},
			{"benchmark-package-contract", goBinary, []string{"-C", "go", "test", "-count=1", "./dev", "./internal/devrunner", "-run", "^Test(CargoWorkspaceAndDevelopmentGates|Benchmark.*)$"}},
			{"rust-benchmarks", "cargo", []string{"bench", "--workspace", "--all-features", "--bench", "gateway", "--locked", "--offline", "--", "--noplot"}},
			{"grpc-benchmark", goBinary, []string{"-C", "go", "test", "-tags=integration", "./dev", "-run", "^$", "-bench", "^BenchmarkGateway(Inspect|InspectReconnect|AuthorityPublish)$", "-benchtime=2s", "-count=3", "-benchmem"}},
		}, nil
	case "generate-rpc":
		return []Stage{
			{"go-protobuf-generator", goBinary, []string{"-C", "go", "build", "-o", "../.cache/protoc-gen-go", "google.golang.org/protobuf/cmd/protoc-gen-go"}},
			{"go-grpc-generator", goBinary, []string{"-C", "go", "build", "-o", "../.cache/protoc-gen-go-grpc", "google.golang.org/grpc/cmd/protoc-gen-go-grpc"}},
			{"protobuf-generation", "protoc", []string{"--plugin=protoc-gen-go=.cache/protoc-gen-go", "--plugin=protoc-gen-go-grpc=.cache/protoc-gen-go-grpc", "--go_out=go/api", "--go_opt=module=github.com/HardenedLinux/weaver/go/api", "--go-grpc_out=go/api", "--go-grpc_opt=module=github.com/HardenedLinux/weaver/go/api", "-I", "proto", "proto/gateway/v1/gateway.proto"}},
		}, nil
	default:
		return nil, fmt.Errorf("unknown development mode: %s", mode)
	}
}
