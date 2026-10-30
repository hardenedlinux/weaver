package devrunner

import (
	"fmt"
	"os"
)

const proofToolchain = "leanprover/lean4:v4.34.1"

func Plan(goBinary string) []Stage {
	return []Stage{
		{"rust-environment", "rustc", []string{"-vV"}},
		{"go-environment", goBinary, []string{"version"}},
		{"quint-environment", "quint", []string{"--version"}},
		{"proof-environment", "elan", []string{"run", proofToolchain, "lean", "--version"}},
		{"workflow-contract", "actionlint", []string{".github/workflows/assurance.yml"}},
		{"rust-format", "cargo", []string{"fmt", "--all", "--", "--check"}},
		{"rust-default-profile", "cargo", []string{"check", "--workspace", "--all-targets", "--locked", "--offline"}},
		{"rust-tests", "cargo", []string{"test", "--workspace", "--all-features", "--locked", "--offline"}},
		{"rust-clippy", "cargo", []string{"clippy", "--workspace", "--all-features", "--all-targets", "--locked", "--offline", "--", "-D", "warnings"}},
		{"go-fuzz-control-build", goBinary, []string{"test", "-c", "./go/internal/devrunner/testdata/fuzzcontrol", "-o", ".cache/fuzz-control.test"}},
		{"go-tests", goBinary, []string{"test", "-count=1", "-race", "./go/..."}},
		{"go-routing-pbt", goBinary, []string{"test", "./go/internal/routing", "-run", "^$", "-fuzz", "FuzzCeilingNeverExpands", "-fuzztime=3s", "-parallel=1"}},
		{"go-decoder-pbt", goBinary, []string{"test", "./go/api/v1", "-run", "^$", "-fuzz", "FuzzDecoderNeverPanics", "-fuzztime=3s", "-parallel=1"}},
		{"go-stream-pbt", goBinary, []string{"test", "./go/internal/streaming", "-run", "^$", "-fuzz", "FuzzMessageBounds", "-fuzztime=3s", "-parallel=1"}},
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
		{"provider-routing-pbt", goBinary, []string{"test", "./go/internal/routing", "-run", "^$", "-fuzz", "FuzzProviderPlanCannotExpandAuthority", "-fuzztime=3s", "-parallel=1"}},
		{"provider-request-bounds-pbt", goBinary, []string{"test", "./go/internal/routing", "-run", "^$", "-fuzz", "FuzzProviderRequestBounds", "-fuzztime=3s", "-parallel=1"}},
		{"provider-profile-schema-pbt", goBinary, []string{"test", "./go/api/v1", "-run", "^$", "-fuzz", "FuzzProviderProfileRequestFacts", "-fuzztime=3s", "-parallel=1"}},
		{"provider-profile-config-pbt", goBinary, []string{"test", "./go/internal/config", "-run", "^$", "-fuzz", "FuzzProviderProfileConfiguration", "-fuzztime=3s", "-parallel=1"}},
		{"profile-registry-quint-tests", "quint", []string{"test", "dev/proofs/quint/ProviderProfile.qnt", "--main", "ProviderProfile", "--seed", "293"}},
		{"profile-registry-quint-safety", "quint", []string{"run", "dev/proofs/quint/ProviderProfile.qnt", "--main", "ProviderProfile", "--invariant", "safe", "--max-samples", "1000", "--max-steps", "60", "--seed", "293"}},
		{"provider-quint-tests", "quint", []string{"test", "dev/proofs/quint/ProviderRpc.qnt", "--main", "ProviderRpc", "--seed", "293"}},
		{"provider-quint-safety", "quint", []string{"run", "dev/proofs/quint/ProviderRpc.qnt", "--main", "ProviderRpc", "--invariant", "safe", "--max-samples", "1000", "--max-steps", "60", "--seed", "293"}},
		{"provider-lean", "elan", []string{"run", proofToolchain, "lean", "dev/proofs/lean/ProviderRpc.lean"}},
		{"dispatch-cancellation-tests", "quint", []string{"test", "dev/proofs/quint/DispatchCancellation.qnt", "--main", "DispatchCancellation", "--seed", "293"}},
		{"dispatch-cancellation-safety", "quint", []string{"run", "dev/proofs/quint/DispatchCancellation.qnt", "--main", "DispatchCancellation", "--invariant", "safe", "--max-samples", "1000", "--max-steps", "60", "--seed", "293"}},
		{"release-binding-tests", "quint", []string{"test", "dev/proofs/quint/ReleaseBinding.qnt", "--main", "ReleaseBinding", "--seed", "293"}},
		{"release-binding-safety", "quint", []string{"run", "dev/proofs/quint/ReleaseBinding.qnt", "--main", "ReleaseBinding", "--invariant", "safe", "--max-samples", "1000", "--max-steps", "60", "--seed", "293"}},
		{"admission-quint-tests", "quint", []string{"test", "dev/proofs/quint/NativeAdmission.qnt", "--main", "NativeAdmission", "--seed", "293"}},
		{"admission-quint-safety", "quint", []string{"run", "dev/proofs/quint/NativeAdmission.qnt", "--main", "NativeAdmission", "--invariant", "safe", "--max-samples", "1000", "--max-steps", "60", "--seed", "293"}},
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
		{"go-native-integration", goBinary, []string{"test", "-count=1", "-race", "-tags=integration", "./go/dev", "-run", "TestProvider", "-v"}},
		{"control-bundle-pbt", goBinary, []string{"test", "./go/internal/config", "-run", "^$", "-fuzz", "FuzzSourceBundleCannotExpandOriginalSelection", "-fuzztime=3s", "-parallel=1"}},
		{"control-activation-quint-tests", "quint", []string{"test", "dev/proofs/quint/ControlActivation.qnt", "--main", "ControlActivation", "--seed", "293"}},
		{"control-activation-quint-safety", "quint", []string{"run", "dev/proofs/quint/ControlActivation.qnt", "--main", "ControlActivation", "--invariant", "safe", "--max-samples", "1000", "--max-steps", "60", "--seed", "293"}},
		{"control-activation-lean", "elan", []string{"run", proofToolchain, "lean", "dev/proofs/lean/ControlActivation.lean"}},
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
	case "check-scheme":
		return []Stage{
			{"scheme-policy-library", "cargo", []string{"build", "-p", "weaver-policy-ffi", "--locked", "--offline"}},
			{"scheme-declared-poo-library", "cargo", []string{"run", "-p", "weaver-policy-ffi", "--example", "compile_scheme", "--locked", "--offline", "--", "dependencies"}},
			{"scheme-native-ffi", "cargo", []string{"run", "-p", "weaver-policy-ffi", "--example", "compile_scheme", "--locked", "--offline"}},
			// Delegate discovery and assertions to the SDK and Scheme-owned suites.
			// Check the returned result explicitly; success markers alone cannot pass.
			{"scheme-unit-tests", os.Getenv("WEAVER_CONTROL_SCHEME_COMPILER"), []string{"-e", "(dump-stack-trace? #f)", "-e", "(import (prefix-in :gerbil/tools/gxtest tests.))", "-e", "(unless (zero? (tests.main \"-g\" \"-v\" \"5\" \"t\")) (error \"Scheme test suite failed\"))"}},
			{"scheme-native-control-integration", goBinary, []string{"test", "-count=1", "-race", "-tags=integration,schemeintegration", "./go/dev", "-run", "^TestProviderControl", "-v"}},
		}, nil
	case "bench":
		return []Stage{
			{"rust-environment", "rustc", []string{"-vV"}},
			{"go-environment", goBinary, []string{"version"}},
			{"benchmark-package-contract", goBinary, []string{"test", "-count=1", "./go/dev", "./go/internal/devrunner", "-run", "^Test(CargoWorkspaceAndDevelopmentGates|Benchmark.*)$"}},
			{"rust-benchmarks", "cargo", []string{"bench", "--workspace", "--all-features", "--bench", "gateway", "--locked", "--offline", "-j", "2", "--", "--noplot"}},
			{"grpc-benchmark", goBinary, []string{"test", "-tags=integration", "./go/dev", "-run", "^$", "-bench", "^BenchmarkGateway(Inspect|InspectReconnect|AuthorityPublish)$", "-benchtime=2s", "-count=3", "-benchmem"}},
		}, nil
	case "generate-rpc":
		return []Stage{
			{"go-protobuf-generator", goBinary, []string{"build", "-o", ".cache/protoc-gen-go", "google.golang.org/protobuf/cmd/protoc-gen-go"}},
			{"go-grpc-generator", goBinary, []string{"build", "-o", ".cache/protoc-gen-go-grpc", "google.golang.org/grpc/cmd/protoc-gen-go-grpc"}},
			{"protobuf-generation", "protoc", []string{"--plugin=protoc-gen-go=.cache/protoc-gen-go", "--plugin=protoc-gen-go-grpc=.cache/protoc-gen-go-grpc", "--go_out=go/api", "--go_opt=module=github.com/HardenedLinux/weaver/go/api", "--go-grpc_out=go/api", "--go-grpc_opt=module=github.com/HardenedLinux/weaver/go/api", "-I", "api", "api/gateway/v1/gateway.proto"}},
		}, nil
	default:
		return nil, fmt.Errorf("unknown development mode: %s", mode)
	}
}
