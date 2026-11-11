// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package ControllerObjectLifecycle {
    private import ScalarValues::*;
    private import Views::*;
    private import StandardViewDefinitions::*;
    doc /* Lifecycle design and implementation assessment of existing owners.
       Scheme/POO owns control and high-order execution composition. These action
       contracts allocate missing joins; they are not implemented RPCs, another
       object runtime, source ledger or authorization state machine. Existing
       PolicyEvidenceDesign items and WeaverExecution owners remain authoritative.
       Assessment nodes are review subjects, not new runtime services. */

    enum def Phase { enum preparation; enum publication; enum replacement; enum reuse; enum invalidation; }
    enum def Mechanism { enum localImplemented; enum authorityImplemented; enum inheritedAvailable; enum partialIntegration; enum missingIntegration; }

    requirement def BoundedAdvisoryDerivation {
        doc /* The default Scheme compile path runs the inherited ASCENT fixed
           advisory kernel and preserves the exact GatewayArtifact. Preparation
           exposes separate complete declared-candidate/impact explanations.
           Integer-only detached projections, 4096 input / 8192 derived / 12288
           output fact limits and existing capture bounds apply. This is a fact
           bound, not a wall-clock deadline or a proof of general eligibility.
           Retained public sessions replace all projected sources together;
           full request/result equality and local generation fence reuse/ABA.
           Invalidate/close never clear authority pending facts or unknown holds.
           Owner-local advisory output cannot authorize, mutate plans, refund
           reservations or create a new independently admitted original.
           Qualification separates cold preparation, prepared-owner derivation
           and end-to-end semantic recovery. A hot-path contrast must not charge
           repeated cold setup to every observation. Retained and fresh modes
           use the same prepared release workload and exact source boundaries.
           Record the first session open separately from subsequent replacements
           on the same topology. A startup mode label does not establish reuse.
           Decisions observed in one owner belong to one replication unit.
           Match each measured join by the actual detached Governor input and
           ready-node result. Report inner and outer join endpoints separately
           within the same owner block. The diagnostic digests do not replace
           the source version, release receipts or transactional admission checks.
           Replication and tail confidence require an explicit sample-size
           justification before a new statistical campaign. Freeze offered
           load, backpressure and the total budget. Preserve owner clustering
           and retain every refusal and timeout. Preserve four
           workers, all failures and the existing 12-second recovery / 15-second
           natural-exit budgets. Local qualification is not site approval. */
    }

    action def PrepareObject {
        in item original : PolicyEvidenceDesign::SemanticCommitment;
        out item prepared : PolicyEvidenceDesign::ConfigurationCommitment;
        doc /* Reuse POO contracts, admitted Yuanxu scopes, owned capture and
           approved Scheme owner preparation. Preserve the independently admitted
           original. Native object behavior stays in its Scheme owner; materialize
           only the existing checked execution/source projection.
           A single registered provider can explicitly select startup retirement.
           Preparation seals the original-bound artifact and source epoch. The
           exact committed publication, observed by finalization or inspection,
           triggers closure of that compiler lane. Retirement acknowledges the
           native return and VM cleanup while the operation service stays open.
           An authenticated replay observes the same prepared artifact and must
           pass current authority checks before use.
           A cold owner may reuse compiled roles after the Yuanxu Reader admits
           their selected owners, source versions and actual transitive inputs
           against the current Module View. The native link manifest identifies
           code in the image. Role initialization support, including observed
           configuration assets, must be checked by the Reader before use.
           Keep the runtime tool catalog separate from the complete compiler
           bootstrap specification. Preparing a source must not eagerly load
           tooling used only for a build. An explicit build must still admit
           its entire native Context and source closure. */
    }
    action def MaintainObjectRelations {
        in item prepared : PolicyEvidenceDesign::ConfigurationCommitment;
        out item candidate : PolicyEvidenceDesign::DerivedFactCandidate;
        doc /* Target adapter uses inherited AA/ASCENT retained sessions and
           source/query currentness. Complete within the declared scope or return
           unknown. No output is a permit, settlement or authenticated fact. */
    }
    action def PrepareObjectReplacement {
        in item original : PolicyEvidenceDesign::SemanticCommitment;
        in item predecessor : PolicyEvidenceDesign::PublishedObservation;
        out item successor : PolicyEvidenceDesign::SourceCommand;
        doc /* Prepare a new owned source cut without mutating the active image.
           Existing source admission, predecessor CAS and outcome recovery decide
           activation. GatewayProgram cannot be reinstalled in place. Retire the
           old Scheme call/session through its actual owner after pending work is
           accounted for; close alone is not natural native completion. */
    }
    action def ReuseObjectProjection {
        in item retained : PolicyEvidenceDesign::ArtifactImage;
        in item current : PolicyEvidenceDesign::FactUseContext;
        out item projection : PolicyEvidenceDesign::ArtifactImage;
        doc /* Reuse immutable preparation, query results and unchanged relations
           under their exact source/rule/query/limit closure. Actual use retains
           current Cedar, original claim, budget/history and custody checks.
           SourceExpectation equality is not weakened to admit a changed result. */
    }
    action def InvalidateObjectProjection {
        in item changed : PolicyEvidenceDesign::FactProjectionClosure;
        out item candidate : PolicyEvidenceDesign::DerivedFactCandidate;
        doc /* Reuse admitted module currentness and inherited AA change feeds
           for local invalidation. Permission-relevant changes enter the existing
           target hard-fact intent/barrier protocol before fresh use. A missing
           callback or failed rebuild cannot clear that pending authority state.
           Identical rows after an A-B-A update do not restore an old floor. */
    }

    port def ReviewDependencyPort {
        out item contract : PolicyEvidenceDesign::ConfigurationCommitment;
        doc /* Typed lifecycle dependency in this review view, not a new wire
           protocol or evidence that a runtime transition has been implemented. */
    }
    part def Assessment {
        attribute phase : Phase;
        attribute runtimeMechanism : Mechanism;
        attribute upstreamMechanism : Mechanism = Mechanism::inheritedAvailable;
        attribute ascentGatewayJoin : Mechanism default = Mechanism::missingIntegration;
        attribute sourceOwner : String;
        attribute currentSource : String;
        attribute inheritedSource : String;
        attribute missingJoin : String;
        attribute acceptance : String;
        attribute displayName : String;
        attribute responsibility : String;
        attribute glyph : String = "document";
        attribute visualRole : String = "semantic";
        port incoming : ~ReviewDependencyPort;
        port outgoing : ReviewDependencyPort;
    }
    part def Preparation :> Assessment {
        attribute :>> ascentGatewayJoin = Mechanism::partialIntegration;
        attribute :>> phase = Phase::preparation;
        attribute :>> runtimeMechanism = Mechanism::localImplemented;
        attribute :>> sourceOwner = "WeaverExecution::SchemeSemanticPublisher";
        attribute :>> displayName = "Prepare";
        attribute :>> responsibility = "Exists: advisory derive\nMissing: object warmup";
        attribute :>> currentSource = "scheme/gateway/program.ss;scheme/gateway/capture.ss;crates/governance/src/program/compiler.rs";
        attribute :>> inheritedSource = "agentic-ai-lab/modules/loop-engine/interface.ss;gerbil-ascent/program/interface.ss";
        attribute :>> missingJoin = "Fixed bounded advisory kernel is connected to default compile and prepare; generic object readiness and dynamic semantic lowering remain separate gates; cold compiled-role reuse needs Reader admission of source and initialization support";
        attribute :>> acceptance = "Typed refusal; one emission; close/reentry fences; exact original; failed derivation leaves prior accepted source; compiled role reuse preserves current selection, transitive source and asset checks";
    }
    part def Publication :> Assessment {
        attribute :>> phase = Phase::publication;
        attribute :>> runtimeMechanism = Mechanism::authorityImplemented;
        attribute :>> sourceOwner = "WeaverExecution::SourceControlAdapter;WeaverExecution::RustLedger";
        attribute :>> displayName = "Publish";
        attribute :>> responsibility = "Exists: durable CAS\nMissing: fact projection";
        attribute :>> currentSource = "go/internal/controlplane/gateway.go;crates/ledger/src/publication.rs;crates/ledger/src/task_origins.rs";
        attribute :>> inheritedSource = "agentic-ai-lab/modules/temporal-causality/runtime/change-feed.ss;cedar-poo-spec PolicyModules/export/replay";
        attribute :>> missingJoin = "Bind derived closure/completion and recoverable projection to the existing SourceCommand authority path; keep policy composition provenance";
        attribute :>> acceptance = "Lost acknowledgment resolves the same original; unknown never activates; local feed completion is not durable publication";
    }
    part def Replacement :> Assessment {
        attribute :>> phase = Phase::replacement;
        attribute :>> runtimeMechanism = Mechanism::authorityImplemented;
        attribute :>> sourceOwner = "WeaverExecution::SchemeSemanticPublisher;WeaverExecution::RustLedger";
        attribute :>> displayName = "Replace";
        attribute :>> responsibility = "Exists: source fencing\nMissing: owner handover";
        attribute :>> currentSource = "scheme/gateway/program.ss;crates/ledger/src/publication_review.rs;crates/governance/src/host/owner.rs";
        attribute :>> inheritedSource = "gerbil-ascent/program/session.ss;agentic-ai-lab/modules/temporal-causality/runtime/change-feed.ss";
        attribute :>> missingJoin = "Prepare a successor in its owner; join accepted session source with authoritative publication and retirement; never reinstall an active GatewayProgram";
        attribute :>> acceptance = "Stale predecessor; failed replacement; A-B-A source; close during callback; pending derivation and native owner retirement";
    }
    part def Reuse :> Assessment {
        attribute :>> ascentGatewayJoin = Mechanism::partialIntegration;
        attribute :>> phase = Phase::reuse;
        attribute :>> runtimeMechanism = Mechanism::localImplemented;
        attribute :>> sourceOwner = "WeaverExecution::SchemeSemanticPublisher;WeaverExecution::DerivedEvidenceAdapter";
        attribute :>> displayName = "Reuse";
        attribute :>> responsibility = "Exists: retained advice\nMissing: fact authority";
        attribute :>> currentSource = "scheme/gateway/derivation.ss;crates/policy/src/compiled.rs;crates/policy/src/provider.rs;crates/ledger/src/provider_profiles.rs";
        attribute :>> inheritedSource = "gerbil-ascent/program/session.ss;gerbil-ascent/program/update-selection.ss;agentic-ai-lab/modules/ai-agentic-context/query-provider.ss";
        attribute :>> missingJoin = "Owner-scoped fixed advisory session uses full request and immutable integer projections; generic callback closures and hard-fact projection authority remain missing";
        attribute :>> acceptance = "Fresh-vs-retained equality; deletion; rule/limit changes; opaque callbacks; old snapshots unchanged; current effect guard still required";
    }
    part def Invalidation :> Assessment {
        attribute :>> ascentGatewayJoin = Mechanism::partialIntegration;
        attribute :>> phase = Phase::invalidation;
        attribute :>> runtimeMechanism = Mechanism::authorityImplemented;
        attribute :>> sourceOwner = "WeaverExecution::SchemeSemanticPublisher;WeaverExecution::RustLedger;WeaverExecution::RustFinalBroker";
        attribute :>> displayName = "Invalidate";
        attribute :>> responsibility = "Exists: current guard\nMissing: impact loop";
        attribute :>> currentSource = "scheme/gateway/derivation.ss;scheme/gateway/func.ss;crates/ledger/src/provider.rs;crates/broker/src/provider/range_output.rs";
        attribute :>> inheritedSource = "agentic-ai-lab/modules/ai-agentic-context/query-provider.ss;agentic-ai-lab/modules/temporal-causality/runtime/change-feed.ss";
        attribute :>> missingJoin = "Bridge authenticated source changes to affected object/query closure and high-order task continuation; hard facts retain durable pending barriers";
        attribute :>> acceptance = "Withdrawn source; failed subscriber; incomplete fixed point; source disconnect; revoked unsent tail; unchanged original claim and hold";
    }

    part assessment {
        attribute displayName : String = "Existing owners / lifecycle review";
        attribute glyph : String = "model";
        part prepare : Preparation;
        part publish : Publication;
        part replace : Replacement;
        part reuse : Reuse;
        part invalidate : Invalidation;
        connection prepared connect prepare.outgoing to publish.incoming;
        connection current connect publish.outgoing to reuse.incoming;
        connection predecessor connect publish.outgoing to replace.incoming;
        connection successor connect replace.outgoing to publish.incoming;
        connection rebuild connect invalidate.outgoing to prepare.incoming;
        connection recheck connect invalidate.outgoing to reuse.incoming;
        doc /* Dependencies may branch or recur. This is not a linear five-step
           request pipeline; replacement prepares a successor and invalidation
           can supersede preparation or retained reuse. */
    }

    view lifecycle {
        attribute mappedFile : String = "docs/10-19-llm-gateway/10-routing-and-inference/10.14-object-lifecycle.d2";
        attribute displayTitle : String = "Object lifecycle: existing mechanisms and missing joins";
        attribute displaySubtitle : String = "Scheme/POO controls semantics and high-order execution. ASCENT reuses the inherited derivation path.";
        attribute displayEyebrow : String = "WEAVER / CONTROLLER OBJECTS";
        attribute readerQuestion : String = "Where does inherited ASCENT join the existing lifecycle?";
        attribute designAudience : String = "Controller and execution contributors";
        attribute designMedium : String = "Linked English Org and source-derived SVG";
        attribute designMessage : String = "Keep existing owners; complete the lifecycle joins.";
        attribute designFocus : String = "prepare,invalidate";
        attribute visualThemes : String = "sketchbook,field-notes,comfortable,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 1120;
        requirement sourceContract : ControlActivation::SpecificSourceContracts;
        requirement publicationContract : ControlActivation::ControlActivationAcknowledgment;
        requirement finalUseContract : WeaverExecution::CurrentFinalGuard;
        requirement advisoryContract : BoundedAdvisoryDerivation;
        expose assessment::prepare;
        expose assessment::publish;
        expose assessment::replace;
        expose assessment::reuse;
        expose assessment::invalidate;
        expose assessment::prepared;
        expose assessment::current;
        expose assessment::predecessor;
        expose assessment::successor;
        expose assessment::rebuild;
        expose assessment::recheck;
        render asInterconnectionDiagram;
    }
}
