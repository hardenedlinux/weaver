// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package devrunner

import (
	"fmt"
	"os"
	"slices"
)

const rustRuntimeFeatures = "weaver-server/arrow,weaver-governance/scheme-vm"
const providerSpecReviewCase = "^TestProviderRealSPECReviewRevocationLostRepliesAndRestart$"

const proofToolchain = "leanprover/lean4:v4.35.0"

func schemeTool() string {
	if tool := os.Getenv("WEAVER_SCHEME_TOOL"); tool != "" {
		return tool
	}
	return "gerbil"
}

// SchemeQualificationCargoArgs defines the one Cargo graph for the native
// qualification tests and the executable used by the Go fixtures.
func SchemeQualificationCargoArgs() []string {
	return []string{"test", "-p", "weaver-governance", "-p", "weaver-governance-build", "-p", "weaver-server",
		"--features", "weaver-governance/scheme-qualification,weaver-server/governance-qualification,weaver-server/arrow",
		"--locked", "--offline", "-j", "4"}
}

func Plan(goBinary string) []Stage {
	return []Stage{
		{"rust-environment", "rustc", []string{"-vV"}},
		{"go-environment", goBinary, []string{"-C", "go", "version"}},
		{"quint-environment", "quint", []string{"--version"}},
		{"proof-environment", "elan", []string{"run", proofToolchain, "lean", "--version"}},
		{"lean-json-integration", goBinary, []string{"-C", "go", "test", "-count=1", "-tags=proofintegration", "./internal/devrunner", "-run", "^TestLeanJSONCompilerAndRunner$", "-v"}},
		{"spec-real-qualification", goBinary, []string{"-C", "go", "test", "-race", "-count=1", "-tags=proofintegration", "./internal/specreview"}},
		{"project-architecture", goBinary, []string{"-C", "go", "test", "-count=1", "./dev", "-run", "^Test(ProjectArchitecture|SysMLSDKAndRequirementTrace|CargoWorkspace|CIWorkflows)", "-v"}},
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
		{"provider-egress-window-quint-tests", "quint", []string{"test", "dev/proofs/quint/ProviderEgressWindow.qnt", "--main", "ProviderEgressWindow", "--seed", "293"}},
		{"provider-egress-window-quint-safety", "quint", []string{"run", "dev/proofs/quint/ProviderEgressWindow.qnt", "--main", "ProviderEgressWindow", "--invariant", "safety", "--max-samples", "2000", "--max-steps", "80", "--seed", "293"}},
		{"provider-egress-window-lean", "elan", []string{"run", proofToolchain, "lean", "--json", "dev/proofs/lean/ProviderEgressWindow.lean"}},
		{"provider-egress-promotion-quint-tests", "quint", []string{"test", "dev/proofs/quint/ProviderEgressPromotion.qnt", "--main", "ProviderEgressPromotion", "--seed", "293"}},
		{"provider-egress-promotion-quint-safety", "quint", []string{"run", "dev/proofs/quint/ProviderEgressPromotion.qnt", "--main", "ProviderEgressPromotion", "--invariant", "safe", "--max-samples", "2000", "--max-steps", "80", "--seed", "293"}},
		{"provider-admission-turn-tests", "quint", []string{"test", "dev/proofs/quint/ProviderAdmissionTurn.qnt", "--main", "ProviderAdmissionTurn", "--seed", "293"}},
		{"provider-admission-turn-safety", "quint", []string{"run", "dev/proofs/quint/ProviderAdmissionTurn.qnt", "--main", "ProviderAdmissionTurn", "--invariant", "safe", "--max-samples", "2000", "--max-steps", "80", "--seed", "293"}},
		{"provider-admission-turn-lean", "elan", []string{"run", proofToolchain, "lean", "--json", "dev/proofs/lean/ProviderAdmissionTurn.lean"}},
		{"provider-read-custody-tests", "quint", []string{"test", "dev/proofs/quint/ProviderReadCustody.qnt", "--main", "ProviderReadCustody", "--seed", "293"}},
		{"provider-read-custody-safety", "quint", []string{"run", "dev/proofs/quint/ProviderReadCustody.qnt", "--main", "ProviderReadCustody", "--invariant", "safe", "--max-samples", "2000", "--max-steps", "80", "--seed", "293"}},
		{"provider-read-custody-lean", "elan", []string{"run", proofToolchain, "lean", "--json", "dev/proofs/lean/ProviderReadCustody.lean"}},
		{"provider-lifecycle-footprint-tests", "quint", []string{"test", "dev/proofs/quint/ProviderLifecycleFootprint.qnt", "--main", "ProviderLifecycleFootprint", "--seed", "293"}},
		{"provider-lifecycle-footprint-safety", "quint", []string{"run", "dev/proofs/quint/ProviderLifecycleFootprint.qnt", "--main", "ProviderLifecycleFootprint", "--invariant", "safe", "--max-samples", "2000", "--max-steps", "80", "--seed", "293"}},
		{"provider-lifecycle-footprint-lean", "elan", []string{"run", proofToolchain, "lean", "--json", "dev/proofs/lean/ProviderLifecycleFootprint.lean"}},
		{"provider-snapshot-publication-tests", "quint", []string{"test", "dev/proofs/quint/ProviderSnapshotPublication.qnt", "--main", "ProviderSnapshotPublication", "--seed", "293"}},
		{"provider-snapshot-publication-safety", "quint", []string{"run", "dev/proofs/quint/ProviderSnapshotPublication.qnt", "--main", "ProviderSnapshotPublication", "--invariant", "safe", "--max-samples", "2000", "--max-steps", "80", "--seed", "293"}},
		{"provider-snapshot-publication-lean", "elan", []string{"run", proofToolchain, "lean", "--json", "dev/proofs/lean/ProviderSnapshotPublication.lean"}},
		{"provider-semantic-progress-tests", "quint", []string{"test", "dev/proofs/quint/ProviderSemanticProgress.qnt", "--main", "ProviderSemanticProgress", "--seed", "293"}},
		{"provider-semantic-progress-safety", "quint", []string{"run", "dev/proofs/quint/ProviderSemanticProgress.qnt", "--main", "ProviderSemanticProgress", "--invariant", "safe", "--max-samples", "2000", "--max-steps", "80", "--seed", "293"}},
		{"provider-semantic-progress-lean", "elan", []string{"run", proofToolchain, "lean", "--json", "dev/proofs/lean/ProviderSemanticProgress.lean"}},
		{"provider-delivery-join-quint-tests", "quint", []string{"test", "dev/proofs/quint/ProviderDeliveryJoin.qnt", "--main", "ProviderDeliveryJoin", "--seed", "293"}},
		{"provider-delivery-join-quint-safety", "quint", []string{"run", "dev/proofs/quint/ProviderDeliveryJoin.qnt", "--main", "ProviderDeliveryJoin", "--invariant", "safe", "--max-samples", "2000", "--max-steps", "80", "--seed", "293"}},
		{"provider-delivery-pipeline-quint-tests", "quint", []string{"test", "dev/proofs/quint/ProviderDeliveryPipeline.qnt", "--main", "ProviderDeliveryPipeline", "--seed", "293"}},
		{"provider-delivery-pipeline-quint-safety", "quint", []string{"run", "dev/proofs/quint/ProviderDeliveryPipeline.qnt", "--main", "ProviderDeliveryPipeline", "--invariant", "safe", "--max-samples", "2000", "--max-steps", "80", "--seed", "293"}},
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
		{"provider-write-fence-tests", "quint", []string{"test", "dev/proofs/quint/ProviderRequestFence.qnt", "--main", "ProviderRequestFence", "--seed", "293"}},
		{"provider-write-fence-safety", "quint", []string{"run", "dev/proofs/quint/ProviderRequestFence.qnt", "--main", "ProviderRequestFence", "--invariant", "safe", "--max-samples", "1000", "--max-steps", "60", "--seed", "293"}},

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
		{"publication-producer-review-safety", "quint", []string{"run", "dev/proofs/quint/PublicationRecovery.qnt", "--main", "PublicationRecovery", "--step", "producerReviewSchedule", "--invariant", "producerReviewSafe", "--max-samples", "1000", "--max-steps", "60", "--seed", "293", "--verbosity", "0"}},
		{"publication-qualified-review-safety", "quint", []string{"run", "dev/proofs/quint/PublicationRecovery.qnt", "--main", "PublicationRecovery", "--step", "qualifiedProducerSchedule", "--invariant", "qualifiedProducerSafe", "--max-samples", "1000", "--max-steps", "60", "--seed", "293", "--verbosity", "0"}},
		{"spec-proof-closure-integration", goBinary, []string{"-C", "go", "test", "-race", "-count=1", "-tags=proofintegration", "./internal/devrunner", "-run", "^TestSPECProofClosure", "-v"}},
		{"spec-qualified-composition", "elan", []string{"run", proofToolchain, "lake", "-d", "dev/proofs/cedar", "env", "lean", "--json", "dev/proofs/cedar/QualifiedReview.lean"}},
		{"domain-spec-composition", "elan", []string{"run", proofToolchain, "lake", "-d", "dev/proofs/cedar", "env", "lean", "--json", "dev/proofs/cedar/DomainMigrationComposition.lean"}},
		{"model-closure-positive", "elan", []string{"run", proofToolchain, "lake", "-d", "dev/proofs/cedar", "env", "lean", "--json", "dev/proofs/cedar/ModelClosure.lean"}},
		{"finite-domain-model-tests", "quint", []string{"test", "dev/specs/quint/FiniteDomainMigration.qnt", "--main", "FiniteDomainMigration", "--seed", "293"}},
		{"finite-domain-model-safety", "quint", []string{"run", "dev/specs/quint/FiniteDomainMigration.qnt", "--main", "FiniteDomainMigration", "--invariant", "safety", "--max-samples", "1000", "--max-steps", "60", "--seed", "293"}},
		{"head-domain-composition-tests", "quint", []string{"test", "dev/proofs/quint/GatewayHeadCAS.qnt", "--main", "GatewayHeadCAS", "--seed", "293"}},
		{"head-domain-composition-safety", "quint", []string{"run", "dev/proofs/quint/GatewayHeadCAS.qnt", "--main", "GatewayHeadCAS", "--invariant", "safety", "--max-samples", "1000", "--max-steps", "60", "--seed", "293"}},
		{"publication-lean", "elan", []string{"run", proofToolchain, "lean", "--json", "dev/proofs/lean/PublicationRecovery.lean"}},
		{"source-owner-quint-tests", "quint", []string{"test", "dev/proofs/quint/SourceOwner.qnt", "--main", "SourceOwner", "--seed", "293"}},
		{"source-owner-quint-safety", "quint", []string{"run", "dev/proofs/quint/SourceOwner.qnt", "--main", "SourceOwner", "--invariant", "safe", "--max-samples", "1000", "--max-steps", "60", "--seed", "293"}},
		{"go-provider-server-build", "cargo", []string{"build", "-p", "weaver-server", "--bin", "weaver-server", "--features", "arrow", "--locked", "--offline", "-j", "4"}},
		{"go-provider-observer-build", "cargo", []string{"test", "-p", "weaver-server", "--lib", "--features", "arrow", "--locked", "--offline", "-j", "4", "--no-run"}},
		{"go-provider-grpc-integration", goBinary, []string{"-C", "go", "test", "-json", "-count=1", "-race", "-tags=integration", "-timeout=10m", "./dev", "-run", "TestProvider", "-skip", providerSpecReviewCase}},
		{"policy-provider-spec-integration", goBinary, []string{"-C", "go", "test", "-count=1", "-race", "-tags=integration", "-timeout=4m", "./dev", "-run", providerSpecReviewCase, "-v"}},
		{"control-bundle-pbt", goBinary, []string{"-C", "go", "test", "./internal/config", "-run", "^$", "-fuzz", "FuzzSourceBundleCannotExpandOriginalSelection", "-fuzztime=3s"}},
		{"authority-publication-quint-tests", "quint", []string{"test", "dev/proofs/quint/AuthorityPublication.qnt", "--main", "AuthorityPublication", "--seed", "293", "--match", "^authority[A-Z]"}},
		{"authority-publication-quint-safety", "quint", []string{"run", "dev/proofs/quint/AuthorityPublication.qnt", "--main", "AuthorityPublication", "--invariant", "safe", "--max-samples", "1000", "--max-steps", "60", "--seed", "293"}},
		{"semantic-boundary-quint-tests", "quint", []string{"test", "dev/proofs/quint/LlmPolicyContinuation.qnt", "--main", "LlmPolicyContinuation", "--seed", "293"}},
		{"gateway-program-quint-tests", "quint", []string{"test", "dev/proofs/quint/GatewayProgram.qnt", "--main", "GatewayProgram", "--seed", "293"}},
		{"gateway-program-quint-safety", "quint", []string{"run", "dev/proofs/quint/GatewayProgram.qnt", "--main", "GatewayProgram", "--invariant", "safe", "--max-samples", "1000", "--max-steps", "60", "--seed", "293"}},
		{"semantic-boundary-quint-safety", "quint", []string{"run", "dev/proofs/quint/LlmPolicyContinuation.qnt", "--main", "LlmPolicyContinuation", "--step", "boundaryStep", "--invariant", "safety", "--max-samples", "1000", "--max-steps", "60", "--seed", "293", "--verbosity", "0"}},
	}
}

