package WeaverExecution {
    doc /* Zero Trust is the mandatory runtime model for all effects and semantic
       extensions: authenticate original scope, authorize actual use against
       current authority, consume once and preserve uncertain exposure. Runtime
       allocation and safety requirements follow that model. Source evidence ports and
       the derived-evidence adapter describe the target architecture only; their
       production delivery is gated by 59.27. Existing effect owners are reused. */

    requirement def OriginalTaskBinding {
        doc /* Preserve family, declared node, profile, endpoint and exact wire body commitment. */
    }
    requirement def SharedBudget {
        doc /* Original node holds sum to no more than the original family budget. */
    }
    requirement def ConsumeBeforeSend {
        doc /* Persist irreversible unknown consumption before any possible external bytes. */
    }
    requirement def CurrentFinalGuard {
        doc /* Serialize the final policy/history revision and fence check with actual send. */
    }
    requirement def UnknownRetainsHold {
        doc /* Crashes, lost replies and partial writes cannot prove no execution or refund capacity. */
    }
    requirement def NoImplicitRetry {
        doc /* One logical node has one consumed send opportunity; redirects and SDK retries are disabled. */
    }
    requirement def DevelopmentPolicy {
        doc /* ASP Rust is a deny-mode Cargo test dependency and is absent from the runtime graph. */
    }

    item def CanonicalProposal {
        item progression : PolicyEvidenceDesign::SessionProgressionProposal[0..1];
        doc /* Target successor metadata is joined at existing admission. A
           historical predecessor receipt alone is not a new execution permit. */
    }
    item def DurableOutcome;
    item def ConsumedPermit;
    item def CanonicalWireRequest;
    port def ProposalPort {
        out item proposal : CanonicalProposal;
    }
    port def OutcomePort {
        out item observation : DurableOutcome;
    }
    port def ConsumedPort {
        out item permit : ConsumedPermit;
    }
    port def WirePort {
        out item request : CanonicalWireRequest;
    }
    part def SchemeSemanticPublisher {
        doc /* Scheme is the programmable semantic owner of reusable routines,
           strategies, semantic profiles and task assignments through Agentic AI
           Lab and admitted Yuanxu scopes. It proposes effects, never consumes
           execution authority. Current delivery freezes a source bundle;
           observation-driven Session/Workflow progression and embedded VM
           lifecycle remain separate delivery gates. JSON/YAML is a data subset,
           not a replacement for Scheme functions and POO composition.
           Higher-order Governance composes assessment protocols, obligations,
           evidence transformations and review/compensation strategies using
           existing AA generic methods and Workflow/Funflow. Captured callback
           dependencies belong to the projection closure; local assessment or
           compensation cannot grant sends, undo bytes or refund unknown usage.
           Reuse inherited JsonSchema and POO/AA contracts for JSON data profiles
           and Scheme-produced data. Configuration schema, semantic Profile and
           actual Cedar schema are distinct admission/authorization contracts. */
        port sourceCandidates : PolicyEvidenceDesign::CandidatePort;
        port sourceObservations : ~PolicyEvidenceDesign::ObservationPort;
        port derivedFacts : ~PolicyEvidenceDesign::DerivedFactsPort;
        port effectObservations : ~PolicyEvidenceDesign::EffectObservationPort;
    }
    part def GoControlAdapter {
        doc /* Refine routine node and routing preferences; emit typed data with
           no send capability. Carry configuration/capture commitments and
           authenticated original source identity over gRPC. Reconcile ambiguity;
           never evaluate Scheme, manage GC roots or forward foreign pointers. */
        port proposals : ProposalPort;
        port observations : ~OutcomePort;
        port sourceCandidates : ~PolicyEvidenceDesign::CandidatePort;
        port sourceCommands : PolicyEvidenceDesign::CandidatePort;
        port sourceOutcomes : ~PolicyEvidenceDesign::ObservationPort;
        port semanticObservations : PolicyEvidenceDesign::ObservationPort;
        port effectObservations : ~PolicyEvidenceDesign::EffectObservationPort;
        port semanticEffectObservations : PolicyEvidenceDesign::EffectObservationPort;
    }
    part def CedarGatewayLibrary {
        doc /* Core library dependency, not another daemon or authority store.
           Existing upstream owners supply PolicyModules, execution Delta,
           BoundOperation/PolicySnapshot, pure operation/authority checks and
           schema-bound Rust replay. The upstream Gateway Lean library composes
           schema-valid actual-effect admission, original-operation/grant ledger
           transitions and conditional exact execution-Delta proofs. Gateway
           governance profiles use LeanPoo Dataflow/C4 inheritance and the
           existing ObjectProfile factory-indexed Session with explicit Contract
           strengthening. Scope/schema/source/root/policy binding joins actual
           admission to Delta. These laws preserve supplied identities and pure
           returned ledgers; they do not prove authenticated original identity,
           shared budget arithmetic or durable ordered history.
           The ProfileAdmission boundary binds the exact selected profile and
           original scope to an independently supplied current publication.
           Gateway consumption requires a PublishedReceipt indexed by that
           explicit publication; raw Receipt has no consumption path. Rust
           authenticates and joins the publication at final CAS; a caller-chosen
           or rolled-back publication is outside the library's guarantee.
           Weaver owns scenario-specific Rust execution, current actual facts,
           durable CAS, budget retention, account/source custody, final driver and
           gRPC integration. Pure Lean receipts do not authenticate Host state or
           authorize transport. AWS AgentCore stays platform-specific. */
    }
    part def RustPolicy {
        doc /* Evaluate Cedar against actual operation and authoritative deciding
           state; reject evaluation errors. Local CFFI preflight is inert. The
           target capture adapter validates canonical Rust-owned data before async
           use; it does not make invalid caller addresses safe or replace source
           custody, durable publication and current final execution guards. */
        doc /* Consume the upstream core library's semantic/runtime contracts;
           do not duplicate Cedar or Delta evaluation inside Weaver. */
    }
    part def RustLedger {
        doc /* One deciding store owns immutable tasks, reservations, logical keys, current revision and fence. */
        doc /* Commit-floor target: reuse publication exact-result retention,
           account/WAL owner validation and current-cut CAS. Independent authority
           records full four-prefix decisions and fences stale epochs. Local WAL
           and materialized projections may roll back; floor authority may not
           roll back with them. This boundary is a deployment/refinement premise,
           not established by placing two SQLite files on one host. */
        port proposals : ~ProposalPort;
        port observations : OutcomePort;
        port consumed : ConsumedPort;
        port sourceCommands : ~PolicyEvidenceDesign::CandidatePort;
        port sourceOutcomes : PolicyEvidenceDesign::ObservationPort;
        port effectOutcomes : PolicyEvidenceDesign::EffectObservationPort;
    }
    part def RustFinalBroker {
        doc /* Use the consuming ledger handle; serialize the final guard through the bounded transport call. */
        doc /* Target rollback-safe mode requires the sole transport owner and
           provider credentials outside the restored worker domain. Its current
           cut/epoch check, durable one-use send burn and bounded socket admission
           serialize with authority changes. Never return a reusable permission
           that an old worker can send with offline. Unknown results retain the
           original reservation; already admitted bytes may drain. */
        port consumed : ~ConsumedPort;
        port wire : WirePort;
    }
    part def HttpsExecutor {
        doc /* Exact committed target and body, no inherited proxy, redirect or automatic retry. */
        port wire : ~WirePort;
    }
    part def TelemetryService {
        doc /* Default service in the target architecture; implementation and exporter delivery remain pending. Local bounded signals observe source/authority/effects. Export needs explicit configuration and Policy. Telemetry cannot acknowledge an authority commit, authorize a send or release unknown budget. */
        doc /* Observe already extracted metadata with bounded nonblocking
           submission. Do not re-read a mutable request, retry an effect or mutate
           authority/history/accounting from a telemetry callback. */
    }
    part def DerivedEvidenceAdapter {
        doc /* Optional derived-evidence target. Prefer Agentic AI Lab's inherited
           Gerbil Ascent sessions, rules and context invalidation; MRR is selected
           only for a demonstrated semantic-query/lineage requirement or measured
           advantage. No new direct dependency is added by this model. Both
           backends emit typed candidates, never authorization or accounting.
           mrr-data remains an optional physical adapter. */
        attribute selectedBackend : PolicyEvidenceDesign::DerivationBackend = PolicyEvidenceDesign::DerivationBackend::inheritedAscent;
        port candidates : PolicyEvidenceDesign::DerivedFactsPort;
    }
    action def Propose;
    action def Enqueue;
    action def Consume;
    action def GuardAndSend;
    action def RecoverOutcome {
        doc /* Go observes the Rust-owned durable result under the frozen
           publication identity and digest before submitting an absent decision.
           A known result is read-only recovery. Unknown or rejected results do
           not activate ingress. A historical receipt never replaces current
           Rust Policy, fence, original claim, history or budget checks. */
    }

    part gateway {
        part semanticPublisher : SchemeSemanticPublisher;
        part controlAdapter : GoControlAdapter;
        part policy : RustPolicy;
        part ledger : RustLedger;
        part broker : RustFinalBroker;
        part executor : HttpsExecutor;
        part telemetry : TelemetryService;
        part derivedEvidence : DerivedEvidenceAdapter[0..1];
        connect semanticPublisher.sourceCandidates to controlAdapter.sourceCandidates;
        connect controlAdapter.sourceCommands to ledger.sourceCommands;
        connect ledger.sourceOutcomes to controlAdapter.sourceOutcomes;
        connect controlAdapter.semanticObservations to semanticPublisher.sourceObservations;
        connect ledger.effectOutcomes to controlAdapter.effectObservations;
        connect controlAdapter.semanticEffectObservations to semanticPublisher.effectObservations;
        connect derivedEvidence.candidates to semanticPublisher.derivedFacts;
        connect controlAdapter.proposals to ledger.proposals;
        connect ledger.observations to controlAdapter.observations;
        connect ledger.consumed to broker.consumed;
        connect broker.wire to executor.wire;
    }
}
