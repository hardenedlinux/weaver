// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package AgentConnectivity {
    private import ScalarValues::*;
    doc /* Planned local Agent integration, not an implemented Magpie adapter or
       a qualified HTTP gateway. Phase one retains Magpie's UI, local host and
       Agent configuration owners and connects a fixed Weaver backend. Unified
       distribution is a later delivery decision. A Go interface is an adapter
       boundary; it does not supply a UI, a running host or CLI configuration.
       Requirements and acceptance cases below are design obligations only. */

    enum def DeliveryStatus { enum planned; enum qualified; }
    enum def ConfigOutcome { enum applied; enum restored; enum conflict; enum unknown; }
    enum def GatewayProtocol { enum openAiChat; enum openAiResponses; enum anthropicMessages; }
    enum def BackendBinding { enum existingGoRpc; enum httpCompatibility; }

    requirement def LocalAgentHostReadiness {
        doc /* Provide a user operation surface, a running local host and an
           Agent-specific configuration adapter. Phase one uses Magpie's own
           owners. Prepare endpoint, model, protocol and gateway credential;
           verify host/backend readiness before editing a CLI configuration.
           Model choices come from the backend's source-versioned catalog,
           filtered to the authenticated caller, not a second hard-coded list.
           Readiness is connectivity evidence, never execution authority.
           Stock Magpie connects through its standard HTTP-provider interface.
           Existing Go/RPC is an internal execution contract, not an available
           Magpie plugin. An in-host RPC join requires a maintained Magpie-side
           adapter. HTTP ingress and internal RPC are different layers; neither
           concrete join is implemented by this model. */
    }
    requirement def ReversibleAgentConfiguration {
        doc /* Reuse Magpie edit, applied/stash and drift ownership, rather than
           creating a second Weaver config writer or restore database. Qualify
           durable ownership intent before write and recover interrupted edits
           through that same owner; these crash guarantees are not presumed
           implemented upstream. Compare file identity and expected field values
           before atomic replacement. Preserve unrelated values and formatting.
           Restore only owned fields still equal to the values we wrote. Drift
           requires explicit reconciliation; an unknown write requires inspection
           of the same intent, never blind replay or whole-file restoration. */
    }
    requirement def SingleAgentRoutingAuthority {
        doc /* A Weaver-backed Magpie profile selects one fixed Weaver backend.
           Preserve an immutable request snapshot per attempt. Magpie account
           pools and direct-provider fallbacks must not bypass this profile's
           Weaver boundary. Scheme/POO/gerbil-ascent owns candidate semantics;
           the existing source lane and ledger own publication and actual use.
           Request transforms precede the final wire commitment. No-client-output
           does not prove no upstream execution; unknown exposure stays held.
           Optional direct Magpie profiles are separately named and cannot claim
           Weaver's end-to-end provider authorization guarantees. Admit each
           bounded conversational turn under an approved session/profile and
           shared budget before binding its exact wire body. Existing fixed-body
           and operation-key checks remain intact. Never provide source authority
           to the frontend or compile the whole Scheme source for every prompt. */
    }
    requirement def AgentCredentialCustody {
        doc /* Separate CLI-to-local-host credentials, host-to-Weaver credentials
           and upstream provider credentials. Application labels, User-Agent and
           session headers are observations, not authenticated user identities.
           A shared gateway credential identifies the local host unless explicit
           delegation authenticates a narrower caller. Reuse prepared credential
           and OAuth owners; supply scoped references to the UI and config owner,
           not provider secrets or a second token store. A managed distribution
           defaults discovery off through Magpie's existing control. An existing
           user-run host retains the user's privacy choices; the Weaver adapter
           does not import discovered accounts. Credential export and remote
           binding require separate explicit configuration. */
    }
    requirement def AgentDeploymentSeparation {
        doc /* Embedded Harness clients keep their independent weaver-llm graph
           and need neither Magpie nor a listener. An interactive local Gateway
           needs a host and operation surface, delivered as Magpie initially or
           by a later unified distribution. Server deployment retains existing
           authenticated source, Cedar, ledger and final-effect checks. Packaging
           alone cannot qualify a backend API, erase the local process or turn
           an internal Go package into a supported reusable interface. */
    }
    requirement def AgentConnectivityQualification {
        doc /* Qualify actual Codex and Claude Code configuration formats through
           isolated homes, plus finite local Snake Oil protocol fixtures. Cover
           connect/use/disconnect, external edits, interrupted writes, restart,
           host loss, cancellation, terminal tool release and identity separation.
           Reuse existing Weaver protocol/backpressure and four-worker controls;
           downstream wiring does not duplicate the upstream protocol suite.
           Separate UI/setup and compilation from warm request measurements.
           Local fixture success does not qualify vendor subscription flows or
           production deployment. Model parsing is not runtime acceptance. */
    }

    item def ModelSelection {
        attribute agentId : String;
        attribute profileId : String;
        attribute modelId : String;
        attribute protocol : GatewayProtocol;
        attribute backendEndpoint : String;
        attribute backendBinding : BackendBinding;
        attribute credentialReference : String;
        attribute sourceGeneration : Integer;
    }
    item def ConfigOwnership {
        attribute intentId : String;
        attribute agentId : String;
        attribute fileIdentity : String;
        attribute beforeDigest : String;
        attribute writtenDigest : String;
        attribute ownedFields : String [1..*];
        attribute selectionGeneration : Integer;
        doc /* References to the existing config owner's protected records. No
           secret values or second journal are introduced by this projection. */
    }
    item def ConfigReceipt {
        item ownership : ConfigOwnership;
        attribute outcome : ConfigOutcome;
    }
    item def PendingConfigEdit {
        attribute version : Integer = 1;
        attribute intentId : String;
        attribute field : String;
        attribute requestedValueDigest : String;
        attribute observedFieldsDigest : String;
        attribute ownershipDigest : String;
        attribute configPath : String;
        doc /* Retained inside Magpie's existing applied.json before invoking
           its setter. No requested secret value, restoration image or permit.
           The same intent and prior ownership are checked at final save.
           Process interruption, failed setter or final persistence failure
           leaves this intent unresolved; Keep and ordinary replay cannot erase
           it. A complete file identity/write-set plan is still required for
           automatic CAS restoration; matching field values are insufficient. */
    }
    item def TurnSubmission {
        attribute agentHint : String;
        attribute sessionHint : String;
        attribute selectedProfile : String;
        attribute boundedBodyReference : String;
        doc /* Untrusted request observations, not an original task or send grant.
           Admission authenticates the caller and checks current session policy. */
    }
    item def ProviderSessionScope {
        attribute sourceSession : String;
        attribute authenticatedPrincipal : String;
        attribute profileCommitment : String;
        attribute publicationCommitment : String;
        attribute budgetDomain : String;
        attribute historyDomain : String;
        attribute sharedBudget : Integer;
        attribute maxTurns : Integer;
        assert constraint boundedTurns { maxTurns >= 1 and maxTurns <= 64 }
        assert constraint positiveSharedBudget { sharedBudget > 0 }
        doc /* Rust provider_session.rs validates a one-node unbound Task
           template and fixed domains. Scheme selects concrete plans; Rust
           checks exact bytes and unchanged source bounds. This item conveys
           no currentness, admission, quota or send authority. */
    }
    item def SessionTurnBinding {
        attribute scopeCommitment : String;
        attribute operationId : String;
        attribute commandCommitment : String;
        attribute turnFamily : String;
        attribute exactWireCommitment : String;
        attribute sourceFactScope : String;
        doc /* Family derives from source scope and retry key, excluding body:
           changed retry bytes must conflict, not acquire a new identity.
           Each turn has its own origin but reuses budget/history domains.
           Persist the parent fact-scope binding in the same admission
           transaction and use it again at final send and range release;
           checking only the new family would miss parent fact withdrawal. */
    }
    item def GatewayCall {
        attribute gatewayPrincipal : String;
        attribute agentHint : String;
        attribute sessionHint : String;
        attribute originalTask : String;
        attribute finalWireDigest : String;
        doc /* The ingress authenticates gatewayPrincipal. Hints cannot populate
           that principal. Original task and wire binding join existing admission. */
    }
    item def GatewayResult {
        attribute complete : Boolean;
        attribute cancelled : Boolean;
        item usage : DisjointTokenUsage [0..1];
        doc /* Tool calls become usable only through a validated complete result.
           The Harness retains tool authorization and execution ownership. */
    }
    item def CompactTurnFacts {
        attribute scopeCommitment : String;
        attribute authenticatedPrincipal : String;
        attribute model : String;
        attribute outputTokenLimit : Integer;
        attribute messageCount : Integer;
        attribute bodyBytes : Integer;
        doc /* Counts refer to the already validated exact request held in Rust.
           They are advisory inputs, not a settlement or send permission. */
    }
    item def SessionRouteSelection {
        attribute scopeCommitment : String;
        attribute routeIndices : Integer [1..8];
        doc /* Indices refer only to the approved scope's declared targets. */
    }
    port def CompactTurnFactsPort { out item facts : CompactTurnFacts; }
    port def SessionRouteSelectionPort { out item selected : SessionRouteSelection; }
    item def RichTurnObservation {
        attribute version : Integer = 1;
        attribute terminal : Boolean;
        attribute encodedPayloadReference : String;
        attribute maxEncodedBytes : Integer = 65536;
        doc /* ProviderTurnEvent v1 is separate from legacy text. Terminal data
           retains tools, identity, usage and opaque provider continuation blocks.
           Event encoding carries no send authority. Protobuf has an explicit
           turn_json field; rich Arrow adds a bounded binary turn_json column,
           while legacy text retains its four-column schema. Capability remains
           unadvertised until
           source admission, decoder and final guarded delivery are qualified. */
    }
    item def DisjointTokenUsage {
        attribute ordinaryInput : Integer;
        attribute cacheReadInput : Integer;
        attribute cacheWriteInput : Integer;
        attribute outputTokens : Integer;
        assert constraint { ordinaryInput >= 0 and cacheReadInput >= 0 and cacheWriteInput >= 0 and outputTokens >= 0 }
        doc /* Shared Rust codec normalizes provider-reported categories, including
           OpenAI cache writes and cumulative Claude updates. Expose only after
           validated terminal; missing usage remains unknown. Commit categories
           with rich payload and record the same values in existing ledger usage.
           Counts alone confer no price, refund, issuer or settlement authority. */
    }
    item def ModelCapability {
        attribute modelId : String;
        attribute protocols : GatewayProtocol [1..*];
    }
    item def CatalogSnapshot {
        attribute sourceGeneration : Integer;
        attribute scopeCommitment : String;
        attribute observedVersion : String;
        item models : ModelCapability [0..*];
        doc /* Published available bindings, scoped to the authenticated reader.
           Catalog membership is not a send permit. Preparation checks generation. */
    }
    item def ResponseTextCoordinates {
        attribute responseId : String;
        attribute itemId : String;
        attribute outputIndex : Integer;
        attribute contentIndex : Integer;
        assert constraint boundedOutputIndex { outputIndex >= 0 and outputIndex < 64 }
        assert constraint boundedContentIndex { contentIndex >= 0 and contentIndex < 64 }
        doc /* Strict SDK observations retain provider coordinates from the
           first frame. Registered item/part identities and each part's streamed
           digest must match the final output; equal concatenated text alone
           cannot establish that assignment. This item grants no release. */
    }
    requirement def SourceScopedDiscovery {
        doc /* Read through the existing ledger/source owner. Require the
           authenticated principal, exact source binding, current publication
           and clear hard-fact prefix. Include fact generation in observedVersion
           so available A-B-A cannot restore an old observation. Discovery creates
           no task, hold, claim or provider send. Final use still rechecks its own
           admission; the catalog is not permission or HTTP qualification. */
    }
    requirement def PositionedStreamObservation {
        doc /* Identity, item/part order and indices must be validated rather
           than guessed by HTTP encoding. A signature is exposed as complete
           block metadata only after the matching Messages block closes.
           Tool arguments remain in the validated whole-turn result. Choose
           strict observations before decoding the first frame; a logical-only
           SDK reader is not evidence that an HTTP translation is qualified.
           Broker projects the closed metadata into the existing bounded turn.v1
           envelope. Control-only observations use the same reservation, exact
           payload commitment, final guard and delivery owner as text; they
           cannot mint completion or settle usage. Private argument/signature
           fragments drain locally without a public frame. Protobuf and Arrow
           retain identical coordinates; HTTP encoding grants no new authority.
           An HTTP encoder must pause later text when an earlier tool's required
           header is withheld until terminal. Reuse the already validated final
           output from the first withheld item; never replay the emitted prefix,
           invent headers or accumulate a second copy of all tail fragments.
           Bound total encoded bytes. Encoding and send qualification differ. */
    }
    item def HostStatus {
        attribute hostReady : Boolean;
        attribute backendReady : Boolean;
        attribute sameSelectionGeneration : Boolean;
    }
    port def SelectionPort { out item value : ModelSelection; }
    port def ConfigIntentPort { out item value : ConfigOwnership; }
    port def ConfigReceiptPort { out item value : ConfigReceipt; }
    port def TurnSubmissionPort { out item value : TurnSubmission; }
    port def GatewayCallPort { out item value : GatewayCall; }
    port def GatewayResultPort { out item value : GatewayResult; }
    port def HostStatusPort { out item value : HostStatus; }
    port def CatalogPort { out item value : CatalogSnapshot; }
    port def PlanPort { out item value : PolicyEvidenceDesign::ConfigurationCommitment; }

    part def UserOperationSurface {
        port selected : SelectionPort;
        port status : ~HostStatusPort;
        port catalog : ~CatalogPort;
        doc /* Phase one reuses Magpie's UI. User selects an Agent, a Weaver
           profile and model, sees readiness/drift and requests disconnect. */
    }
    part def MagpieLocalHost {
        port selected : ~SelectionPort;
        port edit : ConfigIntentPort;
        port edited : ~ConfigReceiptPort;
        port status : HostStatusPort;
        port agentCall : ~TurnSubmissionPort;
        port agentResult : GatewayResultPort;
        port backendCall : TurnSubmissionPort;
        port backendResult : ~GatewayResultPort;
        port controlSelection : SelectionPort;
        port backendCatalog : ~CatalogPort;
        port visibleCatalog : CatalogPort;
        doc /* A real local Magpie process, including its existing Go gateway.
           Phase one therefore has two network hops. Do not label it a UI-only
           component or claim a wholly Rust request path. Configure one Weaver
           provider for a Weaver-backed profile and retain the native UI host. */
    }
    part def AgentConfigAdapter {
        port intent : ~ConfigIntentPort;
        port receipt : ConfigReceiptPort;
        port configured : SelectionPort;
        doc /* Reuse each Agent's existing config format and Magpie's ownership
           records. Readiness, CAS, drift and restoration are qualified before
           users are offered Connect. Disconnect/restore does not require the
           gateway or upstream network to be available. After whole-host loss,
           reopen its local control owner before inspection/restoration. No vendor
           login file is rewritten here. */
    }
    part def CodingCli {
        port configured : ~SelectionPort;
        port call : TurnSubmissionPort;
        port result : ~GatewayResultPort;
    }
    part def WeaverIngressAdapter {
        attribute backendBinding : BackendBinding = BackendBinding::httpCompatibility;
        port selected : ~SelectionPort;
        port proposal : PlanPort;
        port request : ~TurnSubmissionPort;
        port forwarded : GatewayCallPort;
        port returned : ~GatewayResultPort;
        port result : GatewayResultPort;
        port backendCatalog : ~CatalogPort;
        port catalog : CatalogPort;
        doc /* Thin compatibility ingress for stock Magpie. Reuse public
           contracts and existing execution owners; Go internal packages are not
           cross-project extension APIs. Admit bounded turns through source/ledger
           owners, never invent source authority in this adapter. Reuse transport-
           independent SDK codecs while keeping guarded broker send ownership.
           Rich tool/Responses contracts use the versioned extension; legacy text
           profiles stay closed. No per-SSE VM call or post-commit mutation.
           Reuse the SDK TurnEncoder for bounded standard-protocol projection.
           Its bytes belong in native output preparation before the deciding
           release guard, not a second sender translating committed RPC bytes.
           ProviderOutput.prepare retains per-response projection on the same
           owner. Prepare every frame of the bounded snapshot before its final
           guard (at most four ranges / 32 rows), rather than encode remaining
           frames after commit. A rejected or cancelled response must discard
           that state without replay. Whole terminal handoff must
           finish before existing Workflow/Session advancement.
           Optional gateway.http in weaver.toml selects one source Session and
           a distinct token environment reference. Bind loopback only; never
           reuse RPC operation/source or provider credentials. Bearer and
           x-api-key are alternative closed forms, not cumulative authority.
           Reject delegated OAuth deployments until their peer binding has an
           explicit HTTP design. No implicit downgrade from the mTLS RPC realm.
           GET /v1/models reads current source facts on the existing lane.
           POST paths must match the profile both before and after admission;
           preserve the exact bounded JSON bytes and optional idempotency key.
           SseStream polls the same DeliveryCursor as the RPC receiver before
           handing prepared bytes to HTTP. Errors abort without a fabricated
           success terminator. Native HTTP tests use a labeled advisory double;
           real linked Scheme and stock Magpie remain separate obligations. */
    }
    part def WeaverSemanticControl {
        port proposed : ~PlanPort;
        port published : PlanPort;
        part sourceOwner : WeaverExecution::SchemeSemanticPublisher;
        part turnSelector : RetainedSessionSelector;
        doc /* Reuse Scheme/POO/gerbil-ascent, source lane, durable intent and
           ledger publication. Infer on bounded fact changes and publish the
           source/version-bound projection. Preserve A-B-A generation checks. */
    }
    part def RetainedSessionSelector {
        port facts : ~CompactTurnFactsPort;
        port selected : SessionRouteSelectionPort;
        attribute maxRetainedScopes : Integer = 1;
        attribute transfersPrompt : Boolean = false;
        attribute compilesSourcePerTurn : Boolean = false;
        attribute ownsAdmission : Boolean = false;
        doc /* Existing source lane carries SessionTurnInput compact facts to
           the same affine SchemeCompiler. Fixed weaver_session_turn_v1 binds
           a POO scope once and reuses one ASCENT session; warm calls carry only
           facts and scope commitment. The default source policy preserves
           declared target order with at most eight routes. Rust validates
           returned indices, projects canonical commitments, then rejoins the
           ledger cut. Rust lane/transaction controls use an explicit advisory
           test owner; actual linked Scheme qualification remains pending. */
    }
    part def BoundedTurnCodec {
        attribute ownsTransport : Boolean = false;
        attribute ownsSendAuthority : Boolean = false;
        attribute countsControlBytes : Boolean = true;
        attribute releasesToolsOnlyAtTerminal : Boolean = true;
        doc /* Initial implementation: weaver_llm::TurnDecoder. Feed bounded
           authorized wire bytes and drain events without owning I/O. Errors and
           premature EOF discard partial state; terminal release happens once.
           This does not establish the planned governed rich-event transport. */
    }
    part def SessionTurnLedger {
        port observed : CompactTurnFactsPort;
        port proposed : ~SessionRouteSelectionPort;
        attribute sharesExistingDatabase : Boolean = true;
        attribute ownsProviderSend : Boolean = false;
        attribute ownsReservation : Boolean = false;
        attribute bindsParentFactsAtFinalUse : Boolean = true;
        doc /* Native provider_session.rs observes an opaque source/fact cut,
           then atomically retains a finite retry decision, exact original,
           shared domains and parent fact linkage after external derivation.
           Original domain commitment includes compact parent provenance;
           missing metadata cannot silently become an independent request.
           Recovery stores bounded chosen semantics without another prompt
           copy; replay supplies bytes checked against the original command.
           An exact retained decision skips the advisory lane, but the final
           transaction rereads the decision and rechecks the current cut.
           Parsing/commitment/encoding precede the deciding transaction; guards
           read compact parent provenance. Existing broker/ledger claims reserve
           exposure. source_owner/session.rs connects the two existing lanes;
           actual linked Scheme and full public HTTP qualification remain pending. */
    }
    part def WeaverBackend {
        port request : ~GatewayCallPort;
        port response : GatewayResultPort;
        port plan : ~PlanPort;
        port catalog : CatalogPort;
        part finalGuard : WeaverExecution::RustFinalBroker;
        part execution : WeaverExecution::RuntimePerformanceAllocation;
        part codecContract : BoundedTurnCodec;
        part sessionAdmission : SessionTurnLedger;
        doc /* Reuse existing Rust admission and final-effect owners through the
           selected backend interface. A concrete Magpie request/result join is
           still required. HTTP needs public-protocol ingress and response
           encoding, including scoped GET /v1/models. Existing RPC is reusable
           internally, not evidence of a Magpie-facing API. Reuse
           codecs and Tokio I/O. Bound queues and cancellation end to end;
           a slow CLI cannot leave detached unbounded provider work. */
    }
    part def LocalAgentConnectivity {
        attribute deliveryStatus : DeliveryStatus = DeliveryStatus::planned;
        requirement hostContract : LocalAgentHostReadiness;
        requirement configContract : ReversibleAgentConfiguration;
        requirement routingContract : SingleAgentRoutingAuthority;
        requirement credentialContract : AgentCredentialCustody;
        requirement deploymentContract : AgentDeploymentSeparation;
        requirement acceptanceContract : AgentConnectivityQualification;
        requirement discoveryContract : SourceScopedDiscovery;
        requirement positionContract : PositionedStreamObservation;
        part ui : UserOperationSurface;
        part host : MagpieLocalHost;
        part config : AgentConfigAdapter;
        part cli : CodingCli;
        part ingress : WeaverIngressAdapter;
        part semantics : WeaverSemanticControl;
        part backend : WeaverBackend;
        connection deriveTurn connect backend.sessionAdmission.observed to semantics.turnSelector.facts;
        connection proposeTurn connect semantics.turnSelector.selected to backend.sessionAdmission.proposed;
        connection choose connect ui.selected to host.selected;
        connection edit connect host.edit to config.intent;
        connection confirmEdit connect config.receipt to host.edited;
        connection configure connect config.configured to cli.configured;
        connection showStatus connect host.status to ui.status;
        connection adaptCatalog connect backend.catalog to ingress.backendCatalog;
        connection readCatalog connect ingress.catalog to host.backendCatalog;
        connection showCatalog connect host.visibleCatalog to ui.catalog;
        connection cliRequest connect cli.call to host.agentCall;
        connection proxyRequest connect host.backendCall to ingress.request;
        connection adaptRequest connect ingress.forwarded to backend.request;
        connection backendReply connect backend.response to ingress.returned;
        connection adaptReply connect ingress.result to host.backendResult;
        connection cliReply connect host.agentResult to cli.result;
        connection adaptControl connect host.controlSelection to ingress.selected;
        connection compose connect ingress.proposal to semantics.proposed;
        connection activate connect semantics.published to backend.plan;
    }

    item def ConnectRequested;
    item def PreparationAccepted;
    item def PreparationRefused;
    item def ConfigWriteAcknowledged;
    item def WriteOutcomeUnknown;
    item def ProbeAccepted;
    item def ProbeRefused;
    item def DisconnectRequested;
    item def OwnedFieldsChanged;
    item def ExplicitReconcileRequested;
    item def HostUnavailable;
    item def RestorationVerified;
    item def RestorationConflict;
    item def AppliedConnectionRecovered;
    item def RestoredConfigurationRecovered;
    item def PendingRestorationRecovered;
    state def AgentConnectionLifecycle {
        doc /* Abstract events denote checked owner outcomes, not untrusted UI
           claims. Connect performs prepare, owned write and readiness verification.
           State belongs to one selected profile/generation; a refused rebind does
           not claim the CLI's prior configuration or another profile was removed.
           Recovery inspects the original config intent. It never authorizes
           network effects, silently changes providers or overwrites user edits. */
        entry; then disconnected;
        state disconnected;
        state preparing;
        state applying;
        state verifying;
        state connected;
        state drifted;
        state unavailable;
        state restoring;
        state recoveryRequired;
        transition first disconnected accept ConnectRequested then preparing;
        transition first preparing accept PreparationAccepted then applying;
        transition first preparing accept PreparationRefused then disconnected;
        transition first applying accept ConfigWriteAcknowledged then verifying;
        transition first applying accept WriteOutcomeUnknown then recoveryRequired;
        transition first verifying accept ProbeAccepted then connected;
        transition first verifying accept ProbeRefused then restoring;
        transition first connected accept DisconnectRequested then restoring;
        transition first connected accept OwnedFieldsChanged then drifted;
        transition first connected accept HostUnavailable then unavailable;
        transition first unavailable accept ProbeAccepted then connected;
        transition first unavailable accept DisconnectRequested then restoring;
        transition first drifted accept ExplicitReconcileRequested then preparing;
        transition first drifted accept DisconnectRequested then restoring;
        transition first restoring accept RestorationVerified then disconnected;
        transition first restoring accept RestorationConflict then recoveryRequired;
        transition first restoring accept WriteOutcomeUnknown then recoveryRequired;
        transition first recoveryRequired accept AppliedConnectionRecovered then verifying;
        transition first recoveryRequired accept RestoredConfigurationRecovered then disconnected;
        transition first recoveryRequired accept PendingRestorationRecovered then restoring;
    }
    action def AdmitHarnessTurn {
        in item submitted : TurnSubmission;
        out item admitted : GatewayCall;
        doc /* Join to existing source owner, original-task ledger and
           final broker. Preserve session budget, history and idempotency across
           turns; stale facts or profile generations refuse admission.
           provider_session.rs implements the native ledger transaction;
           the Scheme owner/ingress joins remain pending. Pure contract
           validation is separate: recheck exact scope/source epoch/publication, fact
           floor/revision/snapshot and pending-intent prefix, then retain one
           retry decision, bounded turn count, original and parent fact link.
           Derivation runs outside SQL; quota and send remain existing owners. */
    }
    action def PrepareAgentConnection {
        in item selected : ModelSelection;
        out item ownership : ConfigOwnership;
        doc /* Verify readiness and persist ownership intent through the existing
           adapter before any CLI write. Failure leaves the original untouched. */
    }
    action def ApplyOwnedConfiguration {
        in item ownership : ConfigOwnership;
        out item receipt : ConfigReceipt;
        doc /* Compare expected file/fields and atomically apply only the owned
           edit. A lost acknowledgment enters inspection of this same intent. */
    }
    action def RestoreOwnedConfiguration {
        in item ownership : ConfigOwnership;
        out item receipt : ConfigReceipt;
        doc /* Restore matching owned fields; preserve unrelated changes.
           Conflicting owned fields require reconciliation, not blind rollback. */
    }

    part def PlannedAcceptance {
        attribute status : DeliveryStatus = DeliveryStatus::planned;
        attribute scenario : String;
        attribute oracle : String;
        attribute formalModel : String default = "";
        attribute runtimeProperty : String default = "";
        doc /* Future executable scenario contract, not an existing test result. */
    }
    part acceptance {
        part httpOperationChallenge : WeaverProject::DesignProcess::DesignChallenge {
            attribute :>> hypothesis = "A model catalog read and any locally accepted bearer are sufficient to start a standard HTTP stream";
            attribute :>> assumptions = "Loopback capability selects one source Session/principal; source lane and ledger decide current authority; HTTP is not a source or RPC identity";
            attribute :>> disturbance = "Ambiguous credential headers, other-realm tokens, protocol replacement between catalog and admission, withdrawal, duplicate keys and streamed body overflow";
            attribute :>> independentOracle = "Accepted transport path equals the admitted source protocol, one dedicated credential authenticates before source observation, exact body reaches upstream, and native DeliveryCursor precedes every body transfer";
            attribute :>> progressObligation = "Under output demand and current authority the bounded stream completes once; cancellation and shutdown drain the same runtime owners; no synthetic terminal on failed delivery";
            attribute :>> explorationBound = "64 fixed-seed credential property cases, all byte split points for bounded JSON, four native workers; original 120-second library watchdog, no cold dependency installation";
            attribute :>> modelCampaign = "HttpOperation.cachedCatalogStep and credentialUnionStep versus step under safe; source/ledger and PreparedSnapshot models retain their existing scope";
            attribute :>> runtimeProperty = "http_uses_current_source_catalog_exact_turns_and_one_native_delivery_owner; http_request::credential_realms_do_not_union";
            attribute :>> runtimeBudget = "120 seconds total for native library entry; five-second HTTP body/read bounds and existing one-second delivery credit deadline";
            attribute :>> consequence = "Use a distinct HTTP capability, current Session admission and pre-guard projection on the existing output owner; catalog data never grants source or send authority";
            attribute :>> status = WeaverProject::DesignProcess::ChallengeStatus::refutedHypothesis;
        }
        part preparedSnapshotChallenge : WeaverProject::DesignProcess::DesignChallenge {
            attribute :>> hypothesis = "Preparing only the first frame before the deciding guard suffices for a stateful streaming projection";
            attribute :>> assumptions = "Existing ledger decides current authority; output preparation performs no I/O; bounded snapshots have at most four ranges and 32 rows";
            attribute :>> disturbance = "Encoding failure at each frame, policy replacement or cancellation after preparation, exhausted credit and repeated requests";
            attribute :>> independentOracle = "Every actual handoff has an earlier prepared frame, a completely prepared snapshot at guard time and fresh existing receipt; per-frame timestamps alone miss a failed-snapshot prefix; original holds are retained";
            attribute :>> progressObligation = "A completely prepared snapshot advances under output demand and current authority; error drops the response projection; earlier committed snapshots remain historical";
            attribute :>> explorationBound = "Four abstract frames, 256 traces, 30 steps, seed 293 and four simulator threads; native ledger semantics are not reimplemented";
            attribute :>> modelCampaign = "PreparedSnapshot.latePreparationStep and lateMixedFailuresStep versus step under safe; compare the insufficient frameOnlySafe oracle";
            attribute :>> runtimeProperty = "prepared_snapshot::tests::four_fixed_preparation_failures_publish_no_part_of_that_snapshot; a_real_policy_writer_after_encoding_prevents_every_handoff; actual_sse_projection_preserves_guarded_terminal_and_hold; prepared_sse_snapshot_still_obeys_cancel_and_credit";
            attribute :>> runtimeBudget = "Four fixed failure positions and finite positive controls; four Rust workers; existing 120-second command watchdog; no cold dependency installation";
            attribute :>> consequence = "Mutably owned projection, all bounded snapshot frames prepared before final guard, existing delivery/queue owner only";
            attribute :>> status = WeaverProject::DesignProcess::ChallengeStatus::refutedHypothesis;
        }
        part orderedProjectionChallenge : WeaverProject::DesignProcess::DesignChallenge {
            attribute :>> hypothesis = "Every accepted text delta can be immediately forwarded despite withheld earlier tool headers; replaying the whole final result is harmless";
            attribute :>> assumptions = "Strict source codec authenticates final content and positions; bounded canonical output is retained by the existing terminal owner; encoding has no send authority";
            attribute :>> disturbance = "Text-tool-text and tool-text order; fragmentation; terminal duplication, truncation and cancellation; output byte exhaustion";
            attribute :>> independentOracle = "Output positions form the original prefix without duplicates; tool data appears only at whole-turn completion; final tail preserves canonical content";
            attribute :>> progressObligation = "With a complete validated final result and output demand, the paused tail is emitted once; cancellation/error closes the projection; runtime send fairness remains separate";
            attribute :>> explorationBound = "Three abstract positions; 256 traces, 30 steps, seed 293; four simulator threads; no cryptographic or scheduling proof";
            attribute :>> modelCampaign = "StreamProjection.immediateStep and replayStep versus step";
            attribute :>> runtimeProperty = "stream_encoding::tests::ordered_projection_preserves_content_without_replaying_prefix; withheld_first_tool_produces_no_later_header_before_terminal; aggregate_budget_exhaustion_after_prefix_returns_no_partial_terminal_and_cannot_retry";
            attribute :>> runtimeBudget = "64 generated cases, seed 293; four Rust workers; fixed 120-second command watchdog; reuse installed dependencies";
            attribute :>> consequence = "Stream known prefix; pause at unknown headers; project the canonical terminal tail from the first withheld position with no second tail buffer";
            attribute :>> status = WeaverProject::DesignProcess::ChallengeStatus::refutedHypothesis;
        }
        part catalogVersionChallenge : WeaverProject::DesignProcess::DesignChallenge {
            attribute :>> hypothesis = "Scope/model identity alone is sufficient for a reusable catalog observation version";
            attribute :>> assumptions = "Scope is immutable; hard facts and their ordered prefix can change while the model list stays identical; catalog data is not permission";
            attribute :>> disturbance = "Withdraw and restore availability, queue observations across publication/source changes, restart and cross-principal access";
            attribute :>> independentOracle = "Equal observation versions must identify equal relevant cuts; discovery creates no task/hold/send and cannot substitute for final admission";
            attribute :>> progressObligation = "With stable current facts and a scheduled source owner, a read returns or a bounded error; scheduling/DB latency are runtime obligations, not proved by safe";
            attribute :>> explorationBound = "256 traces, 30 steps, seed 293; 4 simulator threads; no universal or liveness claim";
            attribute :>> modelCampaign = "SessionDiscovery.coarseVersionStep and catalogPermitStep versus step";
            attribute :>> runtimeProperty = "provider_session::tests::discovery_matches_current_facts_without_execution_effects; real ABA version regression";
            attribute :>> runtimeBudget = "64 generated histories, fixed seed 293, existing 120-second suite watchdog, four Rust test workers; reuse dependencies";
            attribute :>> consequence = "A coarse version must be replaced with a commitment to authority, publication and fact prefix; final use keeps its independent guards";
            attribute :>> status = WeaverProject::DesignProcess::ChallengeStatus::refutedHypothesis;
        }
        part contentAssignmentChallenge : WeaverProject::DesignProcess::DesignChallenge {
            attribute :>> hypothesis = "Aggregate text equality and unique block indices suffice to preserve a streamed response";
            attribute :>> assumptions = "Provider item/content indices identify final array positions; a stream can be fragmented and malformed; metadata is not executable tool output";
            attribute :>> disturbance = "Reassign equal concatenated text, permute or skip block indices, substitute ids and stop mid-turn";
            attribute :>> independentOracle = "Per-part content and identity match the final projection; accepted block positions preserve the ordered final content prefix; malformed sequences cannot complete tools";
            attribute :>> progressObligation = "A finite valid stream completes under consumer demand; error/truncation terminates without a tool. Backpressure fairness/cancellation remain separate runtime obligations";
            attribute :>> explorationBound = "256 traces, 30 steps, seed 293; 4 simulator threads; two abstract parts/blocks; cryptographic and OS behavior excluded";
            attribute :>> modelCampaign = "StreamCoordinates.aggregateOnlyStep; MessageBlockOrder.uniqueIndexStep; compare with step";
            attribute :>> runtimeProperty = "stream_observation::tests::part_assignment_cannot_change_under_fragmentation; message_array_order_survives_fragmentation; anthropic_unique_indices_do_not_allow_reordered_blocks fails before the shared-decoder correction";
            attribute :>> runtimeBudget = "64 cases per property, seed 293; four Rust test workers, existing 120-second command watchdog";
            attribute :>> consequence = "Use per-part binding and prove order explicitly; a unique-index map alone may accept a sequence that changes final content order";
            attribute :>> status = WeaverProject::DesignProcess::ChallengeStatus::refutedHypothesis;
        }
        part configRecoveryChallenge : WeaverProject::DesignProcess::DesignChallenge {
            attribute :>> hypothesis = "A durable intent plus unchanged visible getters is enough to clear or restore an interrupted config edit";
            attribute :>> assumptions = "Setters may change primary config and auxiliary stash/catalog files; each atomic rename is separate; external edits and restart are allowed";
            attribute :>> disturbance = "Crash after an auxiliary write but before the visible field changes; external edit including equal-byte replacement; crash during restoration";
            attribute :>> independentOracle = "No unowned surviving effect, no overwrite of external file identity, and recovery reaches an explicit restored/conflict outcome when its declared environment is stable";
            attribute :>> progressObligation = "Recovery must reach restored or explicit conflict with stable files and fair scheduling. recoverable only checks required information; no liveness proof or implemented restore is claimed";
            attribute :>> explorationBound = "Two files; original/owned/external/restored identities; 256 traces, 30 steps, seed 293, four threads; compare/replace remains an unqualified runtime assumption";
            attribute :>> modelCampaign = "ConfigRecoveryDesign.fieldOnlyStep and blindRestoreStep versus step; AgentConfigIntent retains only the unknown-completion checkpoint";
            attribute :>> runtimeProperty = "Magpie original owner: equal getters with an auxiliary side effect must retain the same pending intent";
            attribute :>> runtimeBudget = "64 generated edits, four Go workers, 90-second test timeout inside a 120-second outer watchdog; no GUI or network";
            attribute :>> consequence = "Current digest-only checkpoint lacks a complete prepared write set and file identities; successful unknown-state retention is not recovery qualification";
            attribute :>> status = WeaverProject::DesignProcess::ChallengeStatus::openGap;
        }
        part scopedModelDiscovery : PlannedAcceptance {
            attribute :>> scenario = "Principal isolation; pending and withdrawn facts; source/publication rotation; restart and A-B-A; no task or reservation effects";
            attribute :>> oracle = "Fresh reads on the existing owner reject unavailable/foreign scopes; equal model names after ABA have a different observation version; discovery alone cannot authorize use";
            attribute :>> formalModel = "dev/proofs/quint/SessionDiscovery.qnt";
            attribute :>> runtimeProperty = "crates/ledger/tests/unit/provider_session.rs::discovery_matches_current_facts_without_execution_effects";
        }
        part responseCoordinateBinding : PlannedAcceptance {
            attribute :>> scenario = "64 fragmentations and 64 generated per-part reassignments; foreign item/response ids, duplicate indices and terminal substitutions";
            attribute :>> oracle = "Strict observations preserve exact indices and terminal tool calls; identical aggregate text cannot hide per-part reassignment; any error closes the decoder";
            attribute :>> formalModel = "dev/proofs/quint/StreamCoordinates.qnt";
            attribute :>> runtimeProperty = "crates/llm/tests/unit/stream_observation.rs::part_assignment_cannot_change_under_fragmentation";
        }
        part messageBlockCompletion : PlannedAcceptance {
            attribute :>> scenario = "Thinking/signature fragments, wrong block index and complete block closure before text/tool continuation";
            attribute :>> oracle = "Only the matching block stop exposes its complete signature; block metadata cannot authorize tool execution or whole-turn completion";
            attribute :>> formalModel = "dev/proofs/quint/MessageBlockOrder.qnt";
            attribute :>> runtimeProperty = "crates/llm/tests/unit/stream_observation.rs::anthropic_positions_and_complete_signature_preserve_block_order";
        }
        part governedCoordinateHandoff : PlannedAcceptance {
            attribute :>> scenario = "Generated equal-text part reassignment and arbitrary AsyncRead fragmentation through the real broker codec; closed metadata mutations and native Protobuf/Arrow round trips; cancellation after the first control frame";
            attribute :>> oracle = "Coordinate changes alter the committed payload; malformed assignment cannot finish; control frames cannot expose tool arguments, consume terminal usage or bypass output credit/cancellation";
            attribute :>> formalModel = "ProviderTurnRelease.payloadUnboundStep versus step; StreamCoordinates.aggregateOnlyStep versus step";
            attribute :>> runtimeProperty = "provider_turn::tests::coordinate_changes_bind_the_release_even_when_text_is_identical; turn_sse::tests::broker_preserves_part_assignment_and_rejects_same_text_rebinding; turn_encoding::tests::positioned_controls_and_text_round_trip_without_becoming_terminal";
        }
        part publicIntegration : PlannedAcceptance {
            attribute :>> scenario = "Stock Magpie standard provider calls the compatibility ingress";
            attribute :>> oracle = "Public supported API only; one fixed Weaver provider; no internal-package imports or vendor fallback";
        }
        part conversationalAdmission : PlannedAcceptance {
            attribute :>> scenario = "Two changing turns, replayed turn, exhausted shared budget and withdrawn session facts";
            attribute :>> oracle = "Exact wire binding per turn; no fresh budget per request; duplicate cannot duplicate execution; withdrawal refuses admission";
        }
        part sessionScopeContract : PlannedAcceptance {
            attribute :>> scenario = "64 generated retry-byte/scope mutations; principal, route, budget, profile and domain substitutions";
            attribute :>> oracle = "Exact wire changes command digest but not retry family; changed source scope changes family; derived task preserves all source bounds and shared domains; pure checks grant no admission";
        }
        part sessionLedgerTransaction : PlannedAcceptance {
            attribute :>> scenario = "Ten native ledger cases: four-way turn/budget races, restart, A-B-A, withdrawal, source rotation, missing/redirected parent metadata, orphan fact intent, real rollback/lost acknowledgment and recovery without duplicate prompt storage";
            attribute :>> oracle = "One atomic retry/original/domain/parent decision; no new hold during derivation; existing final-use owners retain shared budget and refuse stale or incomplete provenance; explicit derivation fixture does not qualify the Scheme join";
        }
        part sessionOwnerJoin : PlannedAcceptance {
            attribute :>> scenario = "Four advisory requests never compile source; Source lane admits two changing requests and exact replay; withdrawal completes while advisory work is blocked";
            attribute :>> oracle = "No SQL custody across Scheme work; final transaction rejects stale cut; shared holds remain; session hints cannot supply principal or source credentials; actual Scheme qualification is a separate gate";
        }
        part retainedTurnRecovery : PlannedAcceptance {
            attribute :>> scenario = "Exact retry and restart recover retained routing; changed bytes and source withdrawal refuse recovery";
            attribute :>> oracle = "No repeated advisory call for an exact retained decision; final transaction rereads stored decision and current source/fact cut; no duplicate original or hold; advisory-owner fixtures do not qualify the linked Scheme ABI";
        }
        part richProtocolRoundTrip : PlannedAcceptance {
            attribute :>> scenario = "Two-turn tool call/result through Responses and Messages with fragmented stream and cancellation";
            attribute :>> oracle = "Lossless tool identities and terminal release; legacy text profiles reject unsupported rich input; catalog advertises only qualified capabilities";
        }
        part boundedCodec : PlannedAcceptance {
            attribute :>> scenario = "128 generated fragmentations; all incomplete tool-turn prefixes; control-byte budget and malformed frame";
            attribute :>> oracle = "Same complete tool identity and arguments; no partial tool release; closure after error; no transport or send authority";
        }
        part richEventEncoding : PlannedAcceptance {
            attribute :>> scenario = "128 opaque-continuation values; duplicate keys, wrong version, duplicate tools, incomplete finish and encoding mismatch";
            attribute :>> oracle = "Versioned payload and commitment preserve continuation; protobuf and rich Arrow preserve the explicit payload; old text schema stays unchanged";
        }
        part governedRichTurns : PlannedAcceptance {
            attribute :>> scenario = "Two source-bound tool/result turns on one Task and budget; replay, wrong model, malformed terminal and rich Arrow";
            attribute :>> oracle = "Broker uses shared codec after guarded send; terminal tools release once; replay makes no provider call; held exposure is not refunded; dynamic Session admission remains separate";
        }
        part usageConservation : PlannedAcceptance {
            attribute :>> scenario = "128 generated inclusive input partitions; repeated cumulative updates; invalid totals, overflow, incomplete terminal and native TLS ledger capture";
            attribute :>> oracle = "Disjoint categories conserve usage; terminal payload and ledger agree; unknown usage stays unknown; original holds are not refunded";
        }
        part configCrashDurability : PlannedAcceptance {
            attribute :>> scenario = "Crash between CLI replacement and ownership persistence; injected ownership write failure";
            attribute :>> oracle = "Original config owner retains durable intent and reports persistence failure; restart inspects same intent; no second Weaver journal";
        }
        part pendingConfigEdit : PlannedAcceptance {
            attribute :>> scenario = "Persist before Codex/Claude setters; block four contenders and 64 substitutions; actual process exits before and after Codex setter; refuse unknown ownership and changed final ownership";
            attribute :>> oracle = "Existing applied.json retains one versioned intent; no setter before persistence; restart observes same unknown operation without replay or false applied/restored acknowledgment; whole-write-set CAS recovery remains a separate obligation";
        }
        part ownershipWriteFailure : PlannedAcceptance {
            attribute :>> scenario = "Codex and Claude config setters succeed while the original applied.json destination refuses ownership persistence";
            attribute :>> oracle = "Apply returns failure; edited config and unrelated values remain observable; no false restored/applied receipt; an atomic ownership file alone does not qualify the separate durable-intent crash cuts";
        }
        part connectDisconnect : PlannedAcceptance {
            attribute :>> scenario = "Codex and Claude Code; isolated homes; select, connect, call, disconnect";
            attribute :>> oracle = "Backend readiness precedes edit; one original config owner; restored owned fields; unrelated values retained";
        }
        part driftAndConflict : PlannedAcceptance {
            attribute :>> scenario = "External edit and concurrent profile change between prepare and apply/restore";
            attribute :>> oracle = "CAS refuses stale edit; UI reports drift; explicit reconciliation preserves user changes";
        }
        part restartRecovery : PlannedAcceptance {
            attribute :>> scenario = "Restart before write, after atomic replacement and before acknowledgment";
            attribute :>> oracle = "Inspect the same intent; no duplicate write or lost before-image; original generation retained";
        }
        part hostLoss : PlannedAcceptance {
            attribute :>> scenario = "Host/backend unavailable before connect and during a live connection";
            attribute :>> oracle = "No initial config edit on failed readiness; visible unavailable state; no provider bypass; explicit disconnect remains possible";
        }
        part protocolCompatibility : PlannedAcceptance {
            attribute :>> scenario = "Four-worker Snake Oil Chat, Responses and Messages; text, tools, cancellation and slow consumer";
            attribute :>> oracle = "Preserve terminal/tool identities; bounded buffering; cancelled work drains; reuse upstream protocol controls";
        }
        part identityAndFallback : PlannedAcceptance {
            attribute :>> scenario = "Two CLI hints sharing a host credential; revoked source; unknown send and attempted direct fallback";
            attribute :>> oracle = "No invented user identity; source/final-use guards remain decisive; unknown budget retained; fixed Weaver profile cannot bypass";
        }
        part distribution : PlannedAcceptance {
            attribute :>> scenario = "Phase-one Magpie host and later unified install, restart, update and uninstall";
            attribute :>> oracle = "UI and local host are present and version-compatible; disconnect restores CLI config before host removal";
        }
    }
    part def DeliveryStage {
        attribute status : DeliveryStatus = DeliveryStatus::planned;
        attribute prerequisite : String;
        attribute exitCriterion : String;
    }
    part delivery {
        part magpieCompatibility : DeliveryStage {
            attribute :>> prerequisite = "Stock Magpie HTTP join; bounded session-turn admission; versioned rich protocol contracts; refined config-owner durability; authenticated model binding";
            attribute :>> exitCriterion = "Codex and Claude Code connect/use/disconnect through one Weaver provider; acceptance cases qualified; no claim of unified packaging";
        }
        part unifiedDistribution : DeliveryStage {
            attribute :>> prerequisite = "Qualified compatibility stage; explicit UI/host ownership and packaging/update design; preserve upstream license notices";
            attribute :>> exitCriterion = "One supported installation delivers UI, host and adapters; recovery, update and uninstall qualified; embedded SDK graph remains independent";
        }
    }
}
