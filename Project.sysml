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
               arbitrary Scheme/Rust programs. */
        }
        part semantics : VerificationResponsibility {
            doc /* Lean reuses cedar-poo-spec and Cedar semantic/refinement
               theorems with explicit authenticity/materialization premises.
               No second control/activation/CAS state machine is introduced.
               Solver reports and finite replay records are not kernel proofs. */
        }
        part implementation : VerificationResponsibility {
            doc /* Scheme suites and Rust/Go PBT/integration tests establish
               concrete composition, FFI, parsing, SQL and transport behavior.
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

        part 'crates/contracts' : RustPackage;
        part 'crates/policy' : RustPackage {
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
        part 't/fixtures/governed-control.ss' : File;

        part 'prod/policies/provider/schema.json' : File;
        part 'prod/policies/provider/provider.cedar' : File;
        part 'prod/policies/provider/profile.json' : File;
        part 'prod/policies/provider/profile.yaml' : File;
        part 'prod/policies/provider/request-cases.json' : File;
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
