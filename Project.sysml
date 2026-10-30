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

    package Architecture {
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
