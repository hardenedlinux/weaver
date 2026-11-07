// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package WeaverProject {
    doc /* Deterministic Engineering project authority. Named layout parts are
       repository-relative paths. The Go OpenSysML SDK gate checks the declared
       owners, package inventories, runtime dependency edges and required files.
       This structural contract does not grant runtime execution authority. */

    part def Directory;
    requirement def ArchitectureViewGrammar {
        doc /* Development-only D2 extension profiles live under dev/d2/themes. The shared render Library owns the engine, themes and export; Weaver supplies source-owned declarations and source checks. System,
           routing, flow, sequence, state, data and assurance views select
           subject-appropriate visual grammars rather than one global template.
           Named SysML views are rendered by the existing OpenSysML SDK from
           captured source bytes. Go derives README D2 from typed SysML view and
           inherited responsibility attributes plus current Lean JSON references;
           D2 retains visual configuration, not independently authored Questions,
           responsibilities or proof claims. Missing or stale proof evidence is
           explicitly unexecuted. Source changes invalidate the mapped declaration. The
           upstream functional Library owns model projection and image generation.
           README embeds the resulting architecture and Zero Trust SVGs directly.
           README figures share the Library sketchbook visual language: paper
           canvas, handwriting, engineering glyphs and measured sketch surfaces.
           Different review Questions select different model layouts, not an
           unrelated font or dark/editor palette for every page.
           Required Library semantics distinguish a source-bound Question role
           from an Answer's domain glyph; an ordinal is optional presentation,
           not that distinction. Measure the whole label/marker/glyph group and
           retain its alignment across themes and font metrics. Standalone SVG
           exports default to the declared opaque canvas; transparency is explicit.
           Declared vector surfaces retain their theme fill, border and drawing
           style in both PNG and SVG; the HTML preview is not a substitute for
           the consumed standalone image. Background loss must fail qualification.
           Consume these semantic primitives through a qualified upstream package;
           downstream glyph swaps or baseline corrections do not satisfy them.
           Public model-view composition retains native identities, arrowheads and
           captured wording; D2 declares graph preferences and visual roles.
           Disconnected text annotations cannot absorb connected subjects, and
           unsupported member notation cannot silently drop fields or endpoints.
           WASM capture uses a reclaimable compiler process scope; image export
           uses the host CPU count without a global runtime concurrency clamp.
           Missing SDK capabilities, stale captures or unresolved model selections
           must refuse generation rather than using a separate legacy renderer.
           The Go development owner renders local bundled assets with the actual
           host CPU count, records source identities and rejects changed inputs.
           Presentation cannot change runtime Policy, claims or proof premises. */
    }
    requirement architectureViews : ArchitectureViewGrammar;
    part def File;
    part def ExecutableFile :> File;
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
        doc /* The Scheme Module Interface and its native Contract own role
           semantics. The native package build qualifies selected products. */
        part 'types.ss' : File;
        part 'objects.ss' : File;
        part 'func.ss' : File;
        part 'config.ss' : File;
        part 'interface.ss' : File;
        part 'gerbil.pkg' : Absent;
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
        part 'go/cmd/weaver-import-provider' : RuntimeGoEntry;
        part 'go/cmd/weaver-meter' : RuntimeGoEntry;
        part 'go/cmd/weaver-dev' : DevelopmentGoEntry;
        part 'scheme' : RuntimeSourceRoot;
        part 'proto' : RuntimeSourceRoot;
        part 'Cargo.toml' : RuntimeInput;
        part 'build.ss' : RuntimeInput;
        part 'init.ss' : RuntimeInput;
        part 'gerbil.pkg' : RuntimeInput;
        part 'github.com/HardenedLinux/weaver/go/dev' : ForbiddenRuntimeReference;
        part 'github.com/HardenedLinux/weaver/go/internal/devrunner' : ForbiddenRuntimeReference;
        part 'github.com/Open-MBEE/OpenSysML' : ForbiddenRuntimeReference;
        part ':hardenedlinux/weaver/dev' : ForbiddenRuntimeReference;
        part 'weaver-dev' : ForbiddenRuntimeReference;
        doc /* Rust src/build inputs derive from Layout.RustPackage. Go inputs
           derive from the declared runtime entry dependency closure, including
           imports and embed directives. Development tools are outside that
           closure; a production import of one is rejected, never exempted. */
    }

    package ArtifactOrganization {
        doc /* Project-wide custody and lifecycle. SysML allocates the
           responsibilities. The intended executable declaration lives in
           Gerbil Scheme through the Weaver Scheme/POO Module system.
           Verification::Artifacts records the implemented CI paths until
           the executable projection can be checked against the workflow. */
        part def SchemeArtifactDeclaration;
        part def RustArtifactMaterializer;
        part def ReproducibleInput;
        part def NativeBuildProduct;
        part def VerificationRun;
        part def DerivedView;
        part def LocalQualification;
        part def ReleaseBundle;
        part def SiteRuntimeState;
        part def SiteQualification;

        part artifactPlan : SchemeArtifactDeclaration {
            doc /* Typed POO objects declare artifact kinds, relative layout,
               producers, identity bindings, publication scope and retention.
               The existing Module Interface exports the checked plan.
               Gerbil Build Packages compiles that export. Derive Rust input
               and the CI publication inventory from the same plan. A change
               to an admitted declaration invalidates both projections. */
        }
        part materialization : RustArtifactMaterializer {
            doc /* Rust consumes the versioned Scheme plan over the existing
               typed bridge or its build projection. Validate relative paths
               and required identity before materializing a typed record.
               Publish the immutable run record before advancing latest.
               Go and native tools supply observations. GitHub can still
               record early job failures before the native owner exists.
               Neither observation path may override Scheme publication rules.
               The Scheme declaration and Rust materializer are design work. */
        }
        part checkedInSources : ReproducibleInput {
            doc /* Git owns source, schemas, locks, deterministic fixtures and
               reproducible projections. A generated file in Git must have a
               checked-in recipe and a reproducibility check. Site data, local
               digests, and individual execution verdicts stay outside Git. */
        }
        part nativeBuild : NativeBuildProduct {
            doc /* Cargo and Gerbil Build Packages prepare and reuse their own
               outputs. The release consumer selects exact executable, linked
               image and package closure. Toolchain clean operates on owned
               outputs and does not remove verification evidence or site data. */
        }
        part verificationRuns : VerificationRun {
            doc /* weaver-dev and native suites produce verification outcomes.
               Rust materializes records from those observations under the
               Scheme plan once implemented. Verification::Artifacts declares
               the current local and CI paths. CI retains job attempts for seven days.
               The remaining local design retains an immutable run by identity
               before updating any latest view. A failed or incomplete attempt
               remains separately addressable and never qualifies the input. */
        }
        part reportViews : DerivedView {
            doc /* Org summaries and other views consume typed results. Views
               inherit their evidence identity and can be regenerated. Scratch
               is process-owned and cleaned on exit. Only structured diagnostics
               and explicitly retained historical evidence survive cleanup. */
        }
        part localSnakeOil : LocalQualification {
            doc /* Native Go integration owns local developer qualification.
               Use .cache/weaver-deployment-qualification/ as its dedicated
               root for generated catalogs, config and isolated ledgers. The
               design gives each new run a private subdirectory and binds the
               fixture and build identities in its typed result. Existing runs
               and original verdicts stay where they were recorded. */
        }
        part deployableRelease : ReleaseBundle {
            doc /* The release design freezes one digest-bound manifest for the
               selected executable or image, Gerbil package library and
               resolved closure, build inputs and toolchain revisions. The
               deployment owner verifies the delivered bytes. Project CI
               receipts alone cannot authorize release publication. */
        }
        part runtimeCustody : SiteRuntimeState {
            doc /* The site launcher supplies settings and a selected catalog.
               The Rust authority owns the persistent ledger. Keep catalog
               and ledger at separate paths on the site's persistent storage.
               A mutable ledger is bound to qualification by its admitted cut
               or verified snapshot, never by copying a live database into CI. */
        }
        part formalQualification : SiteQualification {
            doc /* Site approval, activation, catalog, replay and baseline cut
               bind to the same immutable release before sampling. The
               existing Governor preregistration governs A/A and retained A/B.
               Site authority retains these records and formal verdicts
               independently of CI expiry. Missing site records keep formal
               qualification pending. */
        }
    }

    package Verification {
        doc /* The Go verification owner inventories maintained project sources,
           the complete Lean/Quint/Cedar proof source trees and Org/D2 design
           sources. Gate inputs must be in that identity map. Before/after maps
           and optional committed-blob checks bind the receipt to project bytes;
           they do not prove an atomic filesystem snapshot or dependency-cache
           integrity. Build outputs and archived run logs are not source inputs. */
        doc /* The standard unfiltered Gerbil test gate derives its module
           inventory from direct -test.ss files in t using the SDK's
           collection rule. Qualification requires the exact harness inventory,
           balanced module/suite/case starts and completions, nonempty modules,
           a final OK and natural process success within the existing deadline.
           A historical case count, zero exit alone or a partial transcript is
           not completion evidence. Go testing.F exercises protocol corruption;
           transcript checks do not prove SDK execution or final-send safety. */
        part rust : VerificationSuite { part 'check-rust' : VerificationMode; }
        part go : VerificationSuite {
            part 'check-go' : VerificationMode;
            doc /* Prepare the ordinary provider and commit-observer images with
               Cargo in separate five-minute stages before the Go Provider
               integration suite. The same Cargo targets remain the fixture's
               image authority. The integration package keeps its ten-minute
               timeout and all existing recovery and natural-exit gates. */
        }
        part scheme : VerificationSuite {
            part 'check-scheme' : VerificationMode;
            doc /* Prepare the qualification image through Cargo before Go
               streaming tests. Bound the image build and Go suite separately.
               Retain native Go failure events with the stage receipt. The
               provider recovery and natural-exit deadlines govern runtime. */
        }
        part architecture : VerificationSuite { part 'check-architecture' : VerificationMode; }
        part policy : VerificationSuite {
            part 'check-policy' : VerificationMode;
            doc /* Own the real SPEC provider integration because it consumes
               Lean and CVC5. Run its stream-release, before-commit and
               after-commit cases after the same native image build stages. */
        }
        part benchmarks : VerificationSuite { part bench : VerificationMode; }

        package Artifacts {
            doc /* The repository owns reproducible inputs. Toolchains own build
               products and caches. The verification owner publishes typed
               receipts through one output directory. GitHub transports the
               declared JSON paths as one artifact per job attempt.
               ArtifactOrganization defines custody beyond verification. */
            part def CIReceipt;
            part def LocalResult;
            part def ToolOutput;
            part def ReleaseEvidence;

            part '.cache/verification/ci-job.json' : CIReceipt {
                doc /* The reusable workflow binds the run, attempt, PR head,
                   actual checkout, runner and phase outcomes. Publish after
                   failure as well as success. An absent checkout is explicit. */
            }
            part '.cache/verification/latest-bootstrap-build.json' : CIReceipt;
            part '.cache/verification/latest-bootstrap-proofs.json' : CIReceipt;
            part '.cache/verification/latest-<suite>.json' : CIReceipt {
                doc /* weaver-dev owns suite receipts. Preserve committed input
                   digests, stage status, exit, duration and output digest.
                   The native deadline precedes the GitHub step deadline so
                   timeout evidence can finish publication. Native recovery
                   and natural-exit acceptance keep their separate fences.
                   Bench measurements remain separate from correctness claims. */
            }
            part '.cache/verification/spec/*/receipt.json' : CIReceipt {
                doc /* The SPEC owner retains per-run verdicts and stage evidence
                   alongside its typed catalog. Only the receipt is exported to CI. */
            }
            part '.cache/verification/spec/*/catalog.json' : LocalResult;
            part '.cache/verification/latest-benchmark-summary.org' : LocalResult;
            part transientProcessOutput : ToolOutput {
                doc /* Native process owners use private temporary directories.
                   Retain bounded diagnostics inside the typed receipt and clean
                   the scratch directory when the producer finishes. */
            }
            part toolchainProducts : ToolOutput {
                doc /* Cargo and Scheme Build Packages own compiled outputs.
                   Their stores and caches are inputs to reproducibility checks
                   where required. Ordinary jobs export the declared receipts. */
            }
            part approvedReleaseEvidence : ReleaseEvidence {
                doc /* Site authority binds the deployable release and its
                   manifest to approval, activation and workload identity.
                   Production qualification follows the separate site protocol. */
            }
        }
    }

    package AssuranceResponsibilities {
        private import ScalarValues::*;
        doc /* Sole responsibility registry. Documents and diagrams reference
           these owners; they do not create parallel verification designs. */
        part def Specification :> VerificationResponsibility {
            attribute displayName : String = "Specify effects";
            attribute responsibility : String = "SysML + Org\nAllocate final-send ownership\nName the required contracts";
            attribute glyph : String = "model";
            attribute visualRole : String = "publication";
            doc /* SysML owns component allocation, typed boundaries and named
               requirements. SDK structural analysis is not behavioral proof. */
        }
        part def Schedules :> VerificationResponsibility {
            attribute displayName : String = "Explore failures";
            attribute responsibility : String = "Quint\nRace revoke, wait and release\nFind unsafe recovery schedules";
            attribute glyph : String = "decision";
            attribute visualRole : String = "selection";
            doc /* Quint owns concurrent/fault schedules and unsafe counterexamples.
               Extend existing publication/execution models rather than duplicate
               their ledgers. It does not reimplement Cedar evaluation or prove
               arbitrary Scheme/Rust programs. Credential semantics enter as
               qualified opaque references; only read/use ordering is modeled. */
        }
        part def Semantics :> VerificationResponsibility {
            attribute displayName : String = "Preserve contracts";
            attribute responsibility : String = "Lean + cedar-poo-spec\nRetain required parent scope\nProve conditional preservation";
            attribute glyph : String = "obligation";
            attribute visualRole : String = "semantic";
            doc /* Lean reuses cedar-poo-spec and Cedar semantic/refinement
               theorems with explicit authenticity/materialization premises.
               No second control/activation/CAS state machine is introduced.
               Credential subject/key/scope/audience meanings have one SPEC
               definition; downstream Lean only applies its composition laws.
               Solver reports and finite replay records are not kernel proofs. */
        }
        part def Implementation :> VerificationResponsibility {
            attribute displayName : String = "Test actual effects";
            attribute responsibility : String = "PBT + integration\nExercise SQL, FFI and gRPC\nObserve denied and sent bytes";
            attribute glyph : String = "evidence";
            attribute visualRole : String = "execution";
            doc /* Scheme/Rust/Go PBT and integration suites establish
               concrete composition, FFI, parsing, SQL and transport behavior.
               Inherited POO property testing, Proptest and Go testing.F own generation, shrinking, corpora and
               replay. Property contracts, independent oracles and typed command
               models precede Runtime changes; command runners only launch suites.
               They do not turn finite cases into universal theorems. */
        }
        part specification : Specification;
        part schedules : Schedules;
        part semantics : Semantics;
        part implementation : Implementation;
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
        doc /* Go deployment chooses an authenticated approved-producer RPC or
           a JSON/YAML data file, exclusively. It never launches Scheme. Rust's
           default production program installation remains a delivery gate;
           qualification graphs do not silently become production semantics. */
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
        part 'dev/d2' : Directory;
        part 'dev/d2/themes' : Directory;
        part 'dev/d2/README.org' : File;
        part t : Directory;
        part docs : Directory;
        part proto : Directory;
        part examples : Directory;
        part '.github' : Directory;

        part 'Project.sysml' : File;
        part '.gitignore' : File;
        part 'Cargo.toml' : File;
        part 'Cargo.lock' : File;
        part 'LICENSE' : File;
        part 'LICENSING.org' : File;
        part 'REUSE.toml' : File;
        part 'Cargo.lock.license' : File;
        part 'crates/governance/tests/unit/binding.txt.license' : File;
        part 'dev/d2/package.json.license' : File;
        part 'dev/d2/pnpm-lock.yaml.license' : File;
        part 'dev/d2/tsconfig.json.license' : File;
        part 'dev/proofs/cedar/lake-manifest.json.license' : File;
        part 'dev/proofs/cedar/lean-toolchain.license' : File;
        part 'dev/sysml/runtime-trace.json.license' : File;
        part 'devenv.lock.license' : File;
        part 'docs/50-59-research-program/58-streaming-execution/58.03-streaming-runtime.png.license' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.03-provider-rpc-core.png.license' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.21-verification-ownership.png.license' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.51-zero-trust-contract-refinement.png.license' : File;
        part 'docs/architecture/diagrams/00a-readme-overview.png.license' : File;
        part 'docs/architecture/diagrams/01-system-boundaries-node-editor.png.license' : File;
        part 'docs/architecture/diagrams/01-system-boundaries-sketchbook.png.license' : File;
        part 'docs/architecture/diagrams/01-system-boundaries.png.license' : File;
        part 'docs/architecture/diagrams/01-system-relationships.png.license' : File;
        part 'docs/architecture/diagrams/12-execution-correspondence-node-editor.png.license' : File;
        part 'docs/architecture/diagrams/12-execution-correspondence.png.license' : File;
        part 'examples/local-owner/request.json.license' : File;
        part 'examples/local-owner/task.json.license' : File;
        part 'go/go.sum.license' : File;
        part 'prod/policies/provider/profile.json.license' : File;
        part 'prod/policies/provider/request-cases.json.license' : File;
        part 'prod/policies/provider/schema.json.license' : File;
        part 'prod/policies/review/named-forbid.json.license' : File;
        part 'prod/policies/review/named-permit.json.license' : File;
        part 'prod/policies/review/namespaced-enum-validated.json.license' : File;
        part 'prod/policies/streaming/schema.json.license' : File;
        part 'LICENSES' : Directory;
        part 'LICENSES/LGPL-2.1-or-later.txt' : File;
        part 'LICENSES/Apache-2.0.txt' : File;
        part 'rust-toolchain.toml' : File;
        part 'go.work' : Absent;
        part 'go.work.sum' : Absent;
        part 'go/go.mod' : File;
        part 'go/go.sum' : File;
        part 'gerbil.pkg' : File;
        part 'build.ss' : ExecutableFile;
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
        part 'docs/50-59-research-program/59-provider-rpc/59.55-evidence-reviewed-publication.org' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.55-evidence-reviewed-publication.d2' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.55-evidence-reviewed-publication.svg' : File;
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
        part 'docs/50-59-research-program/59-provider-rpc/59.71-host-envelope-and-retest.org' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.72-turso-read-stage-attribution.org' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.73-bridge-commit-cpu-and-ci.org' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.74-commit-io-and-notification-origin.org' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.75-complete-entry-and-output-contract.org' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.75-package-linkage.d2' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.75-package-linkage.svg' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.76-embedded-tooling-and-darwin-io.org' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.76-embedded-tooling-and-darwin-io.d2' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.76-embedded-tooling-and-darwin-io.svg' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.77-mrr-turso-storage.org' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.78-turso-mvcc-custody.org' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.79-turso-final-domains.org' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.80-shared-domain-authority.org' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.81-original-task-origin-registration.org' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.82-semantic-responsibility-allocation.org' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.85-source-preparation-admission.org' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.77-mrr-turso-storage.d2' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.77-mrr-turso-storage.svg' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.75-complete-entry-and-output-contract.d2' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.75-complete-entry-and-output-contract.svg' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.64-governance-capture-ownership.org' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.64-governance-capture-ownership.d2' : File;
        part 'docs/50-59-research-program/59-provider-rpc/59.64-governance-capture-ownership.svg' : File;

        part 'crates/contracts' : RustPackage;
        part 'crates/governance' : RustPackage {
            doc /* ApprovedProducer/ProducerCatalog seal a bounded local set of
               names, immutable original artifacts and source identity/epoch
               observations. A producer name cannot supply replacement input.
               Private immutable SourceData ownership may be shared without
               copying every body at queue admission. This catalog neither
               authenticates observations nor replaces the durable source ledger. */
            doc /* Own checked concrete source records after a
               synchronous native Scheme strong-root conversion. No VM object survives in
               OwnedSource; conversion and transport confer no publication/send
               authority. Program graph/export admission remains host-owned. The scheme-vm feature
               exposes conversion only; scheme-program links an explicit application
               and fixed ABI; scheme-qualification selects a debug-only test root.
               SourceExpectation retains the independently admitted original
               before producer invocation; BoundSource compares the whole typed
               image and remains inert data, never a publication/send permit. */
            doc /* root_source builds the reverse native input from concrete
               validated original records using SDK rooted constructors. Field
               symbols, identifier strings, exact integers and optional fields
               retain their kinds. Fallible bounded construction owns temporary
               roots; it confers neither producer admission nor execution rights. */
            doc /* SourceClient/SourceInbox bound queued, running and unread
               ready work on an existing tracked blocking owner. The VM remains
               owner-thread local. Terminal close and cancellation fence future
               delivery; active foreign calls drain naturally before join.
               This lane has no publication, execution or budget authority. */
            doc /* SchemeCompiler checks real installed-producer readiness before
               becoming usable. program/linked.rs is the sole reviewed SDK ABI
               exception to deny-mode unsafe policy; typed conversion and all
               ownership/lifecycle code remain safe. Startup catalog data is
               bounded/duplicate-free and supplies eligibility, never source PoP. */
            part 'weaver-contracts' : RuntimeDependency;
            part 'weaver-policy-ffi' : RuntimeDependency;
        }
        part 'crates/governance-build' : RustPackage {
            doc /* Match explicit application module/source to archive metadata;
               initialize that application as the real root. The fixed ABI is a
               dependency, not a replacement initializer. Production mode refuses
               known fixture modules; qualification cannot build a release graph. */
        }
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
        part 'crates/broker' : RustPackage {
            part 'weaver-contracts' : RuntimeDependency;
            part 'weaver-ledger' : RuntimeDependency;
        }
        part 'crates/server' : RustPackage {
            doc /* An initialized GovernanceWorker may publish its producer
               catalog once through the shared admission gate. Closed or duplicate
               publication fails; the catalog uses this worker's fixed client.
               CompileSource authenticates the source connection, observes its
               durable authority before compilation and rechecks after the owned
               result returns. A response is knowledge, never a publication or
               execution permit; Go uses existing source publication CAS. */
            doc /* ServiceRuntime is the existing shared task/resource owner.
               Approved compiler factories construct non-Send Scheme VMs on its
               tracked blocking worker. Terminal shutdown closes source delivery;
               drain waits for natural factory/call return and VM cleanup.
               One compiler owner is installed for this runtime incarnation;
               rejected duplicates cannot retire the current owner. This lifecycle
               run_from_env may install the compiled program and explicit startup
               catalog through this owner before binding ingress. No implicit
               application exists; CompileSource selects only the sealed set. */
            part 'weaver-contracts' : RuntimeDependency;
            part 'weaver-governance' : RuntimeDependency;
            part 'weaver-ledger' : RuntimeDependency;
            part 'weaver-broker' : RuntimeDependency;
            part 'weaver-telemetry' : RuntimeDependency;
        }
        part 'crates/telemetry' : RustPackage;
        part 'crates/contracts/benches/support' : Directory;
        part 'crates/policy/benches/support' : Directory;
        part 'crates/ledger/benches/support' : Directory;

        part 'go/api/v1' : GoPackage;
        part 'go/api/gateway/v1' : GoPackage;
        part 'go/cmd/weaver-control' : GoPackage;
        part 'go/cmd/weaver-dev' : GoPackage;
        part 'go/cmd/weaver-import-provider' : GoPackage;
        part 'go/cmd/weaver-meter' : GoPackage;
        part 'go/dev' : GoPackage;
        part 'go/internal/config' : GoPackage;
        part 'go/internal/controlplane' : GoPackage;
        part 'go/internal/telemetry' : GoPackage;
        part 'go/internal/devrunner' : GoPackage;
        part 'go/internal/gatewayclient' : GoPackage;
        part 'go/internal/metering' : GoPackage;
        part 'go/internal/specreview' : GoPackage;
        part 'go/internal/routing' : GoPackage;
        part 'go/internal/streaming' : GoPackage;
        part 'go/internal/devrunner/testdata/fuzzcontrol' : Directory;

        part 'scheme/governance' : SchemeModule;
        part 'scheme/policy' : SchemeModule;
        part 'scheme/gateway' : SchemeModule {
            doc /* program.ss owns a sealed Record/Function lifecycle for one
               approved typed-return producer. Install/close are terminal at
               their respective admission points; a duplicate cannot replace
               the installed callback. Actual Governor/Profile construction
               belongs to the approved application graph, never a default
               fixture. This object supplies no publication or send authority. */
        }
        part 't/gateway-contracts-test.ss' : File;
        part 't/gateway-fact-impact-test.ss' : File;
        part 't/governance-test.ss' : File;
        part 't/policy-test.ss' : File;
        part 't/fixtures/governed-control.ss' : File {
            doc /* Test-only library compiled by the root standard Gerbil build;
               integration imports its canonical package module. No executable
               or production Governance capability is introduced. */
        }

        part 'prod/policies/provider/ProviderReview.lean' : File;
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
        part 'dev/sysml/ZeroTrustRefinement.sysml' : File;
        part 'dev/sysml/GatewayArchitecture.sysml' : File;
        part 'dev/sysml/StoragePersistence.sysml' : File;
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
        part 'dev/build.ss' : Absent;
        part 'dev/gerbil.pkg' : Absent;
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
    allocation brokerCode allocate Architecture::broker to Layout::'crates/broker';
    allocation transportCode allocate Architecture::executor to Layout::'crates/broker';
    allocation telemetryDesign allocate Architecture::telemetry to Layout::'docs/50-59-research-program/59-provider-rpc/59.24-telemetry-service.org';
    allocation telemetryCode allocate Architecture::telemetry to Layout::'crates/telemetry';
    allocation telemetryControlCode allocate Architecture::telemetry to Layout::'go/internal/telemetry';
}
