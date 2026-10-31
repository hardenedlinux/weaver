package WeaverProject {
    doc /* Deterministic Engineering project authority. Named layout parts are
       repository-relative paths. The Go OpenSysML SDK gate checks the declared
       owners, package inventories, runtime dependency edges and required files.
       This structural contract does not grant runtime execution authority. */

    part def Directory;
    part def File;
    part def IgnoredDirectory;
    part def Absent;
    part def RuntimeDependency;
    part def ProhibitedExtension;
    part def VerificationSuite;
    part def VerificationMode;
    part def GoPackage;
    part def VerificationResponsibility;
    part def RuntimeGoEntry;
    part def DevelopmentGoEntry;
    part def RuntimeSourceRoot;
    part def RuntimeInput;
    part def ForbiddenRuntimeRoot;
    part def ForbiddenRuntimeReference;
    part def RuntimeAssetRoot;
    part def RustPackage {
        part 'Cargo.toml' : File;
        part src : Directory;
        part tests : Directory;
        part 'benches/gateway.rs' : File;
        part 'benches/README.org' : File;
    }
    part def SchemeModule {
        part 'types.ss' : File;
        part 'objects.ss' : File;
        part 'func.ss' : File;
        part 'config.ss' : File;
        part 'interface.ss' : File;
    }

    package SourcePolicy {
        part '.py' : ProhibitedExtension;
    }

    requirement def ProductionAssetBoundary {
        doc /* Production imports, compilation, startup and packaging must not
           depend on dev files or development-only packages. Runtime-consumed
           Cedar Policy/schema/manifests belong under prod and are explicitly
           registered in Layout. Validation sources and raw proof outputs remain
           development assets. Promotion validates and owns deployable bytes;
           runtime loading may not follow a link back into dev. A prod path alone
           establishes neither current authority nor permission to publish. */
    }
    requirement productionAssets : ProductionAssetBoundary;

    package RuntimeBoundary {
        part dev : ForbiddenRuntimeRoot;
        part 'go/dev' : ForbiddenRuntimeRoot;
        part 'go/internal/devrunner' : ForbiddenRuntimeRoot;
        part prod : RuntimeAssetRoot;
        part 'go/cmd/weaver-control' : RuntimeGoEntry;
        part 'go/cmd/weaver-dev' : DevelopmentGoEntry;
        part 'scheme' : RuntimeSourceRoot;
        part 'proto' : RuntimeSourceRoot;
        part 'Cargo.toml' : RuntimeInput;
        part 'build.ss' : RuntimeInput;
        part 'init.ss' : RuntimeInput;
        part 'gerbil.pkg' : RuntimeInput;
        part 'github.com/HardenedLinux/weaver/go/dev' : ForbiddenRuntimeReference;
        part 'github.com/HardenedLinux/weaver/go/internal/devrunner' : ForbiddenRuntimeReference;
        part ':hardenedlinux/weaver/dev' : ForbiddenRuntimeReference;
        part 'weaver-dev' : ForbiddenRuntimeReference;
        doc /* Rust src/build inputs derive from Layout.RustPackage. Go inputs
           derive from the declared runtime entry dependency closure, including
           imports and embed directives. Development tools are outside that
           closure; a production import of one is rejected, never exempted. */
    }

    package Verification {
        part rust : VerificationSuite { part 'check-rust' : VerificationMode; }
        part go : VerificationSuite { part 'check-go' : VerificationMode; }
        part scheme : VerificationSuite { part 'check-scheme' : VerificationMode; }
        part architecture : VerificationSuite { part 'check-architecture' : VerificationMode; }
        part policy : VerificationSuite { part 'check-policy' : VerificationMode; }
        part benchmarks : VerificationSuite { part bench : VerificationMode; }
    }

    package AssuranceResponsibilities {
        doc /* Sole responsibility registry. Documents and diagrams reference
           these owners; they do not create parallel verification designs. */
        part specification : VerificationResponsibility {
            doc /* SysML owns component allocation, typed boundaries and named
               requirements. SDK structural analysis is not behavioral proof. */
        }
        part schedules : VerificationResponsibility {
            doc /* Quint owns concurrent/fault schedules and unsafe counterexamples.
               Extend existing publication/execution models rather than duplicate
               their ledgers. It does not reimplement Cedar evaluation or prove
               arbitrary Scheme/Rust programs. Credential semantics enter as
               qualified opaque references; only read/use ordering is modeled. */
        }
        part semantics : VerificationResponsibility {
            doc /* Lean reuses cedar-poo-spec and Cedar semantic/refinement
               theorems with explicit authenticity/materialization premises.
               No second control/activation/CAS state machine is introduced.
               Credential subject/key/scope/audience meanings have one SPEC
               definition; downstream Lean only applies its composition laws.
               Solver reports and finite replay records are not kernel proofs. */
        }
        part implementation : VerificationResponsibility {
            doc /* Scheme/Rust/Go PBT and integration suites establish
               concrete composition, FFI, parsing, SQL and transport behavior.
               Inherited POO property testing, Proptest and Go testing.F own generation, shrinking, corpora and
               replay. Property contracts, independent oracles and typed command
               models precede Runtime changes; command runners only launch suites.
               They do not turn finite cases into universal theorems. */
        }
    }

    package DesignProcess {
        private import ScalarValues::*;
        doc /* Project engineering process, not a Gateway runtime state machine.
           A changed design invalidates downstream review decisions. Discussion
           confirms the advantage and scope; production work starts only after
           the complete reviewed design is explicitly confirmed. */
        enum def DesignStage {
            enum advantageDiscussion;
            enum sysmlArchitecture;
            enum crossReview;
            enum overallConfirmation;
            enum implementation;
        }
        enum def ReviewDisposition {
            enum proposed;
            enum confirmed;
            enum reworkRequired;
        }
        item def DesignReviewRecord {
            attribute designIdentity : String;
            attribute scopeIdentity : String;
            attribute evidenceIdentity : String;
            attribute comparisonMetricIdentity : String;
            attribute decisionMaker : String;
            attribute stage : DesignStage;
            attribute disposition : ReviewDisposition;
            doc /* Every round report binds its scoped Weaver/Box/OpenShell
               comparison and evidence-progress metric. Targets, inspected
               reference source and executed acceptance remain distinguishable.
               This review metric is not a financial settlement signal. */
        }
        port def ReviewPort { out item decision : DesignReviewRecord; }
        part def ReviewStage {
            port incoming : ~ReviewPort;
            port confirmed : ReviewPort;
            port rework : ReviewPort;
            doc /* Confirmation applies to one exact design and scope. Rework
               cannot also confirm that design. Merely running a checker or
               finding a proof file is not a confirmation decision. */
        }
        part cycle {
            part discussion : ReviewStage;
            part architecture : ReviewStage;
            part review : ReviewStage;
            part confirmation : ReviewStage;
            part implementation : ReviewStage;
            connect discussion.confirmed to architecture.incoming;
            connect architecture.confirmed to review.incoming;
            connect review.confirmed to confirmation.incoming;
            connect confirmation.confirmed to implementation.incoming;
            connect architecture.rework to discussion.incoming;
            connect review.rework to discussion.incoming;
            connect confirmation.rework to discussion.incoming;
            connect implementation.rework to discussion.incoming;
        }
    }

    package Architecture {
        doc /* Zero Trust is the mandatory core model, not an optional plugin.
           Every extension preserves authenticated original identity, explicit
           authority, current actual-effect authorization and failure-closed
           claim/budget/history recovery. Higher-order Governance composes within
           this model; assessment, cached proof and telemetry are not send permits.
           Deployment containment and source freshness contracts have explicit
           scopes and cannot stand in for this end-to-end execution boundary. */
        doc /* cedar-poo-spec is the core reusable semantic library, jointly
           maintained upstream. Its existing Policy/Delta/Admission/Rust replay
           capabilities are reused. The upstream Gateway Lean library composes
           admission with execution Delta; Weaver owns scenario-specific Rust
           execution, durable CAS and qualified storage/transport adapters. */
        part cedarLibrary : WeaverExecution::CedarSecurityFrameworks;
        part semantics : WeaverExecution::SchemeSemanticPublisher;
        part control : WeaverExecution::GoControlAdapter;
        part policy : WeaverExecution::RustPolicy;
        part ledger : WeaverExecution::RustLedger;
        part broker : WeaverExecution::RustFinalBroker;
        part executor : WeaverExecution::HttpsExecutor;
        part telemetry : WeaverExecution::TelemetryService;
    }

    package Layout {
        part crates : Directory;
        part go : Directory;
        part scheme : Directory;
        part prod : Directory;
        part dev : Directory;
        part t : Directory;
        part docs : Directory;
        part proto : Directory;
        part examples : Directory;
        part '.github' : Directory;

        part 'Project.sysml' : File;
        part '.gitignore' : File;
        part 'Cargo.toml' : File;
        part 'Cargo.lock' : File;
        part 'rust-toolchain.toml' : File;
        part 'go.work' : Absent;
        part 'go.work.sum' : Absent;
        part 'go/go.mod' : File;
        part 'go/go.sum' : File;
        part 'gerbil.pkg' : File;
        part 'build.ss' : File;
        part 'init.ss' : File;
        part 'proto/gateway/v1/gateway.proto' : File;
        part '.github/workflows/ci.yml' : File;
        part '.github/workflows/verify-suite.yml' : File;
        part '.github/actions/prepare-toolchain/action.yml' : File;
        part 'scheme/policy/cedar-ffi.ss' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.24-telemetry-service.org' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.25-openshell-and-tao3k-ecosystem.org' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.26-semantic-execution-ecosystem.d2' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.27-policy-evidence-architecture.org' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.28-ascent-mrr-and-fact-review.org' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.29-strands-box-cross-review.org' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.30-governance-adapter-acceptance.org' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.30-governance-adapter-acceptance.d2' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.40-core-gateway-library.org' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.41-authority-read-final-cas.org' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.42-independent-commit-floor.org' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.43-floor-transport-owner.org' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.43-floor-transport-owner.d2' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.44-cloud-rpc-arrow-boundaries.org' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.44-cloud-rpc-arrow-boundaries.d2' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.45-slow-consumer-zero-trust.org' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.45-slow-consumer-zero-trust.d2' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.45-slow-consumer-zero-trust.svg' : File;
        part 'dev/proofs/cedar/ZeroTrustEnrichment.lean' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.46-functional-security-frameworks.org' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.46-functional-security-frameworks.d2' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.46-functional-security-frameworks.svg' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.49-policy-proposal-barrier.org' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.49-policy-proposal-barrier.d2' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.49-policy-proposal-barrier.svg' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.50-parent-contract-and-replay.org' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.50-parent-contract-and-replay.d2' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.50-parent-contract-and-replay.svg' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.51-zero-trust-architecture.org' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.51-zero-trust-architecture.d2' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.51-zero-trust-architecture.svg' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.52-reviewed-publication-cas.org' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.52-reviewed-publication-cas.d2' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.52-reviewed-publication-cas.svg' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.53-artifact-registry-recovery.org' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.53-artifact-registry-recovery.d2' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.53-artifact-registry-recovery.svg' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.54-source-incarnation-authority.org' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.54-source-incarnation-authority.d2' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.54-source-incarnation-authority.svg' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.55-native-reviewed-publication.org' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.55-native-reviewed-publication.d2' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.55-native-reviewed-publication.svg' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.56-runtime-assets-and-authority-floor.org' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.56-runtime-assets-and-authority-floor.d2' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.56-runtime-assets-and-authority-floor.svg' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.57-schema-bound-candidate-replay.org' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.57-schema-bound-candidate-replay.d2' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.57-schema-bound-candidate-replay.svg' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.58-independent-source-recovery.org' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.58-independent-source-recovery.d2' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.58-independent-source-recovery.svg' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.59-retained-root-and-recovery-coverage.org' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.59-retained-root-and-recovery-coverage.d2' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.59-retained-root-and-recovery-coverage.svg' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.60-persistent-source-key-custody.org' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.60-persistent-source-key-custody.d2' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.60-persistent-source-key-custody.svg' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.61-authority-bound-replay-pair.org' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.61-authority-bound-replay-pair.d2' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.61-authority-bound-replay-pair.svg' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.62-burn-exposure-recovery.org' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.62-burn-exposure-recovery.d2' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.62-burn-exposure-recovery.svg' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.63-mrr-admission-contract.org' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.63-mrr-admission-contract.d2' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.63-mrr-admission-contract.svg' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.65-turso-concurrent-admission.org' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.65-turso-concurrent-admission.d2' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.65-turso-concurrent-admission.svg' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.66-bounded-writer-reuse.org' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.66-bounded-writer-reuse.d2' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.66-bounded-writer-reuse.svg' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.67-writer-owner-lifecycle.org' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.67-writer-owner-lifecycle.d2' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.67-writer-owner-lifecycle.svg' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.68-cpu-matched-writer-review.org' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.69-hot-path-cost-boundaries.org' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.69-hot-path-cost-boundaries.d2' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.69-hot-path-cost-boundaries.svg' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.70-borrowed-validation-dispatch.org' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.64-governance-capture-ownership.org' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.64-governance-capture-ownership.d2' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.64-governance-capture-ownership.svg' : File;

        part 'crates/contracts' : RustPackage;
        part 'crates/governance' : RustPackage {
            doc /* Own checked concrete source records after a
               synchronous native Scheme strong-root conversion. No VM object survives in
               OwnedSource; conversion and transport confer no publication/send
               authority. Program graph/export admission remains host-owned. The scheme-vm feature
               exposes conversion only; scheme-qualification links the test graph.
               SourceExpectation retains the independently admitted original
               before producer invocation; BoundSource compares the whole typed
               image and remains inert data, never a publication/send permit. */
            doc /* SourceClient/SourceInbox bound queued, running and unread
               ready work on an existing tracked blocking owner. The VM remains
               owner-thread local. Terminal close and cancellation fence future
               delivery; active foreign calls drain naturally before join.
               This lane has no publication, execution or budget authority. */
            part 'weaver-contracts' : RuntimeDependency;
        }
        part 'crates/governance-build' : RustPackage;
        part 'crates/policy' : RustPackage {
            doc /* Reuse the existing fixed cedar-poo-spec revision's Rust
               runtime for schema-bound replay, declared IDs and entity checks.
               Official materialized PolicySet JSON retains named policy identity;
               text-renderer comments are never treated as identity metadata.
               Finite replay supplies no no-gain, registrar or execution authority. */
            part 'weaver-contracts' : RuntimeDependency;
        }
        part 'crates/policy-ffi' : RustPackage {
            part 'weaver-policy' : RuntimeDependency;
        }
        part 'crates/ledger' : RustPackage {
            part 'weaver-contracts' : RuntimeDependency;
            part 'weaver-policy' : RuntimeDependency;
        }
        part 'crates/execution' : RustPackage {
            part 'weaver-contracts' : RuntimeDependency;
            part 'weaver-ledger' : RuntimeDependency;
        }
        part 'crates/server' : RustPackage {
            part 'weaver-contracts' : RuntimeDependency;
            part 'weaver-ledger' : RuntimeDependency;
            part 'weaver-execution' : RuntimeDependency;
        }
        part 'crates/contracts/benches/support' : Directory;
        part 'crates/policy/benches/support' : Directory;
        part 'crates/ledger/benches/support' : Directory;

        part 'go/api/v1' : GoPackage;
        part 'go/api/gateway/v1' : GoPackage;
        part 'go/cmd/weaver-control' : GoPackage;
        part 'go/cmd/weaver-dev' : GoPackage;
        part 'go/dev' : GoPackage;
        part 'go/internal/config' : GoPackage;
        part 'go/internal/controlplane' : GoPackage;
        part 'go/internal/devrunner' : GoPackage;
        part 'go/internal/gatewayclient' : GoPackage;
        part 'go/internal/routing' : GoPackage;
        part 'go/internal/streaming' : GoPackage;
        part 'go/internal/devrunner/testdata/fuzzcontrol' : Directory;

        part 'scheme/governance' : SchemeModule;
        part 'scheme/policy' : SchemeModule;
        part 'scheme/gateway' : SchemeModule;
        part 't/gateway-contracts-test.ss' : File;
        part 't/governance-test.ss' : File;
        part 't/policy-test.ss' : File;
        part 't/fixtures/governed-control.ss' : File {
            doc /* Test-only library compiled by the root standard Gerbil build;
               integration imports its canonical package module. No executable
               or production Governance capability is introduced. */
        }

        part 'prod/policies/provider/schema.json' : File;
        part 'prod/policies/provider/provider.cedar' : File;
        part 'prod/policies/provider/profile.json' : File;
        part 'prod/policies/provider/profile.yaml' : File;
        part 'prod/policies/provider/request-cases.json' : File;
        part 'prod/policies/review/namespaced-enum-validated.json' : File;
        part 'prod/policies/review/named-permit.json' : File;
        part 'prod/policies/review/named-forbid.json' : File;
        part 'prod/policies/review/README.org' : File;
        part 'prod/policies/streaming/schema.json' : File;
        part 'prod/policies/streaming/stream.cedar' : File;
        part 'prod/policies/README.org' : File;
        part 'prod/policies/verification.org' : File;
        part 'dev/proofs/quint' : Directory;
        part 'dev/proofs/lean' : Directory;
        part 'dev/proofs/cedar' : Directory;
        part 'dev/sysml' : Directory;
        part 'dev/sysml/WeaverExecution.sysml' : File;
        part 'dev/sysml/StreamingExecution.sysml' : File;
        part 'dev/sysml/ProviderRpc.sysml' : File;
        part 'dev/sysml/ControlActivation.sysml' : File;
        part 'dev/sysml/PolicyEvidenceDesign.sysml' : File;
        part 'dev/sysml/runtime-trace.json' : File;

        part '.cache' : IgnoredDirectory;
        part '.data' : IgnoredDirectory;
        part target : IgnoredDirectory;
        part '.devenv' : IgnoredDirectory;

        part 'dev/benchmarks' : Absent;
        part api : Absent;
        part 'dev/policies' : Absent;
        part 'dev/fixtures/policies' : Absent;
        part 'scheme/modules' : Absent;
        part 'scheme/weaver' : Absent;
        part 'scheme/gerbil.pkg' : Absent;
        part 'packages/server' : Absent;
        part 'packages/control' : Absent;
        part 'dev/models' : Absent;
        part 'dev/toolchains/go' : Absent;
        part '.github/workflows/assurance.yml' : Absent;
    }

    allocation governanceCode allocate Architecture::semantics to Layout::'scheme/governance';
    allocation configurationCode allocate Architecture::semantics to Layout::'scheme/gateway';
    allocation controlCode allocate Architecture::control to Layout::'go/internal/controlplane';
    allocation cedarCode allocate Architecture::policy to Layout::'crates/policy';
    allocation cedarBridgeCode allocate Architecture::policy to Layout::'crates/policy-ffi';
    allocation ledgerCode allocate Architecture::ledger to Layout::'crates/ledger';
    allocation brokerCode allocate Architecture::broker to Layout::'crates/execution';
    allocation transportCode allocate Architecture::executor to Layout::'crates/execution';
    allocation telemetryDesign allocate Architecture::telemetry to Layout::'docs/50-59-research-program/59-provider-rpc/59.24-telemetry-service.org';
}
