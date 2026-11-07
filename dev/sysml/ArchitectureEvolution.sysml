// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package ArchitectureEvolution {
    private import ScalarValues::*;
    private import Views::*;
    private import StandardViewDefinitions::*;
    doc /* Architecture learning and strengthening contracts. This development
       model extends ControllerObjectLifecycle and the existing authority model.
       Hypotheses, causal mechanisms, costs and falsifiers are first-class review
       subjects. Capability availability does not establish integrated behavior
       or a performance advantage. Target action allocations do not implement a
       runtime, new policy language, second ledger or autonomous self-modification. */

    enum def EvidenceDomain { enum semantics; enum schedules; enum nativeEffects; enum matchedWorkload; enum operations; }
    enum def Finding { enum notExecuted; enum supportsWithinScope; enum counterexample; enum inconclusive; }
    enum def Readiness { enum unknown; enum preparing; enum readyWithinScope; enum refused; enum retired; }
    item def EvidenceAxis {
        attribute domain : EvidenceDomain;
        attribute finding : Finding = Finding::notExecuted;
        attribute sourceIdentity : String;
        attribute witness : String;
        attribute scopeAndPremises : String;
        doc /* Evidence is a vector over independent domains, not an overall
           maturity score. A finite schedule, kernel theorem, native integration
           and matched benchmark answer different questions. Preserve failures;
           changed sources invalidate dependent acceptance claims. */
    }
    item def PreparedObjectReadiness {
        item image : PolicyEvidenceDesign::ArtifactImage;
        item facts : PolicyEvidenceDesign::FactUseContext;
        attribute ownerEpoch : String;
        attribute dependencyCut : String;
        attribute status : Readiness;
        attribute preparationObservation : String;
        doc /* Target local preparation evidence for the exact execution owner,
           dependencies and image. Parse/capture completion, publication ACK and
           open sockets do not establish readiness. Recheck after source/owner
           change and at actual use. Readiness is neither durable publication nor
           permission; do not wait for a remote dependency while holding a ledger
           deciding lock. Existing bounded owner queues and tracked cleanup apply. */
    }
    item def ReconciliationCut {
        item original : PolicyEvidenceDesign::SemanticCommitment;
        item desired : PolicyEvidenceDesign::ConfigurationCommitment;
        item observed : PolicyEvidenceDesign::PublishedObservation[0..1];
        item readiness : PreparedObjectReadiness[0..1];
        item facts : PolicyEvidenceDesign::FactUseContext;
        doc /* Desired, prepared, authority-committed and actually observed states
           have separate coordinates. Lack of observation is unknown. Convergence
           needs admitted source availability, bounded successful preparation and
           eventual scheduling; an ongoing partition does not promise liveness.
           Coalesce recomputation demand only. Original hard-fact intents,
           transitions, claims and unknown holds cannot be dropped as superseded. */
    }
    item def DecisionExplanation {
        item original : PolicyEvidenceDesign::SemanticCommitment;
        item derivation : PolicyEvidenceDesign::DerivedFactCandidate[0..1];
        item publication : PolicyEvidenceDesign::PublishedObservation[0..1];
        item effect : PolicyEvidenceDesign::EffectObservation[0..1];
        attribute reasonReferences : String[0..*];
        attribute missingEvidence : String[0..*];
        doc /* Target bounded, authorized data projection of existing receipts
           and provenance. Distinguish policy denial, derivation unknown, warmup,
           stale facts, capacity refusal and uncertain effects. Redact source
           facts and payloads. Sampled telemetry is not a coherent ledger image;
           an explanation grants no authority or accounting adjustment. */
    }
    action def AssessObjectReadiness {
        in item image : PolicyEvidenceDesign::ArtifactImage;
        in item facts : PolicyEvidenceDesign::FactUseContext;
        out item observation : PreparedObjectReadiness;
    }
    action def ReconcileObjectSet {
        in item cut : ReconciliationCut;
        in item candidate : PolicyEvidenceDesign::DerivedFactCandidate;
        out item proposal : PolicyEvidenceDesign::SourceCommand[0..1];
        doc /* Scheme composes admitted object behavior and ASCENT candidates;
           Go carries observations/publication. Rust decides current authority.
           Preserve SourceExpectation equality and independently admitted origin;
           semantic selection precedes freeze or uses a qualified SPEC derivation. */
    }
    action def PrepareSessionWorkflow {
        in item original : PolicyEvidenceDesign::SemanticCommitment;
        out item workflow : PolicyEvidenceDesign::PreparedSessionWorkflow;
        doc /* Scheme projects a bounded sequence of typed Funflow provider
           tasks placed in an Agentic AI Lab Session. The single-provider
           specialization captures the order before publication and seals
           preparation at exact activation. Hard-fact projection keeps its
           linked Scheme owner while the Session is active. */
    }
    action def AdvanceGovernedRoutine {
        in item original : PolicyEvidenceDesign::SemanticCommitment;
        in item workflow : PolicyEvidenceDesign::PreparedSessionWorkflow[0..1];
        in item predecessor : PolicyEvidenceDesign::EffectObservation[1..64];
        in item selector : PolicyEvidenceDesign::ReleasedWorkflowResult[0..31];
        in item facts : PolicyEvidenceDesign::FactUseContext;
        out item proposal : PolicyEvidenceDesign::SessionProgressionProposal;
        doc /* Reuse AA Session, Yuanxu Funflow and Governor; Rust admission owns
           frontier/claim/reservation/outcome atomicity. Configuration convergence
           and business-step completion are separate loops sharing Scheme/POO.
           For a fork/join, the live Scheme Governor derives ready nodes with
           ASCENT from complete releases and current availability. Conditional
           routes also match a structured selector result and a durable branch
           decision defines the join's active predecessor. Unknown,
           partial or wrong-domain observation cannot advance a step. */
    }
    action def ExplainObjectDecision {
        in item original : PolicyEvidenceDesign::SemanticCommitment;
        out item explanation : DecisionExplanation;
    }

    part def Improvement {
        attribute phase : ControllerObjectLifecycle::Phase;
        attribute integration : ControllerObjectLifecycle::Mechanism default = ControllerObjectLifecycle::Mechanism::missingIntegration;
        attribute nativeAsset : String;
        attribute learningWitness : String;
        attribute reuseSeam : String;
        attribute causalMechanism : String;
        attribute cost : String;
        attribute preservedBoundary : String;
        attribute falsifier : String;
        attribute qualificationOwner : String;
        item evidence : EvidenceAxis[0..*];
        doc /* An improvement is a testable design decision. Empty evidence is
           unqualified. Source inspection and prior focused runs must retain
           their exact cohort and bounded scope; neither fills new runtime gates. */
    }
    part def SemanticComposition :> Improvement {
        attribute :>> phase = ControllerObjectLifecycle::Phase::preparation;
        attribute :>> nativeAsset = "Scheme/POO Profile/Governance/Governor and cedar-poo-spec";
        attribute :>> learningWitness = "Praxis packaged policy composition: 10.13-praxis-envoy-and-ascent.org";
        attribute :>> reuseSeam = "scheme/gateway/func.ss;scheme/policy/func.ss;upstream PolicyModules export/provenance";
        attribute :>> causalMechanism = "One object composition supplies planning, obligations and checked projections across multiple entry paths";
        attribute :>> cost = "Callback determinism, admitted capture closure, unsupported values and compatibility qualification";
        attribute :>> preservedBoundary = "No second Go semantic selector; no whole-object flattening; original binding remains exact";
        attribute :>> falsifier = "Two entry paths disagree on the same admitted object; inherited provenance lost; independent original changes";
        attribute :>> qualificationOwner = "WeaverProject::AssuranceResponsibilities::semantics;WeaverProject::AssuranceResponsibilities::implementation";
    }
    part def ConfigurableProgramming :> Improvement {
        attribute :>> phase = ControllerObjectLifecycle::Phase::preparation;
        attribute :>> nativeAsset = "Scheme/POO profiles and contracts, native Build Packages, typed Gateway source capture and catalog startup";
        attribute :>> learningWitness = "Agent Gateway explicit configuration selection; Praxis shared validation and candidate preparation";
        attribute :>> reuseSeam = "SemanticComposition;AssessObjectReadiness;PrepareSessionWorkflow;PolicyEvidenceDesign::SourceCommand";
        attribute :>> causalMechanism = "Map declarative operator inputs and admitted Scheme profiles to the same typed configuration contract and existing preparation path";
        attribute :>> cost = "Profile compatibility, validation diagnostics, exact provenance and bounded preparation";
        attribute :>> preservedBoundary = "TOML selects an admitted profile and supplies typed inputs; trusted Scheme composes resources and workflows; Cedar, SPEC and the ledger retain effect authority";
        attribute :>> falsifier = "Equivalent inputs disagree on the executable projection or effect behavior; invalid or stale candidates activate; ordinary requests repeat source preparation";
        attribute :>> qualificationOwner = "WeaverProject::AssuranceResponsibilities::semantics;WeaverProject::AssuranceResponsibilities::implementation";
        doc /* Proposed authoring contract. Record input and profile revisions
           separately from the prepared projection. Allow a deployment launcher
           to set paths and credentials independently of semantic inputs. Use
           the same owner, validation and activation path across authoring modes.
           Scheme Governor may still derive runtime proposals from current facts. */
    }
    part def IncrementalRelations :> Improvement {
        attribute :>> integration = ControllerObjectLifecycle::Mechanism::partialIntegration;
        attribute :>> phase = ControllerObjectLifecycle::Phase::reuse;
        attribute :>> nativeAsset = "Inherited ASCENT retained sessions and AA source/query lifecycle";
        attribute :>> learningWitness = "Envoy delta subscription: https://www.envoyproxy.io/docs/envoy/latest/api-docs/xds_protocol";
        attribute :>> reuseSeam = "scheme/gateway/derivation.ss fixed advisory session;ControllerObjectLifecycle::MaintainObjectRelations;public program/interface and query-provider APIs";
        attribute :>> causalMechanism = "Affected dependency closure bounds recomputation; unrelated object preparation remains reusable";
        attribute :>> cost = "Retained memory, source ordering, deletion and opaque callback fallback; dense changes may favor fresh evaluation";
        attribute :>> preservedBoundary = "Full FactProjectionClosure and immutable nested values; no decision cache";
        attribute :>> falsifier = "Retained and fresh results differ or retained cost exceeds fresh on the declared workload";
        attribute :>> qualificationOwner = "WeaverProject::AssuranceResponsibilities::implementation";
    }
    part def DependencyReadiness :> Improvement {
        attribute :>> phase = ControllerObjectLifecycle::Phase::replacement;
        attribute :>> nativeAsset = "Owned capture, fixed Gerbil owner, source CAS and pending publication";
        attribute :>> learningWitness = "Envoy initialization/warming: https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/operations/init";
        attribute :>> reuseSeam = "AssessObjectReadiness;ControllerObjectLifecycle::PrepareObjectReplacement;crates/governance/src/host";
        attribute :>> causalMechanism = "Prepare the exact successor dependency cut before activation; track old-owner retirement separately";
        attribute :>> cost = "Temporary duplicate resources, warmup latency, old calls and bounded drain under failure";
        attribute :>> preservedBoundary = "Last prepared image must still pass current authority; revoked facts cannot be served as last-good permission";
        attribute :>> falsifier = "Ready object has an unprepared dependency, stale owner epoch, or execution after revoke";
        attribute :>> qualificationOwner = "WeaverProject::AssuranceResponsibilities::schedules;WeaverProject::AssuranceResponsibilities::implementation";
    }
    part def ObservationDrivenLoops :> Improvement {
        attribute :>> integration = ControllerObjectLifecycle::Mechanism::partialIntegration;
        attribute :>> phase = ControllerObjectLifecycle::Phase::publication;
        attribute :>> nativeAsset = "AA Session, Yuanxu Funflow and Governor plus existing PublishedObservation and EffectObservation";
        attribute :>> learningWitness = "Kubernetes controller pattern: https://kubernetes.io/docs/concepts/architecture/controller/";
        attribute :>> reuseSeam = "ReconcileObjectSet;PrepareSessionWorkflow;AdvanceGovernedRoutine;PolicyEvidenceDesign::SessionProgressionProposal";
        attribute :>> causalMechanism = "Explicit desired/observed discrepancy drives reconciliation; authentic effect observations enable admitted successors";
        attribute :>> cost = "Oscillation, stale observations, fairness and deduplication across two loops";
        attribute :>> preservedBoundary = "Config readiness and business completion remain distinct; local checkpoints never settle or advance authority";
        attribute :>> falsifier = "Lost/duplicated observation creates a second successor, a new original, or clears an unknown hold";
        attribute :>> qualificationOwner = "WeaverProject::AssuranceResponsibilities::schedules;WeaverProject::AssuranceResponsibilities::implementation";
    }
    part def DurableInvalidation :> Improvement {
        attribute :>> phase = ControllerObjectLifecycle::Phase::invalidation;
        attribute :>> nativeAsset = "Rust original authority, pending barrier and mediated actual effects";
        attribute :>> learningWitness = "Prior shared-quota/promotion and bound-mutation experiments: praxis-comparison-20261105/receipt.json";
        attribute :>> reuseSeam = "PolicyEvidenceDesign::HardFactIntent;FactBarrierResolution;existing source lane and ledger transaction";
        attribute :>> causalMechanism = "Preserve authenticated invalidation before recomputation and resolve exact intent prefixes at authority";
        attribute :>> cost = "Unavailable sources may block affected new effects; recoverable projections and storage failover need separate qualification";
        attribute :>> preservedBoundary = "Coalescing cannot erase hard intents; no replay of ambiguous effects; local persistence is not replicated failover";
        attribute :>> falsifier = "Failed subscriber or restart clears pending facts, or recovery permits duplicate consumption";
        attribute :>> qualificationOwner = "WeaverProject::AssuranceResponsibilities::schedules;WeaverProject::AssuranceResponsibilities::implementation";
    }
    part def BoundedOperations :> Improvement {
        attribute :>> phase = ControllerObjectLifecycle::Phase::preparation;
        attribute :>> nativeAsset = "Existing bounded SourceClient lane, provider windows and persistence scheduling";
        attribute :>> learningWitness = "Envoy overload manager: https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/operations/overload_manager";
        attribute :>> reuseSeam = "crates/governance/src/host/client.rs;existing execution owners and telemetry";
        attribute :>> causalMechanism = "Owner-specific pressure observations bound accepted work and retained state before exhaustion";
        attribute :>> cost = "Refusal/fairness tradeoffs, stale pressure and cleanup latency; pressure policy is not budget authorization";
        attribute :>> preservedBoundary = "Keep all current limits; no unbounded warmup or background tasks; telemetry cannot grant effects";
        attribute :>> falsifier = "Capacity refusal leaks retained state or starves pending resolution/drain indefinitely under the admitted workload";
        attribute :>> qualificationOwner = "WeaverProject::AssuranceResponsibilities::implementation";
    }
    part def GovernorExecutionPerformance :> Improvement {
        attribute :>> phase = ControllerObjectLifecycle::Phase::reuse;
        attribute :>> nativeAsset = "Fixed Scheme owner, bounded SourceClient, ASCENT Session and durable provider frontier";
        attribute :>> learningWitness = "SDK Mailbox separates native entry from repeated work in one VM";
        attribute :>> reuseSeam = "AdvanceGovernedRoutine;IncrementalRelations;BoundedOperations;Governor release preregistration in 59.64-governance-capture-ownership.org";
        attribute :>> causalMechanism = "Relational reuse targets computation; persistent batches target foreign entry; isolation targets queue delay caused by source preparation";
        attribute :>> cost = "Retained relations, queue residence, invalidation, independent image lifecycle and drain";
        attribute :>> preservedBoundary = "Complete release precedes proposal; exact facts and current frontier govern claim and reservation; coalesce only wakeups";
        attribute :>> falsifier = "Matched workload has no reproducible improvement from durable release to committed reservation, or admission and owner-drain controls regress";
        attribute :>> qualificationOwner = "WeaverProject::AssuranceResponsibilities::implementation";
        doc /* The matched release workload retains the 12-second recovery
           window and the 15-second natural exit fence. A readiness timeout
           before the workload is a failed trial. Resolve any claimed
           interference against owner-entry and committed-frontier traces.
           In the sealed single-provider DAG, activation follows preparation.
           A later authenticated replay returns the prepared reply. Require
           observed new preparation on the active owner or repeatable queue
           or FFI pressure before qualifying an Actor or multi-VM candidate. */
        doc /* Formal release samples fix the image, catalog, policy, offered
           workload, response gates, arrival schedule and total time budget
           before sampling. Match the actual Governor cut and ready-node result
           across arms. Separate the first ASCENT open, warm decisions and
           natural exits. Preserve owner and observation-window dependence
           when defining independent matched blocks. Justify their count and
           the within-owner sample count for the required effect and tail
           interval. Estimate the natural-stop tail from independent exits.
           Freeze the p99 estimator, 95 percent interval method and any
           resampling parameters before collecting formal samples. */
        doc /* The local nine-node Session contributes one inner-join and
           one outer-join endpoint per owner. Intermediate Governor decisions
           measure derivation and can inform its stage costs. Obtain additional
           endpoint opportunities from the frozen admitted workload and its
           actual owner windows. Keep a separate record of exit opportunities. */
        doc /* A/A requires the 95 percent p99 ratio interval within
           [0.90, 1.10]. Retained adoption requires an upper p99 ratio bound
           at most 0.90, a median ratio at most 0.90, and an upper natural-stop
           p99 ratio bound at most 1.10. Require identical admitted work, the
           original capacity controls and no failed or missing trials.
           Preserve censored trials at their deadlines. Keep wiring diagnostics
           and prelaunch host-admission refusals in their own records. */
        doc /* The deployed image receipt binds the build manifest, the
           admitted application source and SDK revision, the approved site
           catalog and source authority, and the deployment activation.
           Include effective runtime dependency bytes when the native
           program resolves a carrier outside the linked image. Record the
           loader-selected origin and verify the frozen cut before and after
           sampling. A fixture catalog qualifies only its own authority and
           offered workload. */
        doc /* The Governor release preregistration in 59.64-governance-capture-ownership.org
           requires separate site approval and approved workload records. Freeze
           the site manifest, native execution selector and numeric sample plan
           before launch. A/A compares fresh with fresh. Only a passing A/A
           admits the separately frozen retained A/B on the same release. The
           derivation mode is the sole A/B treatment change. */
    }
    part def ExplainableDelivery :> Improvement {
        attribute :>> integration = ControllerObjectLifecycle::Mechanism::partialIntegration;
        attribute :>> phase = ControllerObjectLifecycle::Phase::publication;
        attribute :>> nativeAsset = "ASCENT provenance, Cedar reasons, publication/effect receipts and fixed-cardinality telemetry";
        attribute :>> learningWitness = "Praxis deployable policy hooks and inspected Envoy ACK/NACK protocol";
        attribute :>> reuseSeam = "GatewayPreparation exposes bounded declared-candidate and impact reasons;ExplainObjectDecision receipt join and authenticated inspection remain target work";
        attribute :>> causalMechanism = "One original-bound explanation joins why selected, why blocked, source cut and concrete observed outcome";
        attribute :>> cost = "Sensitive provenance, incomplete observations, bounded storage and cohort compatibility";
        attribute :>> preservedBoundary = "Authorized redaction; metrics remain nonauthoritative; no new exporter or listener by default";
        attribute :>> falsifier = "Explanation mislabels unknown as denied/complete or leaks source facts to an unauthorized reader";
        attribute :>> qualificationOwner = "WeaverProject::AssuranceResponsibilities::implementation";
    }
    part improvements {
        part composition : SemanticComposition;
        part configuration : ConfigurableProgramming;
        part incrementality : IncrementalRelations;
        part readiness : DependencyReadiness;
        part loops : ObservationDrivenLoops;
        part invalidation : DurableInvalidation;
        part operations : BoundedOperations;
        part explanation : ExplainableDelivery;
    }

    port def CapabilityDependency { out item cut : ReconciliationCut; }
    part def Capability {
        attribute displayName : String;
        attribute responsibility : String;
        attribute glyph : String = "model";
        attribute visualRole : String = "semantic";
        port incoming : ~CapabilityDependency;
        port outgoing : CapabilityDependency;
    }
    part def Compose :> Capability {
        attribute :>> displayName = "Compose";
        attribute :>> responsibility = "POO + Scheme\nASCENT relations";
    }
    part def Prepare :> Capability {
        attribute :>> displayName = "Prepare";
        attribute :>> responsibility = "Dependency cut\nBounded owners";
    }
    part def Enforce :> Capability {
        attribute :>> displayName = "Enforce";
        attribute :>> responsibility = "Cedar + SPEC\nRust final effects";
    }
    part def Observe :> Capability {
        attribute :>> displayName = "Observe";
        attribute :>> responsibility = "Authentic outcomes\nScoped explanation";
    }
    part reinforcement {
        part compose : Compose;
        part prepare : Prepare;
        part enforce : Enforce;
        part observe : Observe;
        connection derive connect compose.outgoing to prepare.incoming;
        connection propose connect prepare.outgoing to enforce.incoming;
        connection report connect enforce.outgoing to observe.incoming;
        connection reconcile connect observe.outgoing to compose.incoming;
        doc /* Capability dependencies and feedback, not new runtime components
           or four independent owners. Actions are allocated in WeaverExecution.
           Each reuse/adoption hypothesis has its own cost and falsification gate. */
    }
    view reinforcingCapabilities {
        attribute mappedFile : String = "docs/10-19-llm-gateway/10-routing-and-inference/10.15-architecture-evolution.d2";
        attribute displayTitle : String = "Make architecture capabilities reinforce each other";
        attribute displaySubtitle : String = "Retain semantic richness; qualify preparation, authority and observed outcomes separately.";
        attribute displayEyebrow : String = "WEAVER / ARCHITECTURE EVOLUTION";
        attribute readerQuestion : String = "How do our existing strengths compound?";
        attribute designAudience : String = "Architecture and execution contributors";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "Compose, prepare, enforce and observe through existing owners.";
        attribute designFocus : String = "compose,enforce";
        attribute visualBands : String = "[[\"compose\"],[\"prepare\"],[\"enforce\"],[\"observe\"]]";
        attribute visualThemes : String = "sketchbook,field-notes,comfortable,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement original : WeaverExecution::OriginalTaskBinding;
        requirement currentUse : WeaverExecution::CurrentFinalGuard;
        requirement observation : WeaverExecution::TelemetryNoninterference;
        expose reinforcement::compose;
        expose reinforcement::prepare;
        expose reinforcement::enforce;
        expose reinforcement::observe;
        expose reinforcement::derive;
        expose reinforcement::propose;
        expose reinforcement::report;
        expose reinforcement::reconcile;
        render asInterconnectionDiagram;
    }
}
