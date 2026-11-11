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
    item def GovernorPublicationBinding {
        item workflow : PolicyEvidenceDesign::PreparedSessionWorkflow;
        attribute publicationIdentity : String;
        attribute ownerEpoch : String;
        doc /* Target binding for the retained ASCENT program and the Rust
           plan index. The Workflow's ordered node identities define indices
           only within this binding. Prepare rule and topology state after
           source admission and before admitting the first live graph wake.
           A replacement or owner restart requires a new binding. Rich POO
           composition remains in Scheme; its stable executable projection
           and retained rule session are prepared once per binding. Opening
           the first rule session on a live wake violates this target readiness
           boundary. This is a design obligation, not a production-default or
           submillisecond acceptance claim. */
    }
    item def GovernorFrontierBinding {
        attribute publicationIdentity : String;
        attribute frontierIdentity : String;
        item facts : PolicyEvidenceDesign::FactUseContext;
        doc /* Identity of one coherent ledger observation, including complete
           release and committed selector evidence. The retained program
           applies this cut's mutable relations, including removals. */
    }
    item def GovernorCandidates {
        attribute publicationIdentity : String;
        attribute ownerEpoch : String;
        attribute frontierIdentity : String;
        attribute nodeIndex : Integer[0..64];
        doc /* Advisory indices resolved against the matching Rust plan index
           in compiled order. The deciding transaction checks current facts,
           release evidence and frontier before claim and reservation. The
           indexed ABI has one exact generation followed by at most 64 node
           indices: the binding is not part of the candidate-count bound.
           Keep the SDK snapshot rooted while borrowing its elements; reject
           stale generations, wrong shapes and foreign indices before use. */
    }
    action def DerivePreparedGovernorCandidates {
        in item prepared : GovernorPublicationBinding;
        in item cut : GovernorFrontierBinding;
        out item candidates : GovernorCandidates;
        doc /* Target specialization of AdvanceGovernedRoutine. Reuse the
           fixed owner and rooted ABI. Compare a full mutable relation set
           first. Invalidate retained state on owner or publication change.
           Recover from the durable frontier before resuming derivation.
           Cross the ABI once per coherent frontier with bounded typed facts
           and receive bounded node indices; avoid repeated topology transfer
           and per-node calls. Replacements include removals. Repeated wake
           demand may be coalesced, but source intents, complete receipts,
           branch decisions and claims must remain durable. Measure owner
           capacity and queue wait separately from input construction, rooted
           call and result materialization. The proposed local hot-decision
           P99 target is below one millisecond including owner waiting, on a
           declared graph/fact bound and four-way workload. Network/provider
           latency and durable deciding transactions have separate clocks and
           acceptance. Existing finite observations do not qualify this target.
           Rust still rechecks current authority and reserves in its deciding
           transaction; a fast advisory result cannot waive that transaction.
           The existing scheme_conversion benchmark also hosts a quiet finite
           source-lane profile: one prepared owner, four Tokio workers, complete
           snapshots of the nine-node nested Workflow, and matched per-request
           submission/start/finish/reply clocks. Join by snapshot and wave,
           check interval nesting, and report preparation and natural owner
           drain separately. These advisory-only inputs confer no ledger
           authority and do not qualify Gateway latency or source admission.
           Optional owner-local SDK usage snapshots correlate collection counts
           and GC duration with individual calls without a Scheme callback or
           per-call logging. Heap capacity and RSS high-water are not live
           allocation. Keep quiet controls around diagnostics. The current
           linked owner shares source capture and inference in one VM; private
           image isolation would require an explicit SDK backend migration,
           not mixing InstancePool with the process-global linked backend.
           A prepared retained program may specialize an immutable wholly
           nested topology with no flat arms/joins: omit only empty private
           flat relations and the flat rules whose guards cannot hold. Keep
           every source-bearing declaration, mutable source name and original
           fact limit. Reconstruct through ASCENT's canonical public program
           factory and retain its admission/replacement transaction. The full
           fresh program is the semantic and failure reference. A topology or
           owner replacement must rebuild the chosen program. */
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
        attribute :>> reuseSeam = "AdvanceGovernedRoutine;DerivePreparedGovernorCandidates;IncrementalRelations;BoundedOperations;Governor release preregistration in 59.64-governance-capture-ownership.org";
        attribute :>> causalMechanism = "Relational reuse targets computation; persistent batches target foreign entry; isolation targets queue delay caused by source preparation";
        attribute :>> cost = "Retained relations, queue residence, invalidation, independent image lifecycle and drain";
        attribute :>> preservedBoundary = "Complete release precedes proposal; exact facts and current frontier govern claim and reservation; coalesce only wakeups";
        attribute :>> falsifier = "Matched workload has no reproducible improvement from durable release to committed reservation, or admission and owner-drain controls regress";
        attribute :>> qualificationOwner = "WeaverProject::AssuranceResponsibilities::implementation";
        doc /* Target P99 below one millisecond from a coherent observed cut
           to resolved Rust candidates, including queue residence, ABI
           conversion and ASCENT. Also measure release to observation and
           release to durable claim separately. Keep provider first-frame,
           ready-frame and throughput gates on their respective clocks. */
        doc /* Runtime design priority: prepare and bind the compiled program,
           topology and retained relations before activation. Keep one bounded
           affine runtime per assigned owner; do not create a VM per decision.
           SourceInbox currently serializes Compile and Derive. A live derivation
           owner must not wait behind source compilation; qualify preparation
           isolation using the existing tracked-owner lifecycle before adoption.
           Stable publication binding plus complete current facts identify reuse;
           selector retraction and A-to-B-to-A must invalidate dependent results.
           Coalesce recomputation demand only, never receipts or authority intents.
           Share no mutable VM across owners. Partition independent sessions only
           after exact frontier and ledger claim controls remain satisfied.
           Packed facts and checked candidate indices bound ABI conversion.
           Arrow is appropriate for column batches, not required for small cuts.
           A fast mailbox is not evidence of low durable claim latency. Attribute
           shared admission wait to actual lease holders and commit I/O before
           changing custody; asynchronous waiting alone cannot shorten a lease.
           Do not infer a sub-millisecond network or durable-commit guarantee
           from the cut-to-candidate target. */
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

    requirement def SchemeSourceComposition {
        doc /* Trusted startup routing is evaluated by the installed Scheme/POO
           application with bounded gerbil-ascent eligibility and deterministic
           cost/latency/canonical-digest ordering. Rust computes canonical facts,
           validates the detached output against the independently retained task,
           publication, declared topology and concrete candidate membership, and
           only then seals its exact original. No second ranking engine is added.
           Workflow topology comes from the existing Session/Funflow/Governor
           producer. Later source captures retain unchanged SourceExpectation
           equality; composition does not authenticate or publish a source.
           The Go catalog adapter consumes the composed typed projection.
           File syntax decoding and dynamic catalog reads use the same advisory
           RPC; Go no longer selects candidates or interprets Workflow there.
           Reference algorithms retain development consumers only. OpenSysML
           tools remain Go. */
    }
    requirement def AdvisorySourceComposition {
        doc /* ComposeSource is restricted to authenticated source ingress.
           Recheck source authority before and after the bounded existing owner
           call. When catalog facts are requested, require the expected exact
           catalog version and recheck it after derivation. The response contains
           inert typed source data, never a publication receipt, catalog install,
           source enrollment, consumed permit or barrier resolution. Complete
           static projections reuse Rust validation; undecided offers use the
           same affine Scheme owner. Preserve independent SPEC review custody.
           Existing immutable projection caching may coalesce one new version;
           each request still observes live source/catalog authority and final
           Rust admission independently decides registration, reservation and use. */
    }
    item def UnsealedSourceComposition {
        item original : PolicyEvidenceDesign::SemanticCommitment;
        attribute configurationIdentity : String;
        doc /* Deployment-owned configuration and candidate facts, not a permit.
           Exact byte/traversal and candidate limits bound application input. */
    }
    action def ComposeSourceBeforeSeal {
        in item configuration : UnsealedSourceComposition;
        out item proposal : PolicyEvidenceDesign::SourceCommand;
        doc /* Existing tracked Rust owner invokes the fixed rooted Scheme ABI;
           reuse POO source contracts, gerbil-ascent and installed producer.
           No additional VM, loader, runner, semantic cache or durable store. */
    }
    requirement def SourceBoundOperationPreparation {
        doc /* An authenticated source declares either exact fixed plans or one
           bounded catalog selector before operations. Persist the tagged scope,
           exact source authority epoch, publication and content digest in the
           existing ledger. Only source ingress can declare it; the operation
           listener receives a narrow resolver, never a source credential.
           Fixed plans are inert original data; reuse their sealed projection
           without a source-lane transaction on each hit. All fresh execution
           guards remain broker/ledger decisions. Publisher credential rotation
           retires the old mutation identity. An already registered fixed task
           stays bound to its committed publication, with the same outcome on
           cache hit, cold lookup or restart. Object withdrawal changes deciding
           authority through publication or the hard-fact barrier. Catalog derivation uses the
           existing affine Scheme/POO/gerbil-ascent owner. Coalesce identical
           immutable projections; never cache permission. Before registering a
           selected task, one existing ledger transaction rejoins the exact
           declared scope, current source epoch, committed original publication,
           authority revision/fence and current catalog version/content.
           Candidate/body mutation, stale cuts, withdrawal and source retirement
           cannot register a new task. Restart reads the retained declaration,
           not a Go service cache. Immutable task and spent claim rules remain. */
    }
    requirement def DirectRustOperationIngress {
        doc /* Rust's existing operation listener directly authenticates callers,
           admits bounded streams and invokes the existing ledger/broker/output
           path. Go preparation is a source-only command and exits before the
           request; it needs neither operation credentials nor an ingress socket.
           Default prepare enables direct fixed and catalog-selected operations;
           explicit serve retains reference relay controls until R5.
           A complete typed plan retains the existing direct protocol. An exact
           family/node key resolves activated Prepared or declared ledger data;
           partial overrides are not keys, and no lookup grants authority.
           Resolve using the sealed activation revision/fence, never current-head
           rebasing. All final guards, encoding, order, cancellation, backpressure,
           terminal status and unknown holds remain in the existing Rust owners.
           Direct OAuth observes the actual TLS sender and rejects caller-supplied
           relay evidence before execution admission. Signed relay delegation is
           a separate explicit deployment mode, not a direct-mode fallback. */
    }
    requirement def RustSchemeRuntimeBoundary {
        doc /* The target operation path terminates at the existing Rust server,
           broker and ledger. Reuse the affine Scheme owner for necessary bounded
           semantic derivation; publication preparation is not a per-frame task.
           No Go relay, Kubernetes API call or controller reconciliation is required
           for each request/frame. Rust preserves fresh source/version checks,
           Cedar permission, reservation, frontier/claim, complete response release,
           cancellation and unknown holds. This design is not a latency result. */
    }
    requirement def CloudAdapterAuthorityBoundary {
        doc /* A cloud adapter carries authenticated observations and proposals,
           not business selection or effect authority. Kubernetes UID, resource
           version and generation are observation coordinates, not ledger source
           revisions. Persist hard-fact intent in the existing source lane/ledger
           before ASCENT derives impact; release barriers only after transactional
           exact-source and intent-prefix checks. Duplicate/reordered watches,
           relist, deletion, restart and A-to-B-to-A cannot restore stale authority.
           Separate bounded adapter work from operation admission and owner work.
           A disconnected adapter cannot authorize new use of revoked facts. */
    }
    requirement def GoIntegrationLeverage {
        doc /* Go is optional in the target production graph. Retain an owned Go
           adapter only for a named required integration whose maintained Go API
           avoids substantial implementation and conformance work. Record SDK
           coverage, protocol alternatives, trust custody, version/support cost,
           failure isolation and retirement criteria. Go implementation of an
           external cloud service does not require Weaver to embed a Go runtime.
           Development OpenSysML tooling and independent signing services have
           separate retirement decisions; migration cannot merge issuer custody. */
    }
    item def CloudResourceObservation {
        attribute resourceIdentity : String;
        attribute resourceVersion : String;
        attribute generation : String;
        attribute authenticatedSource : String;
        item cut : ReconciliationCut;
        doc /* Target envelope over existing typed source/fact contracts, not a
           second durable store. A partial watch image is not a coherent ledger
           cut. Secret bytes stay with their existing credential owner. */
    }
    item def CloudIntegrationAssessment {
        attribute integration : String;
        attribute requiredCapability : String;
        attribute supportedInterface : String;
        attribute maintainedSDKBenefit : String;
        attribute operationalCost : String;
        attribute retirementCondition : String;
        item evidence : EvidenceAxis[0..*];
    }
    item def ProviderAvailabilityObservation :> CloudResourceObservation {
        attribute available : Boolean;
        doc /* The namespaced ProviderAvailability resource exposes one desired
           fact. Deployment binds its namespace, name and UID to one admitted
           hard-fact feed. Kubernetes status reflects a resolved ledger cut.
           A replacement UID needs an explicit binding. A watch event triggers
           a fresh read before the adapter stages withdrawal. The source-only
           recovery view returns pending barriers in ledger order. Stage the
           newly observed intent before resolving older pending work. */
    }
    action def IngestCloudObservation {
        in item observation : CloudResourceObservation;
        out item cut : ReconciliationCut;
        doc /* The Rust kube-rs adapter feeds the existing source lane.
           Observation admission precedes Scheme ReconcileObjectSet. No watch
           callback directly publishes or executes an effect. */
    }
    part def RustSchemeAllocation {
        requirement composition : SchemeSourceComposition;
        requirement advisory : AdvisorySourceComposition;
        action compose : ComposeSourceBeforeSeal;
        requirement operation : RustSchemeRuntimeBoundary;
        requirement directIngress : DirectRustOperationIngress;
        requirement sourcePreparation : SourceBoundOperationPreparation;
        requirement cloud : CloudAdapterAuthorityBoundary;
        requirement leverage : GoIntegrationLeverage;
        action ingest : IngestCloudObservation;
        action reconcile : ReconcileObjectSet;
        action prepare : ControllerObjectLifecycle::PrepareObject;
        action advance : AdvanceGovernedRoutine;
        doc /* Target semantic owner is Scheme/POO/gerbil-ascent, effect owner is
           existing Rust admission/broker/ledger, and cloud observation owner is
           a bounded Rust adapter by default. Go development tooling is retained
           while its existing OpenSysML SDK provides concrete leverage. */
    }
    part rustSchemeTarget : RustSchemeAllocation;
}
