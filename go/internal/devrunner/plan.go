package devrunner

import (
	"fmt"
	"os"
)

const rustRuntimeFeatures = "weaver-server/arrow,weaver-governance/scheme-vm"

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
		{"lean-json-integration", goBinary, []string{"-C", "go", "test", "-count=1", "-tags=proofintegration", "./internal/devrunner", "-run", "^TestLeanJSONCompilerAndRunner$", "-v"}},
		{"project-architecture", goBinary, []string{"-C", "go", "test", "-count=1", "./dev", "-run", "^Test(ProjectArchitecture|SysMLSDKAndRequirementTrace|CargoWorkspaceAndDevelopmentGates|SchemeModuleOwnership|CIWorkflows)", "-v"}},
		{"workflow-contract", "actionlint", nil},
		{"rust-format", "cargo", []string{"fmt", "--all", "--", "--check"}},
		{"rust-default-profile", "cargo", []string{"check", "--workspace", "--all-targets", "--locked", "--offline"}},
		{"rust-tests", "cargo", []string{"test", "--workspace", "--features", rustRuntimeFeatures, "--locked", "--offline"}},
		{"rust-clippy", "cargo", []string{"clippy", "--workspace", "--features", rustRuntimeFeatures, "--all-targets", "--locked", "--offline", "--", "-D", "warnings"}},
		{"go-fuzz-control-build", goBinary, []string{"-C", "go", "test", "-c", "./internal/devrunner/testdata/fuzzcontrol", "-o", "../.cache/fuzz-control.test"}},
		{"go-tests", goBinary, []string{"-C", "go", "test", "-count=1", "-race", "./..."}},
		{"go-model-view-source-pbt", goBinary, []string{"-C", "go", "test", "./internal/devrunner", "-run", "^$", "-fuzz", "^FuzzModelViewCaptureTracksSource$", "-fuzztime=3s"}},
		{"go-model-description-pbt", goBinary, []string{"-C", "go", "test", "./internal/devrunner", "-run", "^$", "-fuzz", "^FuzzModelDescriptionUsesInheritedSDKAttributes$", "-fuzztime=3s"}},
		{"go-lean-json-pbt", goBinary, []string{"-C", "go", "test", "./internal/devrunner", "-run", "^$", "-fuzz", "^FuzzLeanJSONSourceAndDeclarationBinding$", "-fuzztime=3s"}},
		{"go-failure-evidence-pbt", goBinary, []string{"-C", "go", "test", "./internal/devrunner", "-run", "^$", "-fuzz", "^FuzzFailureExcerptRetainsPrecedingDiagnostic$", "-fuzztime=3s"}},
		{"go-benchmark-evidence-pbt", goBinary, []string{"-C", "go", "test", "./internal/devrunner", "-run", "^$", "-fuzz", "^FuzzBenchmarkGoRowsPreserveMeasurements$", "-fuzztime=3s"}},
		{"go-arrow-allocation-pbt", goBinary, []string{"-C", "go", "test", "./internal/gatewayclient", "-run", "^$", "-fuzz", "^FuzzArrowAllocationBudget$", "-fuzztime=3s"}},
		{"go-arrow-observation-pbt", goBinary, []string{"-C", "go", "test", "./internal/gatewayclient", "-run", "^$", "-fuzz", "^FuzzArrowObservationRoundTrip$", "-fuzztime=3s"}},
		{"go-routing-pbt", goBinary, []string{"-C", "go", "test", "./internal/routing", "-run", "^$", "-fuzz", "^FuzzRoutingRefinement$", "-fuzztime=3s"}},
		{"go-decoder-pbt", goBinary, []string{"-C", "go", "test", "./api/v1", "-run", "^$", "-fuzz", "FuzzDecoderNeverPanics", "-fuzztime=3s"}},
		{"go-stream-pbt", goBinary, []string{"-C", "go", "test", "./internal/streaming", "-run", "^$", "-fuzz", "FuzzMessageBounds", "-fuzztime=3s"}},
		{"quint-stream-tests", "quint", []string{"test", "dev/proofs/quint/StreamingExecution.qnt", "--main", "StreamingExecution", "--seed", "293"}},
		{"quint-stream-safety", "quint", []string{"run", "dev/proofs/quint/StreamingExecution.qnt", "--main", "StreamingExecution", "--invariant", "safe", "--max-samples", "1000", "--max-steps", "60", "--seed", "293"}},
		{"quint-lifecycle-tests", "quint", []string{"test", "dev/proofs/quint/RuntimeLifecycle.qnt", "--main", "RuntimeLifecycle", "--seed", "293"}},
		{"quint-lifecycle-safety", "quint", []string{"run", "dev/proofs/quint/RuntimeLifecycle.qnt", "--main", "RuntimeLifecycle", "--invariant", "safe", "--max-samples", "1000", "--max-steps", "60", "--seed", "293"}},
		{"lean-stream", "elan", []string{"run", proofToolchain, "lean", "--json", "dev/proofs/lean/StreamingExecution.lean"}},
		{"cedar-proof-bridge", "elan", []string{"run", proofToolchain, "lake", "-d", "dev/proofs/cedar", "build"}},
		leanArchitectureStage(),
		{"quint-typecheck", "quint", []string{"typecheck", "dev/proofs/quint/RuntimeAdmission.qnt"}},
		{"quint-tests", "quint", []string{"test", "dev/proofs/quint/RuntimeAdmission.qnt", "--main", "RuntimeAdmission", "--seed", "293"}},
		{"quint-safety", "quint", []string{"run", "dev/proofs/quint/RuntimeAdmission.qnt", "--main", "RuntimeAdmission", "--invariant", "safety", "--max-samples", "1000", "--max-steps", "50", "--seed", "293"}},
		{"lean", "elan", []string{"run", proofToolchain, "lean", "--json", "dev/proofs/lean/RuntimeAdmission.lean"}},
		{"turso-atomicity-tests", "quint", []string{"test", "dev/proofs/quint/TursoAdmission.qnt", "--main", "TursoAdmission", "--seed", "293"}},
		{"turso-mvcc-tests", "quint", []string{"test", "dev/proofs/quint/TursoMvcc.qnt", "--main", "TursoMvcc", "--seed", "293"}},
		{"turso-mvcc-safety", "quint", []string{"run", "dev/proofs/quint/TursoMvcc.qnt", "--main", "TursoMvcc", "--invariant", "safety", "--max-samples", "1000", "--max-steps", "60", "--seed", "293"}},
		{"shared-domains-tests", "quint", []string{"test", "dev/proofs/quint/SharedDomains.qnt", "--main", "SharedDomains", "--seed", "293"}},
		{"task-origin-tests", "quint", []string{"test", "dev/proofs/quint/TaskOrigin.qnt", "--main", "TaskOrigin", "--seed", "293"}},
		{"task-origin-safety", "quint", []string{"run", "dev/proofs/quint/TaskOrigin.qnt", "--main", "TaskOrigin", "--invariant", "safety", "--max-samples", "1000", "--max-steps", "60", "--seed", "293"}},
		{"shared-domains-safety", "quint", []string{"run", "dev/proofs/quint/SharedDomains.qnt", "--main", "SharedDomains", "--invariant", "safety", "--max-samples", "1000", "--max-steps", "60", "--seed", "293"}},
		{"shared-domains-lean", "elan", []string{"run", proofToolchain, "lean", "--json", "dev/proofs/lean/SharedDomains.lean"}},
		{"turso-atomicity-safety", "quint", []string{"run", "dev/proofs/quint/TursoAdmission.qnt", "--main", "TursoAdmission", "--invariant", "safety", "--max-samples", "1000", "--max-steps", "60", "--seed", "293"}},
		{"provider-routing-pbt", goBinary, []string{"-C", "go", "test", "./internal/routing", "-run", "^$", "-fuzz", "FuzzProviderPlanCannotExpandAuthority", "-fuzztime=3s"}},
		{"provider-routing-ownership-pbt", goBinary, []string{"-C", "go", "test", "./internal/routing", "-run", "^$", "-fuzz", "FuzzCompiledProviderOwnsRouteOrder", "-fuzztime=3s"}},
		{"provider-stream-ownership-pbt", goBinary, []string{"-C", "go", "test", "./internal/gatewayclient", "-run", "^$", "-fuzz", "FuzzProviderExecutionOwnsRouteObservation", "-fuzztime=3s"}},
		{"source-task-ownership-pbt", goBinary, []string{"-C", "go", "test", "./internal/gatewayclient", "-run", "^$", "-fuzz", "FuzzTaskRequestOwnsMutableFields", "-fuzztime=3s"}},
		{"publication-snapshot-pbt", goBinary, []string{"-C", "go", "test", "./internal/gatewayclient", "-run", "^$", "-fuzz", "FuzzPublicationStagesRetainOriginalParent", "-fuzztime=3s"}},
		{"llm-routing-quint-tests", "quint", []string{"test", "dev/proofs/quint/LlmRouting.qnt", "--main", "LlmRouting", "--seed", "293"}},
		{"llm-routing-quint-safety", "quint", []string{"run", "dev/proofs/quint/LlmRouting.qnt", "--main", "LlmRouting", "--invariant", "safety", "--max-samples", "1000", "--max-steps", "60", "--seed", "293"}},
		{"provider-request-bounds-pbt", goBinary, []string{"-C", "go", "test", "./internal/routing", "-run", "^$", "-fuzz", "FuzzProviderRequestBounds", "-fuzztime=3s"}},
		{"provider-profile-schema-pbt", goBinary, []string{"-C", "go", "test", "./api/v1", "-run", "^$", "-fuzz", "FuzzProviderProfileRequestFacts", "-fuzztime=3s"}},
		{"provider-profile-config-pbt", goBinary, []string{"-C", "go", "test", "./internal/config", "-run", "^$", "-fuzz", "FuzzProviderProfileConfiguration", "-fuzztime=3s"}},
		{"profile-registry-quint-tests", "quint", []string{"test", "dev/proofs/quint/ProviderProfile.qnt", "--main", "ProviderProfile", "--seed", "293"}},
		{"profile-registry-quint-safety", "quint", []string{"run", "dev/proofs/quint/ProviderProfile.qnt", "--main", "ProviderProfile", "--invariant", "safe", "--max-samples", "1000", "--max-steps", "60", "--seed", "293"}},
		{"provider-quint-tests", "quint", []string{"test", "dev/proofs/quint/ProviderRpc.qnt", "--main", "ProviderRpc", "--seed", "293"}},
		{"provider-quint-safety", "quint", []string{"run", "dev/proofs/quint/ProviderRpc.qnt", "--main", "ProviderRpc", "--invariant", "safe", "--max-samples", "1000", "--max-steps", "60", "--seed", "293"}},
		{"provider-lean", "elan", []string{"run", proofToolchain, "lean", "--json", "dev/proofs/lean/ProviderRpc.lean"}},
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
		{"publication-local-review-safety", "quint", []string{"run", "dev/proofs/quint/PublicationRecovery.qnt", "--main", "PublicationRecovery", "--step", "localReviewedStep", "--invariant", "localReviewSafe", "--max-samples", "1000", "--max-steps", "60", "--seed", "293"}},
		{"publication-source-key-safety", "quint", []string{"run", "dev/proofs/quint/PublicationRecovery.qnt", "--main", "PublicationRecovery", "--step", "sourceRecoverySchedule", "--invariant", "sourceDecisionSafe", "--max-samples", "1000", "--max-steps", "60", "--seed", "293", "--verbosity", "0"}},
		{"publication-retained-source-safety", "quint", []string{"run", "dev/proofs/quint/PublicationRecovery.qnt", "--main", "PublicationRecovery", "--step", "retainedSourceRecoverySchedule", "--invariant", "sourceDecisionSafe", "--max-samples", "1000", "--max-steps", "60", "--seed", "293", "--verbosity", "0"}},
		{"publication-lean", "elan", []string{"run", proofToolchain, "lean", "--json", "dev/proofs/lean/PublicationRecovery.lean"}},
		{"source-owner-quint-tests", "quint", []string{"test", "dev/proofs/quint/SourceOwner.qnt", "--main", "SourceOwner", "--seed", "293"}},
		{"source-owner-quint-safety", "quint", []string{"run", "dev/proofs/quint/SourceOwner.qnt", "--main", "SourceOwner", "--invariant", "safe", "--max-samples", "1000", "--max-steps", "60", "--seed", "293"}},
		{"go-provider-grpc-integration", goBinary, []string{"-C", "go", "test", "-count=1", "-race", "-tags=integration", "./dev", "-run", "TestProvider", "-v"}},
		{"control-bundle-pbt", goBinary, []string{"-C", "go", "test", "./internal/config", "-run", "^$", "-fuzz", "FuzzSourceBundleCannotExpandOriginalSelection", "-fuzztime=3s"}},
		{"authority-publication-quint-tests", "quint", []string{"test", "dev/proofs/quint/AuthorityPublication.qnt", "--main", "AuthorityPublication", "--seed", "293", "--match", "^authority[A-Z]"}},
		{"authority-publication-quint-safety", "quint", []string{"run", "dev/proofs/quint/AuthorityPublication.qnt", "--main", "AuthorityPublication", "--invariant", "safe", "--max-samples", "1000", "--max-steps", "60", "--seed", "293"}},
		{"semantic-boundary-quint-tests", "quint", []string{"test", "dev/proofs/quint/LlmPolicyContinuation.qnt", "--main", "LlmPolicyContinuation", "--seed", "293"}},
		{"gateway-program-quint-tests", "quint", []string{"test", "dev/proofs/quint/GatewayProgram.qnt", "--main", "GatewayProgram", "--seed", "293"}},
		{"gateway-program-quint-safety", "quint", []string{"run", "dev/proofs/quint/GatewayProgram.qnt", "--main", "GatewayProgram", "--invariant", "safe", "--max-samples", "1000", "--max-steps", "60", "--seed", "293"}},
		{"semantic-boundary-quint-safety", "quint", []string{"run", "dev/proofs/quint/LlmPolicyContinuation.qnt", "--main", "LlmPolicyContinuation", "--step", "boundaryStep", "--invariant", "safety", "--max-samples", "1000", "--max-steps", "60", "--seed", "293", "--verbosity", "0"}},
	}
}
func Stages(mode, goBinary string) ([]Stage, error) {
	switch mode {
	case "bootstrap":
		return []Stage{
			{"rust-dependencies", "cargo", []string{"fetch", "--locked"}},
			{"go-dependencies", goBinary, []string{"-C", "go", "mod", "download"}},
			{"proof-toolchain", "elan", []string{"run", "--install", proofToolchain, "lean", "--version"}},
			{"proof-dependencies", "elan", []string{"run", proofToolchain, "lake", "-d", "dev/proofs/cedar", "build"}},
		}, nil
	case "check":
		return Plan(goBinary), nil
	case "check-storage":
		selected := []Stage{
			{"project-architecture", goBinary, []string{"-C", "go", "test", "-count=1", "./dev", "-run", "^Test(ProjectArchitecture|SysMLSDKAndRequirementTrace|CargoWorkspaceAndDevelopmentGates)", "-v"}},
			{"storage-rust-format", "cargo", []string{"fmt", "--all", "--", "--check"}},
			{"storage-workspace-types", "cargo", []string{"check", "--workspace", "--all-targets", "--locked", "--offline"}},
			{"storage-rust-tests", "cargo", []string{"test", "-p", "weaver-ledger", "-p", "weaver-execution", "--locked", "--offline"}},
			{"storage-rust-clippy", "cargo", []string{"clippy", "-p", "weaver-ledger", "-p", "weaver-execution", "--all-targets", "--locked", "--offline", "--", "-D", "warnings"}},
			{"storage-final-benchmark", "cargo", []string{"bench", "-p", "weaver-ledger", "--bench", "gateway", "--locked", "--offline", "--", "ledger/(final_family_pair|task_origin_registration)"}},
		}
		for _, stage := range Plan(goBinary) {
			if stage.Name == "lean" || stage.Name == "lean-stream" || stage.Name == "quint-stream-tests" || stage.Name == "quint-stream-safety" || stage.Name == "turso-atomicity-tests" || stage.Name == "turso-atomicity-safety" || stage.Name == "turso-mvcc-tests" || stage.Name == "turso-mvcc-safety" || stage.Name == "shared-domains-tests" || stage.Name == "shared-domains-safety" || stage.Name == "shared-domains-lean" || stage.Name == "task-origin-tests" || stage.Name == "task-origin-safety" {
				selected = append(selected, stage)
			}
		}
		return append(selected, Stage{"storage-grpc-integration", goBinary, []string{"-C", "go", "test", "-count=1", "-race", "-tags=integration", "./dev", "-run", "^TestProvider", "-v"}}), nil
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
				mode == "check-go" && stage.Binary == goBinary && stage.Name != "lean-json-integration" ||
				mode == "check-policy" && (stage.Binary == "quint" || stage.Binary == "elan" || stage.Name == "lean-json-integration")
			if common || language {
				selected = append(selected, stage)
			}
		}
		return selected, nil
	case "check-telemetry":
		return []Stage{
			{"project-architecture", goBinary, []string{"-C", "go", "test", "-count=1", "./dev", "./internal/devrunner", "-run", "^Test(ProjectArchitecture|SysML|CargoWorkspace|Benchmark|ModelViewsUseActualSDK)"}},
			{"rust-format", "cargo", []string{"fmt", "--all", "--", "--check"}},
			{"telemetry-rust", "cargo", []string{"test", "-p", "weaver-telemetry", "-p", "weaver-server", "--lib", "--locked", "--offline"}},
			{"telemetry-go", goBinary, []string{"-C", "go", "test", "-count=1", "-race", "./internal/telemetry", "./internal/controlplane"}},
			{"telemetry-integration", goBinary, []string{"-C", "go", "test", "-count=1", "-race", "-tags=integration", "./dev", "-run", "^TestProvider(Telemetry|ControlTelemetry|RevocationDuringSSE|PartialRequestAndRestartRetainUnknownClaim|ControlJSONYAMLRevocationAndRestart|ControlCompleteStreamsShareBudgetAndRejectSDKRetry|ControlPublicationReplyLossCannotActivateOrRebase)", "-v"}},
			{"telemetry-quint", "quint", []string{"test", "dev/proofs/quint/TursoMvcc.qnt", "--main", "TursoMvcc", "--seed", "293"}},
			{"telemetry-safety", "quint", []string{"run", "dev/proofs/quint/TursoMvcc.qnt", "--main", "TursoMvcc", "--invariant", "safety", "--max-samples", "1000", "--max-steps", "60", "--seed", "293"}},
			{"telemetry-lean", "elan", []string{"run", proofToolchain, "lean", "--json", "dev/proofs/lean/RuntimeAdmission.lean"}},
			{"telemetry-benchmark", "cargo", []string{"bench", "-p", "weaver-telemetry", "--bench", "gateway", "--locked", "--offline", "--", "--noplot"}},
		}, nil
	case "check-scheme":
		return []Stage{
			{"project-architecture", goBinary, []string{"-C", "go", "test", "-count=1", "./dev", "-run", "^Test(ProjectArchitecture|SysMLSDKAndRequirementTrace|CargoWorkspaceAndDevelopmentGates|SchemeModuleOwnership|CIWorkflows)", "-v"}},
			{"scheme-policy-library", "cargo", []string{"build", "-p", "weaver-policy-ffi", "--locked", "--offline"}},
			{"scheme-policy-preflight", "cargo", []string{"test", "-p", "weaver-policy-ffi", "--lib", "--benches", "--locked", "--offline"}},
			{"scheme-policy-pkg-config", "cargo", []string{"run", "-p", "weaver-policy-ffi", "--example", "policy_pkg_config", "--locked", "--offline"}},
			{"scheme-module-build", schemeTool(), []string{"build", "-g"}},
			{"scheme-build-environment-tests", goBinary, []string{"-C", "go", "test", "-count=1", "-race", "-tags=schemeintegration", "./internal/devrunner", "-run", "^(Test(SchemePkgConfig|SchemeTool|SchemePackageResult|SchemeTestInventory|SchemeUsesPackageTestEntry|SourceInputsWithArchived)|FuzzSchemePackageResultProtocol)", "-v"}},
			// Package tools own discovery, execution and result reporting. Historical
			// direct-gxi image experiments are not a prerequisite for gerbil test.
			{"scheme-unit-tests", schemeTool(), []string{"test", "-g", "-v", "5", "t"}},
			{"scheme-source-integration-tests", schemeTool(), []string{"test", "-g", "-v", "5", "t/integration"}},
			{"scheme-rooted-sdk-integration", "cargo", []string{"test", "-p", "weaver-governance", "-p", "weaver-governance-build", "-p", "weaver-server", "--features", "weaver-governance/scheme-qualification,weaver-server/governance-qualification", "--locked", "--offline"}},
			{"scheme-grpc-stream-integration", goBinary, []string{"-C", "go", "test", "-count=1", "-race", "-tags=integration,schemeintegration", "./dev", "-run", "^TestProviderControl", "-v"}},
		}, nil
	case "bench-execution":
		return []Stage{
			{"execution-benchmark-target", goBinary, []string{"-C", "go", "test", "-count=1", "-tags=integration", "./internal/devrunner", "-run", "^TestCargoBenchmarkTargetFollowsCargoConfiguration$", "-v"}},
			{"execution-policy-tests", "cargo", []string{"test", "-p", "weaver-policy", "--locked", "--offline"}},
			{"execution-backend-tests", "cargo", []string{"test", "-p", "weaver-ledger", "-p", "weaver-execution", "-p", "weaver-server", "--features", "weaver-server/arrow", "--locked", "--offline"}},
			{"execution-policy-benchmark", "cargo", []string{"bench", "-p", "weaver-policy", "--bench", "gateway", "--locked", "--offline", "--", "policy/context_", "--noplot"}},
			{"execution-ledger-benchmark", "cargo", []string{"bench", "-p", "weaver-ledger", "--bench", "gateway", "--locked", "--offline", "--", "ledger/provider_release/", "--noplot"}},
			{"execution-provider-benchmark", "cargo", []string{"bench", "-p", "weaver-execution", "--bench", "gateway", "--locked", "--offline", "--", "execution/https_guarded_sse_three_events", "--noplot"}},
			{"execution-encoding-benchmark", "cargo", []string{"bench", "-p", "weaver-server", "--features", "arrow", "--bench", "gateway", "--locked", "--offline", "--", "server/encoding_guard_hold", "--noplot"}},
			{"execution-contention-pair", goBinary, []string{"-C", "go", "test", "-count=1", "-tags=integration", "./dev", "-run", "^TestContentionPairs$", "-v"}},
			{"execution-provider-integration", goBinary, []string{"-C", "go", "test", "-count=1", "-race", "-tags=integration", "./dev", "-run", "^TestProvider", "-v"}},
			{"published-pipeline-benchmark", goBinary, []string{"-C", "go", "test", "-tags=integration", "./dev", "-run", "^$", "-bench", "^BenchmarkGatewayPublishedPipeline$", "-benchtime=1x", "-count=3", "-benchmem"}},
			{"execution-streaming-pair", goBinary, []string{"-C", "go", "test", "-tags=integration", "./dev", "-run", "^$", "-bench", "^BenchmarkGatewayStreamingPair$", "-benchtime=1x", "-count=1", "-benchmem"}},
		}, nil
	case "bench-runtime":
		return []Stage{
			{"scheme-policy-library", "cargo", []string{"build", "-p", "weaver-policy-ffi", "--locked", "--offline"}},
			{"scheme-policy-pkg-config", "cargo", []string{"run", "-p", "weaver-policy-ffi", "--example", "policy_pkg_config", "--locked", "--offline"}},
			{"runtime-source-admission-pbt", goBinary, []string{"-C", "go", "test", "./internal/config", "-run", "^$", "-fuzz", "^FuzzFrozenAdmissionPreservesValidation$", "-fuzztime=3s"}},
			{"runtime-source-ownership-pbt", goBinary, []string{"-C", "go", "test", "./internal/controlplane", "-run", "^$", "-fuzz", "^FuzzCompiledSourceOwnershipAndBinding$", "-fuzztime=3s"}},
			{"runtime-projection-benchmark", goBinary, []string{"-C", "go", "test", "./internal/controlplane", "-run", "^$", "-bench", "^BenchmarkCompiledSourceAdmission$", "-benchtime=200ms", "-count=3", "-benchmem"}},
			{"runtime-pipeline-benchmark", goBinary, []string{"-C", "go", "test", "-tags=integration,schemeintegration", "./dev", "-run", "^$", "-bench", "^BenchmarkGatewayCompiledPipeline$", "-benchtime=1x", "-count=3", "-benchmem"}},
		}, nil
	case "bench":
		return []Stage{
			{"project-architecture", goBinary, []string{"-C", "go", "test", "-count=1", "./dev", "-run", "^Test(ProjectArchitecture|SysMLSDKAndRequirementTrace|CargoWorkspaceAndDevelopmentGates|SchemeModuleOwnership|CIWorkflows)", "-v"}},
			{"rust-environment", "rustc", []string{"-vV"}},
			{"go-environment", goBinary, []string{"-C", "go", "version"}},
			{"benchmark-package-contract", goBinary, []string{"-C", "go", "test", "-count=1", "./dev", "./internal/devrunner", "-run", "^Test(CargoWorkspaceAndDevelopmentGates|Benchmark.*)$"}},
			{"rust-benchmarks", "cargo", []string{"bench", "--workspace", "--features", rustRuntimeFeatures, "--bench", "gateway", "--locked", "--offline", "--", "--noplot"}},
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