const testParallelism = "4"

func Stages(mode, goBinary string) ([]Stage, error) {
	stages, err := stagesForMode(mode, goBinary)
	for i, stage := range stages {
		if stage.Binary == goBinary && len(stage.Args) >= 3 && stage.Args[0] == "-C" && stage.Args[2] == "test" {
			stages[i].Args = slices.Insert(stage.Args, 3, "-parallel="+testParallelism)
		}
	}
	return stages, err
}

func stagesForMode(mode, goBinary string) ([]Stage, error) {
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
			{"project-architecture", goBinary, []string{"-C", "go", "test", "-count=1", "./dev", "-run", "^Test(ProjectArchitecture|SysMLSDKAndRequirementTrace|CargoWorkspace)", "-v"}},
			{"storage-rust-format", "cargo", []string{"fmt", "--all", "--", "--check"}},
			{"storage-workspace-types", "cargo", []string{"check", "--workspace", "--all-targets", "--locked", "--offline"}},
			{"storage-rust-tests", "cargo", []string{"test", "-p", "weaver-ledger", "-p", "weaver-broker", "--locked", "--offline"}},
			{"storage-rust-clippy", "cargo", []string{"clippy", "-p", "weaver-ledger", "-p", "weaver-broker", "--all-targets", "--locked", "--offline", "--", "-D", "warnings"}},
			{"storage-final-benchmark", "cargo", []string{"bench", "-p", "weaver-ledger", "--bench", "gateway", "--locked", "--offline", "--", "ledger/(final_family_pair|task_origin_registration)"}},
		}
		for _, stage := range Plan(goBinary) {
			if stage.Name == "lean" || stage.Name == "lean-stream" || stage.Name == "quint-stream-tests" || stage.Name == "quint-stream-safety" || stage.Name == "turso-atomicity-tests" || stage.Name == "turso-atomicity-safety" || stage.Name == "turso-mvcc-tests" || stage.Name == "turso-mvcc-safety" || stage.Name == "shared-domains-tests" || stage.Name == "shared-domains-safety" || stage.Name == "shared-domains-lean" || stage.Name == "task-origin-tests" || stage.Name == "task-origin-safety" {
				selected = append(selected, stage)
			}
		}
		return append(selected, Stage{"storage-grpc-integration", goBinary, []string{"-C", "go", "test", "-count=1", "-race", "-tags=integration", "./dev", "-run", "^TestProvider", "-v"}}), nil
	case "bootstrap-build", "bootstrap-proofs":
		stages, err := stagesForMode("bootstrap", goBinary)
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
			providerBuild := stage.providerBuild()
			proofGo := stage.Name == "lean-json-integration" || stage.Name == "spec-real-qualification" ||
				stage.Name == "spec-proof-closure-integration" || stage.Name == "policy-provider-spec-integration"
			language := mode == "check-rust" && !providerBuild && (stage.Binary == "cargo" || stage.Binary == "rustc") ||
				mode == "check-go" && (providerBuild || stage.Binary == goBinary && !proofGo) ||
				mode == "check-policy" && (providerBuild || stage.Binary == "quint" || stage.Binary == "elan" || proofGo)
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
			{"project-architecture", goBinary, []string{"-C", "go", "test", "-count=1", "./dev", "-run", "^Test(ProjectArchitecture|SysMLSDKAndRequirementTrace|CargoWorkspace|CIWorkflows)", "-v"}},
			{"scheme-policy-library", "cargo", []string{"build", "-p", "weaver-policy-ffi", "--locked", "--offline"}},
			{"scheme-policy-preflight", "cargo", []string{"test", "-p", "weaver-policy-ffi", "--lib", "--benches", "--locked", "--offline"}},
			{"scheme-policy-pkg-config", "cargo", []string{"run", "-p", "weaver-policy-ffi", "--example", "policy_pkg_config", "--locked", "--offline"}},
			{"scheme-module-build", "./build.ss", []string{"compile", "--debug"}},
			{"scheme-build-environment-tests", goBinary, []string{"-C", "go", "test", "-count=1", "-race", "-tags=schemeintegration", "./internal/devrunner", "-run", "^(Test(SchemePkgConfig|SchemeTool|SchemePackageResult|SchemeTestInventory|SchemeUsesPackageTestEntry|SourceInputsWithArchived)|FuzzSchemePackageResultProtocol)", "-v"}},
			// Package tools own discovery, execution and result reporting. Historical
			// direct-gxi image experiments are not a prerequisite for gerbil test.
			{"scheme-unit-tests", schemeTool(), []string{"test", "-g", "-v", "5", "t"}},
			{"scheme-module-selection-integration", schemeTool(), []string{"test", "-g", "-v", "5", "t/qualification/module-selection"}},
			{"scheme-source-integration-tests", schemeTool(), []string{"test", "-g", "-v", "5", "t/integration"}},
			{"scheme-provider-server-build", "cargo", append(SchemeQualificationCargoArgs(), "--no-run")},
			{"scheme-rooted-sdk-integration", "cargo", SchemeQualificationCargoArgs()},
			{"scheme-grpc-stream-integration", goBinary, []string{"-C", "go", "test", "-json", "-count=1", "-race", "-tags=integration,schemeintegration", "-timeout=10m", "./dev", "-run", "^TestProviderControl", "-skip", "^TestProviderControlGovernorPerformance$"}},
		}, nil
	case "bench-execution":
		return []Stage{
			{"execution-benchmark-target", goBinary, []string{"-C", "go", "test", "-count=1", "-tags=integration", "./internal/devrunner", "-run", "^TestCargoBenchmarkTargetFollowsCargoConfiguration$", "-v"}},
			{"execution-policy-tests", "cargo", []string{"test", "-p", "weaver-policy", "--locked", "--offline"}},
			{"execution-backend-tests", "cargo", []string{"test", "-p", "weaver-ledger", "-p", "weaver-broker", "-p", "weaver-server", "--features", "weaver-server/arrow", "--locked", "--offline"}},
			{"execution-policy-benchmark", "cargo", []string{"bench", "-p", "weaver-policy", "--bench", "gateway", "--locked", "--offline", "--", "policy/context_", "--noplot"}},
			{"execution-ledger-benchmark", "cargo", []string{"bench", "-p", "weaver-ledger", "--bench", "gateway", "--locked", "--offline", "--", "ledger/provider_release/", "--noplot"}},
			{"execution-provider-benchmark", "cargo", []string{"bench", "-p", "weaver-broker", "--bench", "gateway", "--locked", "--offline", "--", "broker/https_guarded_sse_three_events", "--noplot"}},
			{"execution-encoding-benchmark", "cargo", []string{"bench", "-p", "weaver-server", "--features", "arrow", "--bench", "gateway", "--locked", "--offline", "--", "server/encoding_guard_hold", "--noplot"}},
			{"execution-delivery-join-pair", goBinary, []string{"-C", "go", "test", "-mod=readonly", "-tags=integration", "./dev", "-run", "^$", "-bench", "^BenchmarkProviderDeliveryJoin$", "-benchtime=1x", "-count=1", "-v"}},
			{"execution-lifecycle-footprint-pair", goBinary, []string{"-C", "go", "test", "-mod=readonly", "-tags=integration", "./dev", "-run", "^$", "-bench", "^BenchmarkProviderLifecycleFootprint$", "-benchtime=1x", "-count=1", "-v"}},
			{"execution-read-custody-pair", goBinary, []string{"-C", "go", "test", "-mod=readonly", "-tags=integration", "./dev", "-run", "^$", "-bench", "^BenchmarkProviderReadCustody$", "-benchtime=1x", "-count=1", "-v"}},
			{"execution-admission-turn-pair", goBinary, []string{"-C", "go", "test", "-mod=readonly", "-tags=integration", "./dev", "-run", "^$", "-bench", "^BenchmarkProviderAdmissionTurn$", "-benchtime=1x", "-count=1", "-v"}},
			{"execution-admission-overlap-pair", goBinary, []string{"-C", "go", "test", "-mod=readonly", "-tags=integration", "./dev", "-run", "^$", "-bench", "^BenchmarkProviderAdmissionOverlap$", "-benchtime=1x", "-count=1", "-v"}},
			{"execution-go-control-pair", goBinary, []string{"-C", "go", "test", "-mod=readonly", "-tags=integration", "./dev", "-run", "^$", "-bench", "^BenchmarkProviderGoControlPair$", "-benchtime=1x", "-count=1", "-v"}},
			{"execution-range-prepare-pair", goBinary, []string{"-C", "go", "test", "-mod=readonly", "-tags=integration", "./dev", "-run", "^$", "-bench", "^BenchmarkProviderRangePreparationGroup$", "-benchtime=1x", "-count=1", "-v"}},
			{"execution-scheduled-encoding-pair", goBinary, []string{"-C", "go", "test", "-mod=readonly", "-tags=integration", "./dev", "-run", "^$", "-bench", "^BenchmarkProviderScheduledEncoding$", "-benchtime=1x", "-count=1", "-v"}},
			{"execution-contention-pair", goBinary, []string{"-C", "go", "test", "-count=1", "-tags=integration", "./dev", "-run", "^TestContentionPairs$", "-v"}},
			{"execution-provider-integration", goBinary, []string{"-C", "go", "test", "-count=1", "-race", "-tags=integration", "./dev", "-run", "^TestProvider", "-v"}},
			{"published-pipeline-benchmark", goBinary, []string{"-C", "go", "test", "-tags=integration", "./dev", "-run", "^$", "-bench", "^BenchmarkGatewayPublishedPipeline$", "-benchtime=1x", "-count=3", "-benchmem"}},
			{"execution-header-seal-pair", goBinary, []string{"-C", "go", "test", "-count=1", "-tags=integration", "./dev", "-run", "^TestHeaderSealPairs$", "-v"}},
			{"execution-header-wait-pair", goBinary, []string{"-C", "go", "test", "-tags=integration", "./dev", "-run", "^$", "-bench", "^BenchmarkGatewayHeaderWaitPair$", "-benchtime=1x", "-count=1", "-benchmem"}},
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
			{"project-architecture", goBinary, []string{"-C", "go", "test", "-count=1", "./dev", "-run", "^Test(ProjectArchitecture|SysMLSDKAndRequirementTrace|CargoWorkspace|CIWorkflows)", "-v"}},
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
