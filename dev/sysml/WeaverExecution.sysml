package WeaverExecution {
    private import ScalarValues::*;
    doc /* Zero Trust is the mandatory runtime model for all effects and semantic
       extensions: authenticate original scope, authorize actual use against
       current authority, consume once and preserve uncertain exposure. Runtime
       allocation and safety requirements follow that model. Source evidence ports and
       the derived-evidence adapter describe the target architecture only; their
       production delivery is gated by 59.27. Existing effect owners are reused. */

    requirement def TursoAdmissionAtomicity {
        doc /* All ledger and test IO uses MRR Data public Turso ownership. Native
           immediate transactions retain one original claim, budget and fencing
           image. Prepare/commit performs no provider send; unknown results keep
           exposure and never create a replacement grant. Eager rollback and
           poisoned-session refusal prevent old-worker reuse. A complete durable
           image includes WAL; SHM is derived. Original finite manifest equality,
           duplicate-key rejection, current use and final transport custody remain
           mandatory. Atomicity and FULL durability are native refinement premises,
           exercised by actual concurrent/failure/restart/partial-write tests. */
    }
    requirement def OriginalTaskBinding {
        doc /* Preserve family, declared node, profile, endpoint and exact wire body commitment. */
    }
    requirement def SharedBudget {
        doc /* Original node holds sum to no more than the original family budget. */
        doc /* A single deciding projection covers request, stream-message and
           provider reservations together. Admission and actual use require all
           retained execution-kind claims and an exact bijection between each
           claim's member manifest and the request/message/provider rows. A
           member binds its logical key, original digest and ceiling; surviving
           messages cannot mask a missing sibling. Check finite manifests up to
           the source contract bound, including the maximum size, rather than
           assuming a two-member test proves that boundary. A fresh Policy
           revision/fence cannot repair missing original members or fund a
           previously unadmitted source-declared message. Equality of every retained reservation with its
           original proposal or plan ceiling, exact shared exposure conservation and equality
           between the budget projection and the original task budget. Local
           checks of each effect kind cannot substitute for the shared sum. */
    }
    requirement def ConsumeBeforeSend {
        doc /* Persist irreversible unknown consumption before any possible external bytes. */
        doc /* Final stream use joins the exact durable range sequence, offset,
           length and unwritten unknown state to the owned permit, message cursor
           and next sequence. An inconsistent receipt denies the writer and
           retains unknown exposure; it cannot prove not-sent or authorize repair.
           This detects partial recovery inconsistency, not coherent database rollback. */
    }
    requirement def CurrentFinalGuard {
        doc /* Serialize the final policy/history revision and fence check with actual send. */
    }
    requirement def UnknownRetainsHold {
        doc /* Crashes, lost replies and partial writes cannot prove no execution or refund capacity. */
        doc /* Startup does not synthesize execution claims from outcome rows.
           An orphaned request claim cannot admit a replacement operation; a
           later message cannot recreate a missing stream claim while earlier
           retained messages exist. A missing manifest is not backfilled from a
           surviving outcome image. Orphaned holds cannot be recycled into new
           messages after outcome-row loss. Contradictory recovery images deny effects
           and remain observable; this is not independent rollback detection. */
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
    item def PolicyDecision {
        doc /* Current Cedar permission plus error-free evaluation. A decision
           value alone is not a consumed permit or a reusable send handle. */
    }
    port def PolicyEvaluationPort {
        out item request : CanonicalProposal;
        in item decision : PolicyDecision;
    }
    port def ProposalPort {
        doc /* Default Go/Rust process boundary is authenticated gRPC with typed
           Protobuf messages. External provider body/schema documents can contain
           JSON without making this a JSON command transport. */
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
        attribute leanDeclaration : String = "CedarPooSpec.Gateway.ProfileObject.Publication";
        attribute leanFields : String = "context,session,selected,projected";
        attribute securityName : String = "Scheme / Original contract";
        attribute securityResponsibility : String = "Task scope and required parents\nPublished selected profile\nConfiguration grants no send right";
        attribute displayName : String = "Scheme / Semantics";
        attribute responsibility : String = "Agentic AI Lab modules\nRoutines + original profiles\nPolicy and source projections";
        attribute glyph : String = "library";
        attribute visualRole : String = "publication";
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
        attribute displayName : String = "Go / Control + routing";
        attribute responsibility : String = "Cloud and protocol integration\nPublish authenticated proposals\nChoose eligible providers";
        attribute glyph : String = "go";
        attribute visualRole : String = "selection";
        doc /* BootstrapProducer receives the server's typed CompileSource
           artifact over authenticated gRPC and reobserves source authority.
           Its typed independent copy does not JSON-roundtrip the source. Source
           staging, task registration and publication still use existing CAS;
           response admission is not permission for a later send. RunFromEnv
           selects exactly one approved producer or JSON/YAML data file; Scheme
           files cannot launch a compiler, and producer failure cannot fall back
           to a file. The Rust deployment still must install its approved graph. */
        doc /* Refine routine node and routing preferences; emit typed data with
           no send capability. Carry configuration/capture commitments and
           authenticated original source identity over gRPC. Reconcile ambiguity;
           never evaluate Scheme, manage GC roots or forward foreign pointers. */
        doc /* Go's target value is cloud/protocol integration, not a language
           monopoly on Kubernetes or networking. Own discovery/watch/reconcile,
           bounded ingress connections and protocol adapters, routing candidates,
           source-outcome recovery and cloud lifecycle integration. Reuse the Go
           ecosystem instead of implementing a duplicate Rust control adapter.
           Ingress TLS/cloud-management credentials are distinct from provider
           execution secrets. A provider SDK that performs its own final request
           cannot bypass Rust; only inert encoding/metadata facilities may be
           reused here without another governed transport refinement. */
        doc /* Informer caches, health probes and SDK observations are candidates,
           not authoritative Policy/history facts. Re-list/reconnect preserves
           original identities and unresolved intent; all final deciding joins
           remain Rust-owned. Current Go code implements config/routing/RPC
           recovery, not Kubernetes controllers or complete protocol discovery.
           Target ecosystem integrations must earn their cost through measurable
           adapter reuse and operator behavior; a pure forwarding layer provides
           insufficient justification. No Go-versus-Rust speed claim follows. */
        doc /* Existing provider responses support default Protobuf events and
           optional Arrow IPC batches over the same gRPC stream. This is not a
           Flight service or end-to-end zero-copy path. Schema, row/range binding,
           ownership and per-release authorization apply to either encoding.
           Scheme/Rust process-local C ABI is a separate boundary, not the
           default communication mechanism between Go and Rust services. */
        doc /* Discovery/watch caches, route candidates and transport flow credits
           never publish their own authority. Preserve original canonical identity
           on protocol reconnect, and propagate cancellation to the original RPC.
           Delivered data can drive observation/proposal logic; any follow-up tool
           or provider effect returns to Rust final admission. A receive callback
           is not an exception to provider credential or execution custody. */
        doc /* The same rule applies to cloud SDKs: an agent-triggered Kubernetes
           mutation is a tool effect, not a discovery watch. Base Go integration
           observes or compiles a canonical proposal; it cannot use SDK-managed
           HTTP/retry hooks to perform that effect outside Rust. A separately
           delegated executor would need its own qualified final-hop contract
           before enablement; none is implied by importing a Go client library. */
        port proposals : ProposalPort;
        port observations : ~OutcomePort;
        port sourceCandidates : ~PolicyEvidenceDesign::CandidatePort;
        port sourceCommands : PolicyEvidenceDesign::CandidatePort;
        port sourceOutcomes : ~PolicyEvidenceDesign::ObservationPort;
        port semanticObservations : PolicyEvidenceDesign::ObservationPort;
        port effectObservations : ~PolicyEvidenceDesign::EffectObservationPort;
        port semanticEffectObservations : PolicyEvidenceDesign::EffectObservationPort;
    }
    part def CedarSecurityFrameworks {
        doc /* Architecture alignment is maintained in 59.51-zero-trust-architecture.
           NIST PE, PA and PEP are logical roles, not language or daemon names.
           Scheme AA Session/Workflow/Governor owns semantic governance; Rust
           owns authoritative Cedar assessment and final effect mediation; Go
           owns cloud identity/protocol integration and control orchestration.
           Authenticated transport alone never grants application authority. */
        doc /* Generic ZeroTrust/UsageControl composes pre/ongoing authorization,
           conditions, witnessed obligation actions and mutation relations over
           the application's existing transitions. Recovery is not authorization;
           closure requires terminal AND accounted. Post-use accounting is an
           application extension, not an imported UCON eventuality theorem.
           Required identity/resource/context interpretations and freshness cuts
           must be bound at final use. All native claims require separate evidence. */
        doc /* SPEC owns independent functional Authorization and ZeroTrust
           frameworks, each under its own directory and aggregate entrypoint.
           ZeroTrust/Model, Composition and Continuous define typed requirements,
           adaptation, strengthening and ongoing effect checks. ProfileObject
           interprets them through actual LeanPoo inheritance/Contract/Session.
           The complete ZeroTrust import closure must exclude Gateway. */
        doc /* A root-indexed profile proof preserves the root, not every extra
           ancestor requirement under raw POO overrides. Gateway composition
           must retain the independently required parent Session and selected
           Session, then conjoin both actual projections. The trusted publisher
           must bind the required parent's full source/Contract, not its name
           or a Session selected by the child request. */
        doc /* Gateway.ZeroTrust consumes the generic functions with its own
           publication-indexed admission and operation/authority ledger. Ongoing
           use keeps the original committed prefix and re-assesses current
           attributes; it never consumes the root again for each streamed row.
           Authorization/Delta owns Cedar comparison and its conditional proofs.
           Neither core framework imports the Gateway specialization. */
        doc /* NIST provides architecture requirements and UCON provides the
           continuity/mutable-attribute research basis. The checked fragment is
           finite effect-boundary safety, not the full UCON temporal logic or a
           deployed certification. Framework predicates and CommittedPrefix
           require authenticated, rollback-resistant native materialization.
           Proof records are duplicable, never affine native send handles. */
        doc /* Weaver's candidate enrichment is checked in isolation. Normal
           fixed-pin acceptance remains separate. Generic framework laws do not
           establish the actual current-state/SQL/queue/IO refinement. */
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
        attribute leanDeclaration : String = "CedarPooSpec.Gateway.Receipt";
        attribute leanFields : String = "preparationValid,contextMatches,sourceMatches,effectMatches,stateMatches,checksAccepted,policyCurrent,requestValid,entitiesValid,allowed";
        attribute securityName : String = "Cedar / Actual request";
        attribute securityResponsibility : String = "Exact effect, facts and schema\nCurrent Policy + profile checks\nError-free Allow is one premise";
        attribute displayName : String = "Cedar / Policy";
        attribute responsibility : String = "Evaluate the exact effect\nRequire error-free permission\nAllow is not a send handle";
        attribute glyph : String = "decision";
        attribute visualRole : String = "policy";
        doc /* Evaluate Cedar against actual operation and authoritative deciding
           state; reject evaluation errors. Local CFFI preflight is inert. The
           target capture adapter validates canonical Rust-owned data before async
           use; it does not make invalid caller addresses safe or replace source
           custody, durable publication and current final execution guards. */
        doc /* Consume the upstream core library's semantic/runtime contracts;
           do not duplicate Cedar or Delta evaluation inside Weaver. */
        port evaluation : ~PolicyEvaluationPort;
    }
    enum def AdmissionStorageEngine {
        enum turso;
    }
    enum def AdmissionStorageOwner {
        enum mrrDataBackend;
    }
    part def RustLedger {
        attribute leanDeclaration : String = "CedarPooSpec.Gateway.ZeroTrust.Proposal";
        attribute leanFields : String = "before,receipt,contextBound,authorityId,after,consumption";
        attribute securityName : String = "Rust / Original consumption";
        attribute securityResponsibility : String = "Original operation + grant\nCommit both ledgers with budget\nRenewed grants cannot replay work";
        attribute displayName : String = "Rust / Authority ledger";
        attribute responsibility : String = "MRR Data Backend / Turso\nClaim, budget and fence together\nPersist original consumption";
        attribute glyph : String = "rust";
        attribute visualRole : String = "semantic";
        attribute storageEngine : AdmissionStorageEngine = AdmissionStorageEngine::turso;
        attribute storageOwner : AdmissionStorageOwner = AdmissionStorageOwner::mrrDataBackend;
        doc /* Production persistence uses mrr-data-backend::turso_driver only.
           Weaver owns its domain schema and admission rules, not another DB
           provider or ORM. The selected feature is turso; no direct rusqlite,
           alternative engine, automatic replay or remote replication is enabled.
           One FULL/WAL native immediate transaction serializes original claims,
           holds, consumption, Policy and fence. Settings are read back on open.
           Standard future driving adds no runtime or worker pool. Final guarded
           callbacks retain the deciding transaction through bounded transport.
           Commit never initiates a provider send. Unknown commit poisons the
           session; rollback is driven eagerly, and original outcomes/holds must
           be recovered with fresh authoritative state. Complete closed-store
           fault images include the durable WAL and discard transient SHM.
           Physical driver reuse does not prove independent anti-rollback custody
           or provider exactly-once delivery. MVCC scheduling is not activated. */
        doc /* One deciding store owns immutable tasks, reservations, logical keys, current revision and fence. */
        doc /* Commit-floor target: reuse publication exact-result retention,
           account/WAL owner validation and current-cut CAS. Independent authority
           records full four-prefix decisions and fences stale epochs. Local WAL
           and materialized projections may roll back; floor authority may not
           roll back with them. This boundary is a deployment/refinement premise,
           not established by placing two local database files on one host. */
        port proposals : ~ProposalPort;
        port observations : OutcomePort;
        port consumed : ConsumedPort;
        port sourceCommands : ~PolicyEvidenceDesign::CandidatePort;
        port sourceOutcomes : PolicyEvidenceDesign::ObservationPort;
        port effectOutcomes : PolicyEvidenceDesign::EffectObservationPort;
        port policyEvaluation : PolicyEvaluationPort;
    }
    part def RustFinalBroker {
        attribute leanDeclaration : String = "CedarPooSpec.Gateway.ZeroTrust.FinalUse";
        attribute leanFields : String = "sameView,authenticated,current,profileAuthority,committed,unknownRetained,notRevoked,mediated";
        attribute securityName : String = "Rust / Final-use guard";
        attribute securityResponsibility : String = "Identity, profile and current view\nDurable consume + unknown holds\nFence every actual external effect";
        attribute displayName : String = "Rust / Final broker";
        attribute responsibility : String = "Own consumed opportunities\nGuard dispatch and each range\nUnknown exposure remains held";
        attribute glyph : String = "capture";
        attribute visualRole : String = "execution";
        doc /* Use the consuming ledger handle; serialize the final guard through the bounded transport call. */
        doc /* Target rollback-safe mode requires the sole transport owner and
           provider credentials outside the restored worker domain. Its current
           cut/epoch check, durable one-use send burn and bounded socket admission
           serialize with authority changes. Never return a reusable permission
           that an old worker can send with offline. Unknown results retain the
           original reservation; already admitted bytes may drain. */
        doc /* Target admission LP: after durable burn, recheck actual current
           cut/epoch and authenticated transport incarnation, then enter the
           bounded synchronous transport operation while holding the same gate
           that serializes every floor mutation. Neither queue admission nor a
           committed log entry sends. Do not release the gate then invoke IO.
           Existing blocking provider dispatch holds its deciding transaction
           through request/response headers; shortening that window needs a new
           transport refinement and measurements, not a change of proof labels. */
        port consumed : ~ConsumedPort;
        port wire : WirePort;
    }
    part def HttpsExecutor {
        attribute leanDeclaration : String = "CedarPooSpec.Gateway.ZeroTrust.CommittedPrefix";
        attribute leanFields : String = "tail,installed";
        attribute securityName : String = "Rust / Stream continuity";
        attribute securityResponsibility : String = "Retain original spent prefix\nReassess each new governed use\nRecovery cannot mint permission";
        attribute displayName : String = "Bounded HTTPS executor";
        attribute responsibility : String = "Send exact authorized bytes\nDisable implicit SDK retries\nReport partial or unknown writes";
        attribute glyph : String = "capture";
        attribute visualRole : String = "execution";
        doc /* Exact committed target and body, no inherited proxy, redirect or automatic retry. */
        port wire : ~WirePort;
        port provider : WirePort;
    }
    part def LlmProviderEndpoint {
        attribute displayName : String = "LLM / Tool endpoint";
        attribute responsibility : String = "Bound route and request\nExternal effects and responses\nNo inferred exactly-once\ndelivery";
        attribute glyph : String = "model";
        attribute visualRole : String = "capture";
        doc /* External model provider boundary. Its response does not authorize
           further sends, settle usage or release unknown reservations. */
        port request : ~WirePort;
    }
    part def ExecutionAuthorityDeployment {
        doc /* Target allocation of the existing gateway parts, not a second
           implementation or a deployed manifest. Scheme/Go and retryable workers
           belong to the worker restore domain. gateway.ledger, gateway.broker
           and gateway.executor share one independent Rust execution-authority
           domain and one active process/serialization gate per security shard.
           Its authenticated committed prefix, immutable outcomes and burns must
           survive restoration of any worker image. Floor, credentials and socket
           state cannot share that worker rollback operation. */
        doc /* Only the active executor holds provider secrets, TLS sessions and
           outbound sockets. Workers have authenticated proposal/observation RPC
           access, no provider secret mount, no direct provider egress and no raw
           FD or reusable send-token handoff. Provider credentials are distinct
           from Go publication and agent ingress credentials. Arrow is optional
           bulk data transport and inherits the same final gate. */
        doc /* All mutations of this shard's four-prefix floor enter the same
           authority gate; direct storage writes and background log replay cannot
           publish or send around it. The base deployment stops admission and
           waits for authentic exact-owner process/egress quiescence before
           replacement. Unreachable old node means no automatic takeover. Neither
           Kubernetes leadership nor store leadership fences an existing socket.
           Multi-node failover requires separately qualified final-egress fencing.
           Trust roots and this durable authority's own rollback remain explicit
           Host premises; logical isolation is sufficient, physical isolation is
           not required. */
        doc /* Current server RPC listeners are loopback-only. Cross-pod target
           deployment therefore still needs a qualified reachable listen interface,
           authenticated role separation and network policy; a same-host Unix
           transport would need its own peer-identity qualification. Neither is
           delivered by a diagram or by changing the batch encoding to Arrow. */
        doc /* Partition only independent security domains. Original claim,
           shared budget/history and publication ordering must share one shard
           until a cross-shard protocol is actually proved. One active transport
           owner does not constrain host CPU cores or unrelated shard concurrency.
           Stage computation outside the gate; do not weaken final exclusion to
           hide the present bounded-call contention cost. */
    }
    part def TelemetryService {
        attribute displayName : String = "Telemetry";
        attribute responsibility : String = "Local operational\nobservations\nExplicitly governed export\nEvents grant no\nexecution rights";
        attribute glyph : String = "evidence";
        attribute visualRole : String = "capture";
        doc /* Current Go source/startup producers emit fixed-label local slog
           metadata; native integration fixtures supply clocked phase records.
           These ordinary stderr diagnostics are not the target bounded event
           bus, loss counters, exporter, durable audit or readiness authority.
           Their presence cannot prove completion or discharge unknown holds. */
        doc /* Default service in the target architecture; implementation and exporter delivery remain pending. Local bounded signals observe source/authority/effects. Export needs explicit configuration and Policy. Telemetry cannot acknowledge an authority commit, authorize a send or release unknown budget. */
        doc /* Observe already extracted metadata with bounded nonblocking
           submission. Do not re-read a mutable request, retry an effect or mutate
           authority/history/accounting from a telemetry callback. */
    }
    part def DerivedEvidenceAdapter {
        attribute displayName : String = "Derived evidence";
        attribute responsibility : String = "Provenance-bound candidates\nGoverned semantic observations\nDerivation is not authority";
        attribute glyph : String = "document";
        attribute visualRole : String = "selection";
        doc /* Optional derived-evidence target. Prefer Agentic AI Lab's inherited
           Gerbil Ascent sessions, rules and context invalidation; MRR is selected
           only for a demonstrated semantic-query/lineage requirement or measured
           advantage. No new direct dependency is added by this model. Both
           backends emit typed candidates, never authorization or accounting.
           mrr-data remains an optional physical adapter for derived evidence.
           This is separate from RustLedger's target mrr-data-backend storage
           ownership; neither role makes MRR derivation a Policy authority. */
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

    part def Gateway {
        attribute displayName : String = "Agent Gateway / logical execution boundary";
        attribute glyph : String = "model";
    }
    part gateway : Gateway {
        part semanticPublisher : SchemeSemanticPublisher;
        part controlAdapter : GoControlAdapter;
        part policy : RustPolicy;
        part ledger : RustLedger;
        part broker : RustFinalBroker;
        part executor : HttpsExecutor;
        part provider : LlmProviderEndpoint;
        part telemetry : TelemetryService;
        part derivedEvidence : DerivedEvidenceAdapter[0..1];
        connection semanticPublisher_sourceCandidates_to_controlAdapter_sourceCandidates connect semanticPublisher.sourceCandidates to controlAdapter.sourceCandidates;
        connection controlAdapter_sourceCommands_to_ledger_sourceCommands connect controlAdapter.sourceCommands to ledger.sourceCommands;
        connection ledger_sourceOutcomes_to_controlAdapter_sourceOutcomes connect ledger.sourceOutcomes to controlAdapter.sourceOutcomes;
        connection controlAdapter_semanticObservations_to_semanticPublisher_sourceObservations connect controlAdapter.semanticObservations to semanticPublisher.sourceObservations;
        connection ledger_effectOutcomes_to_controlAdapter_effectObservations connect ledger.effectOutcomes to controlAdapter.effectObservations;
        connection controlAdapter_semanticEffectObservations_to_semanticPublisher_effectObservations connect controlAdapter.semanticEffectObservations to semanticPublisher.effectObservations;
        connection derivedEvidence_candidates_to_semanticPublisher_derivedFacts connect derivedEvidence.candidates to semanticPublisher.derivedFacts;
        connection controlAdapter_proposals_to_ledger_proposals connect controlAdapter.proposals to ledger.proposals;
        connection ledger_policyEvaluation_to_policy_evaluation connect ledger.policyEvaluation to policy.evaluation;
        connection ledger_observations_to_controlAdapter_observations connect ledger.observations to controlAdapter.observations;
        connection ledger_consumed_to_broker_consumed connect ledger.consumed to broker.consumed;
        connection broker_wire_to_executor_wire connect broker.wire to executor.wire;
        connection executor_provider_to_provider_request connect executor.provider to provider.request;
    }
    part targetDeployment : ExecutionAuthorityDeployment;
}
