package PolicyEvidenceDesign {
    private import ScalarValues::*;
    doc /* Target data contracts only, not implemented messages. Component owners
       remain in WeaverExecution; verification roles remain in the root Project.
       This package defines no parallel control state machine or authorization
       engine. Existing publication/execution requirements continue to apply. */

    enum def AnalysisEvidenceKind {
        enum solverAnalysis;
        enum kernelImplication;
    }
    enum def DeltaPredicate {
        enum authorizationAllow;
        enum errorFreeExecution;
    }
    enum def EvidenceDisposition {
        enum accepted;
        enum rejected;
        enum unsupported;
        enum unknown;
    }
    enum def Completeness {
        enum completeWithinScope;
        enum incomplete;
        enum unknown;
    }
    enum def PublicationOutcome {
        enum committed;
        enum rejected;
    }
    enum def SourceDecisionKind {
        enum policyPublication;
        enum hardFactBarrier;
        enum factProjection;
    }
    enum def AccountingEvidenceKind {
        enum noExecution;
        enum finalUsage;
    }
    enum def PublicationIntent {
        enum bootstrap;
        enum revise;
    }
    enum def ObservationKnowledge {
        enum known;
        enum unknown;
        enum notFound;
    }
    enum def CoverageKind {
        enum finiteCases;
        enum schemaEnvironments;
    }
    enum def EffectOutcome {
        enum noExecutionProven;
        enum partial;
        enum unknown;
        enum complete;
    }
    enum def EffectObservationDomain {
        enum invocation;
        enum responseRelease;
        enum accounting;
    }
    enum def DerivationBackend {
        enum inheritedAscent;
        enum optionalMRR;
    }
    enum def FreshnessMode {
        enum orderedSourceSession;
        enum boundedSourcePromise;
    }
    enum def ConfigurationEntry {
        enum jsonData;
        enum schemeProgram;
    }
    item def ConfigurationCommitment {
        attribute entryKind : ConfigurationEntry;
        attribute configurationSchemaDigest : String;
        attribute supportedDialect : String;
        attribute normalizerClosure : String;
        attribute inputDigest : String;
        attribute semanticOutputDigest : String;
        attribute profileContractIdentity : String;
        attribute schemeModuleClosure : String;
        attribute capturedEnvironment : String;
        attribute governanceAssessmentReceipt : String;
        doc /* JSON data and higher-order Scheme converge to one admitted typed
           semantic output; preserve entry provenance separately. Reuse inherited
           Yuanxu JsonSchema scope, then AA Profile/Governance contracts. Require
           an explicit supported configuration schema; the upstream unconstrained
           object default cannot choose Gateway admission. This schema is distinct
           from the Cedar request schema. JSON cannot skip Governance, Scheme
           output cannot skip data validation, and neither entry grants effects.
           YAML is an existing data normalization path, not another evaluator. */
    }
    item def SchemeCaptureAdmission {
        item configuration : ConfigurationCommitment;
        attribute sourceCut : String;
        attribute sourceImageDigest : String;
        attribute vmIncarnation : String;
        attribute callbackIdentity : String;
        attribute captureEpoch : Integer;
        attribute admittedDependencyClosure : String;
        attribute producerAuthorityReceipt : String;
        doc /* Functions stay in the admitted Scheme VM. Capture immutable typed
           parameters and declared sources, not arbitrary procedures, IO handles
           or live Scheme objects. Revalidate canonical source input before
           materialization. Closure/environment/schema/callback identity is
           checked at publication, not only when evaluating a local method.
           Bind callback/capture/body to trusted host or authenticated-channel
           provenance; old workers cannot acquire current custody by copying
           fresh payload labels. Possession and source-role checks remain required. */
    }
    item def FFIHandoffEvidence {
        item capture : SchemeCaptureAdmission;
        attribute callIdentity : String;
        attribute inputDigest : String;
        attribute outputDigest : String;
        attribute ownershipReceipt : String;
        attribute byteLength : Integer;
        attribute codecClosure : String;
        doc /* Current C ABI is synchronous inert Policy/schema preflight only;
           this target evidence does not invent a production callback ABI.
           Borrowed regions must already be valid, alive and immutable until
           return, with runtime rooting/GC and thread-affinity qualified. Copy
           and decode to Rust-owned immutable values before queueing; no borrowed
           pointer, Scheme object or VM callback crosses a ledger lock/await.
           Rust cannot validate arbitrary addresses before dereferencing them;
           never test invalid caller memory as a recoverable parsing error.
           Separate live callback acceptance from reuse of an already admitted
           owned artifact: producer VM/call expiry fences new callback claims,
           while stored canonical data can survive under current source custody,
           original operation and full current semantic/freshness joins.
           Ownership evidence is not durability evidence. Rust/process recovery
           requires actual recoverable bytes and receipt; otherwise recapture
           the committed source cut or refuse under the original identity.
           Preflight success is not publication, completion or a send permit. */
    }
    item def FactProjectionClosure {
        attribute backendIdentity : String;
        attribute engineClosure : String;
        attribute ruleClosure : String;
        attribute queryIdentity : String;
        attribute schemaDigest : String;
        attribute sourceCut : String;
        attribute sourceAuthority : String;
        attribute scopeIdentity : String;
        attribute limitProfile : String;
        attribute adapterClosure : String;
        attribute callbackEnvironment : String;
        attribute freshnessContract : String;
        doc /* Exact executable and semantic closure, not equal result rows.
           Higher-order Scheme callbacks include admitted captured environments
           and dependencies. Opaque/mutable callbacks cannot claim stable reuse;
           use full derivation and freeze its admitted output. This is not a
           serialization of arbitrary procedure environments. Undeclared IO,
           randomness or mutable dependencies cannot become a hard fact merely
           by hashing code; qualify their admitted source/evaluation contract.
           Content digests
           rely on canonical encoding and collision resistance, not labels. */
    }
    item def FrozenFactImage {
        attribute canonicalPayloadDigest : String;
        attribute sourceCut : String;
        attribute ownershipProfile : String;
        attribute captureReceipt : String;
        doc /* Own immutable canonical values throughout hashing, publication,
           restart materialization and final interpretation. Copying row spines
           is insufficient for nested host objects. Unsupported mutable values
           reject; a deep-copy operation must itself have qualified coverage.
           Materialized bytes/rows must match the committed source image before
           hashing. Rehashing a mutated alias cannot reuse an old source-cut
           identity, even with a newly frozen copy or a different publisher. */
    }
    item def FactFreshnessWitness {
        attribute mode : FreshnessMode;
        attribute admittedContract : String;
        attribute sourceAuthority : String;
        attribute sourceCut : String;
        attribute scopeIdentity : String;
        attribute requestIdentity : String;
        attribute sourceSessionEpoch : Integer;
        attribute clockEpoch : Integer;
        attribute executorFence : Integer;
        attribute validBefore : Integer[0..1];
        attribute authorityReceipt : String;
        doc /* Mode comes from original source/profile admission, not a caller
           choice at use. Ordered-session mode requires admitted source ordering and
           current live session, not merely a connected socket. Bounded mode
           needs an authenticated source promise for this exact cut and scope,
           a trusted monotone clock/epoch and strict time-before-expiry at final
           use. A local TTL or reconnect is not renewal. Reject stale requests,
           lost/unverified renewals and old clock/owner epochs after restart.
           Immediate remote revocation during a partition is not claimed. */
    }
    item def FactUseContext {
        item closure : FactProjectionClosure;
        item frozenImage : FrozenFactImage;
        item coverage : Coverage;
        item freshness : FactFreshnessWitness;
        doc /* Join all coordinates against current authority at projection CAS,
           successor admission and final dispatch/release. Complete means the
           admitted closed scope at this source cut, never arbitrary global
           absence. Timeout, partial scope, failed derivation and unknown remain
           unavailable. No fact change is justified by pointwise Policy delta. */
    }
    item def SemanticCommitment {
        attribute taskRoot : String;
        attribute claim : String;
        attribute profile : String;
        attribute budgetDomain : String;
        attribute historyDomain : String;
        attribute routineStep : String;
        attribute routineGraphDigest : String;
    }
    item def ArtifactImage {
        doc /* One supported original-family handoff. Every materialization,
           analysis and replay joins this exact image. Original claim/domains
           and assurance requirements survive new Session/protocol identifiers.
           Content identity is not producer authenticity or a storage receipt. */
        item original : SemanticCommitment;
        item profileAuthority : ProfileAuthorityCommitment;
        attribute policyDigest : String;
        attribute schemaDigest : String;
        attribute moduleClosure : String;
        attribute adapterClosure : String;
        attribute factSnapshot : String;
        attribute factProjectionClosure : String;
        attribute assuranceProfile : String;
    }
    item def ProfileAuthorityCommitment {
        doc /* Target payload binding, not a new registry or credential format.
           Rust reads this from the existing authenticated original-family
           assignment and authority publication, independently of the candidate.
           Original profile content is immutable across new session/operation
           labels; selected content must refine it through the actual LeanPoo
           ObjectProfile Session/Contract and source/factory closure. Display
           names, a child-selected original or a self-presented publication are
           insufficient. Every payload/source change advances the authority
           identity/revision; recovery rejects rollback and mixed snapshots. */
        attribute publicationIdentity : String;
        attribute publicationRevision : Integer;
        attribute originalProfilePayloadDigest : String;
        attribute selectedProfilePayloadDigest : String;
        attribute objectSourceClosure : String;
        attribute factoryClosure : String;
        attribute contractClosure : String;
        attribute originalScopeBindingReceipt : String;
        attribute recoveryAuthorityBinding : String;
        item source : SourceAdmission;
    }
    item def Coverage {
        attribute kind : CoverageKind;
        attribute schemaDigest : String;
        attribute environmentSetDigest : String;
        attribute scopeIdentity : String;
        attribute completeness : Completeness;
    }
    item def AnalysisEvidence {
        doc /* Before/after images and complete schema-environment coverage are
           required by the restrictive change profile. The initial profile keeps
           schema, source fact snapshot and projection contracts fixed. Policy
           implication is pointwise in one semantic environment; it does not
           compare permissions across different fact/entity/history worlds.
           Authenticate the admitted analysis worker and actual
           tool/configuration; labels cannot prove production. Solver evidence
           retains solver trust. A kernel implication needs its exact premises
           and does not by itself prove UNSAT of a generated query. */
        attribute kind : AnalysisEvidenceKind;
        attribute predicateKind : DeltaPredicate;
        attribute disposition : EvidenceDisposition;
        item beforeImage : ArtifactImage;
        item afterImage : ArtifactImage;
        item coverage : Coverage;
        attribute producerIdentity : String;
        attribute producerCredentialBinding : String;
        attribute toolClosure : String;
        attribute solverConfiguration : String;
        attribute proofOrReportIdentity : String;
        doc /* Gateway restrictive publication selects errorFreeExecution.
           Equal Allow/Deny results can hide changed evaluation errors. Upstream
           provenanceChanges and proofFootprint remain separate evidence axes:
           a behavior-equivalent revision can still invalidate source admission.
           Platform-neutral library envelopes must not depend on Weaver's SQL,
           gRPC types, Scheme VM handles or product-specific ArtifactImage. */
        doc /* The upstream Gateway AdmissionBinding connects the actual receipt
           and Delta through exact scope/schema/source/after-root/policy equality
           and current-plan checks. ObjectProfile Contract admission preserves
           original ordered requirements under C4 extension. Host admission must
           authenticate that original profile and object source; neither raw
           records nor satisfied labels prove budget or history truth. */
    }
    item def ReplayEvidence {
        doc /* Recompute official Rust Cedar replay with the same schema and
           compare decisions, reason IDs, errors and all case bindings. Finite
           coverage cannot establish universal no-expansion or whitelist future
           requests. Actual requests still require the current final guard. */
        item image : ArtifactImage;
        attribute manifestDigest : String;
        attribute receiptDigest : String;
        attribute validatorIdentity : String;
        item coveredCases : Coverage;
    }
    item def SourceAdmission {
        doc /* Authenticate the publishing source role and its incarnation,
           module closure and original assurance profile. This is distinct from
           admitting an analysis worker; neither role is a shared account label. */
        attribute moduleClosure : String;
        attribute sourceOwnerIdentity : String;
        attribute sourceCredentialBinding : String;
        attribute sourceIncarnation : String;
        attribute admittedProfile : String;
        attribute factFeedContract : String[0..1];
        attribute freshnessContract : String[0..1];
    }
    item def DerivedFactCandidate {
        doc /* Prefer the inherited Agentic AI Lab/Ascent capability. MRR is an
           optional qualified backend, not a second authorization engine. Bind
           backend/rule/query/input/limit semantics to factProjectionClosure;
           equal rows do not make evidence interchangeable. Incomplete, timed-out
           or out-of-scope nonmembership is unknown, never an allow/no-execution. */
        attribute backend : DerivationBackend;
        attribute engineClosure : String;
        attribute queryIdentity : String;
        attribute generation : Integer;
        attribute sourceSnapshot : String;
        attribute catalogDigest : String;
        attribute ruleClosure : String;
        attribute sourceAuthority : String;
        attribute semanticScope : String;
        attribute lineageRoot : String;
        attribute completeness : Completeness;
    }
    item def HardFactIntent {
        item original : SemanticCommitment;
        item sourceAdmission : SourceAdmission;
        attribute intentIdentity : String;
        attribute factDomain : String;
        attribute sourceRevision : String;
        attribute predecessorSourceRevision : String;
        attribute previousSnapshot : String;
        attribute proposedSourceCut : String;
        attribute expectedProjectionFloor : Integer;
        doc /* Authenticated hard-fact input, not a rule-derived self-grant.
           Require the admitted fact-feed and freshness contracts; a generic
           publisher credential is insufficient to assert arbitrary hard facts.
           Persist original intent and affected-domain barrier before trusting a
           replacement projection. Source revisions need their own admitted
           ordering; do not sort timestamps or use Ascent/MRR generation as a fence. */
    }
    item def HardFactBarrier {
        item intent : HardFactIntent;
        attribute assignedFloor : Integer;
        attribute pendingPrefix : String;
        attribute authoritativeReceipt : String;
        doc /* Original intent, monotone floor, pending membership and immutable
           decision become durable in one authority transaction before success.
           The receipt confirms blocking, not projection readiness. Local timeout,
           rejected projection or source disconnect cannot cancel this intent. */
    }
    item def FactBarrierResolution {
        attribute originalIntents : String[1..*];
        attribute installedProjection : String;
        attribute previousPendingPrefix : String;
        attribute remainingPendingPrefix : String;
        attribute floor : Integer;
        attribute decisionReceipt : String;
        doc /* Resolution evidence in the existing source transaction, not a new
           coordinator. Bind every resolved intent to the installed source cut.
           Coalescing requires an admitted source-order proof accounting for each
           original intent. Rejection/timeout has no resolution. Remaining pending
           work still blocks fresh effects; floor never decreases on resolution. */
    }
    item def FactProjectionCandidate {
        item barrier : HardFactBarrier;
        item derivation : DerivedFactCandidate;
        item image : ArtifactImage;
        item facts : FactUseContext;
        item handoff : FFIHandoffEvidence;
        attribute originalIntent : String;
        attribute operationIdentity : String;
        attribute expectedParent : Integer;
        attribute expectedProjectionFloor : Integer;
        attribute expectedPendingPrefix : String;
        attribute sourceIncarnation : String;
        doc /* Compare the current barrier/pending prefix, actual predecessor,
           source custody and full image inside the same Rust source authority.
           Match facts.closure.sourceCut to this immutable intent's proposed
           source cut; a valid unrelated image cannot resolve another intent.
           Resolve only this original intent atomically with projection/outcome;
           another pending intent keeps the domain blocked. Fact replacement is
           not covered by a fixed-fact Policy delta. Lost replies recover the
           original outcome. Continuations reuse the existing canonical-family
           contract and cannot erase pending intent or reset original domains. */
    }
    item def PublicationCommand {
        doc /* At the existing publication CAS, compare operation/digest and the
           actual predecessor against deltaEvidence.beforeImage; join candidate,
           deltaEvidence.afterImage and replay.image; recheck source custody and fact
           floor. Preflight reserves no parent. Bootstrap requires explicit
           initial authority; failed observation cannot select bootstrap. Commit
           binds recoverable artifacts and immutable outcome atomically, with no
           provider call or budget release. Unknown retries keep this identity. */
        attribute intent : PublicationIntent;
        item candidate : ArtifactImage;
        item sourceAdmission : SourceAdmission;
        item deltaEvidence : AnalysisEvidence[0..1];
        item replay : ReplayEvidence;
        item configuration : ConfigurationCommitment;
        attribute operationIdentity : String;
        attribute expectedParent : Integer[0..1];
        attribute expectedFence : Integer;
        attribute factFloor : Integer;
        attribute sourceIncarnation : String;
        doc /* A restrictive revise intent requires deltaEvidence for the real
           predecessor. Bootstrap instead requires explicit initial-image
           admission and replay, and asserts no no-expansion theorem against an
           absent predecessor. Omitting delta on revise is a downgrade. */
    }
    item def PublishedObservation {
        attribute decisionKind : SourceDecisionKind;
        attribute operationIdentity : String;
        attribute commandDigest : String;
        attribute knowledge : ObservationKnowledge;
        attribute outcome : PublicationOutcome[0..1];
        attribute revision : Integer[0..1];
        attribute fence : Integer[0..1];
        item factBarrier : HardFactBarrier[0..1];
        item barrierResolution : FactBarrierResolution[0..1];
        doc /* Only a known decision has an outcome. Unknown/notFound cannot
           synthesize rejection; committed is historical until joined with
           current authority. Unknown/notFound have
           no outcome/head; known rejection may report no existing head. Present
           revision/fence are paired for Policy/projection decisions. A committed
           hardFactBarrier instead requires its durable barrier receipt; it does
           not assert a new active image. A committed factProjection binds its
           resolution, but cannot clear other pending work. Publication never
           establishes effect completion or accounting application. */
    }
    item def ActualEffect {
        item original : SemanticCommitment;
        attribute principal : String;
        attribute actionIdentity : String;
        attribute resource : String;
        attribute logicalMessage : String;
        attribute payloadDigest : String;
        attribute payloadLength : Integer;
        attribute contextDigest : String;
        attribute endpoint : String;
        attribute credentialBinding : String;
        attribute responseMode : String;
        attribute streamIdentity : String;
        attribute rangeOrdinal : Integer;
        attribute chargeCeiling : Integer;
    }
    item def DecidingView {
        attribute revision : Integer;
        attribute fence : Integer;
        attribute sourceIncarnation : String;
        attribute executorIncarnation : String;
        attribute activeImage : String;
        attribute profileAuthorityIdentity : String;
        attribute profileAuthorityRevision : Integer;
        attribute recoveryFloorReceipt : String;
        attribute factSnapshot : String;
        attribute entitySnapshot : String;
        attribute factFloor : Integer;
        attribute claimState : String;
        attribute reservation : String;
        attribute budgetVersion : Integer;
        attribute historyVersion : Integer;
        attribute factDomain : String;
        attribute pendingHardFactIntents : String[0..*];
        attribute routineFrontier : String;
        attribute factValidityIdentity : String;
    }
    item def CommitCut {
        doc /* Full authenticated prefix commitments, not lengths or display
           generations. Each commitment covers ordered IDs, canonical bodies,
           original scope and predecessor. Domain owners validate actual effects. */
        attribute originalAssignment : String;
        attribute publicationPrefix : String;
        attribute consumptionPrefix : String;
        attribute accountApplicationPrefix : String;
        attribute historyPrefix : String;
    }
    item def FloorDecision {
        attribute intentIdentity : String;
        attribute canonicalCommandDigest : String;
        attribute ownerEpoch : Integer;
        item predecessor : CommitCut;
        item resultCut : CommitCut;
        attribute outcomeIdentity : String;
        attribute outcome : PublicationOutcome;
        doc /* Independent authority atomically binds original intent/digest,
           epoch, full predecessor and immutable committed/rejected result.
           Exact retry observes its original result; it never rebases a parent.
           Missing/failed lookup is unknown, not abort. Resolve an absent intent
           by a durable fenced rejection. Rejection resolves that intent only;
           it proves neither no-execution nor final usage and cannot by itself
           release the original claim or unknown budget. */
    }
    item def TransportAdmission {
        item currentCut : CommitCut;
        attribute executionShard : String;
        attribute authenticatedOwnerIncarnation : String;
        attribute ownerEpoch : Integer;
        attribute originalLogicalKey : String;
        attribute durableBurnIdentity : String;
        attribute canonicalDestinationAndBody : String;
        doc /* An internal live continuation at the sole Rust transport owner,
           never a bearer capability returned over gRPC or Arrow. Final guard
           checks current cut/epoch, original scope and actual authenticated
           owner, then invokes the bounded synchronous socket operation while
           holding the same exclusion gate used by every floor mutation. Burn
           commits before possible bytes; replay never recreates this continuation.
           The admission linearization point is the guarded transition into that
           transport call, not prepare, log apply, enqueue, burn or remote read.
           This is permission to attempt IO, not evidence of peer execution. */
    }
    item def TransportQuiescence {
        attribute executionShard : String;
        attribute retiredOwnerIncarnation : String;
        attribute supervisorIdentity : String;
        attribute stopEvidence : String;
        attribute retiredConnections : String;
        doc /* Authenticated evidence from the actual process/egress supervisor
           that the exact old incarnation cannot initiate more provider writes.
           Base topology waits for its real process exit and closes all owned
           connections; no exported FD, credential or delegated sender may survive.
           Already admitted bytes can drain and retain unknown budget. Kubernetes
           object deletion, lease expiry, a PID without incarnation, epoch advance
           or a caller Boolean cannot substitute. If old-host quiescence cannot
           be proved, replacement activation remains blocked. */
    }
    item def FinalEffectJoin {
        item effect : ActualEffect;
        item image : ArtifactImage;
        item observed : DecidingView;
        item current : DecidingView;
        item facts : FactUseContext;
        doc /* Rust derives actual facts, validates against image.schemaDigest
           and image.policyDigest, and compares the deciding coordinates inside
           the existing final consume/dispatch/release boundary. Join current
           profileAuthority payload/source with the original assignment and
           deciding authority identity/revision. Raw preparation and semantic
           receipts cannot enter Gateway consumption without publication binding;
           no entry-origin flag exempts them. Recheck the joined authority under
           final CAS; an earlier bound receipt is not a freshness certificate.
           Deserialized/FFI values must reconstruct the checked binding, never
           trust a serialized proof tag or caller-selected original profile.
           Compare observed/current deciding coordinates inside the serialized
           guard. Historical publication outcomes never restore an active head.
           Recovery requires an independently authenticated monotonic floor;
           local SQLite WAL and a new process session do not establish it.
           The floor covers execution consumption, account applications and
           history prefixes as well as publication. A publication-only floor
           misses rollback of a spend under an unchanged valid publication.
           Prepared local WAL is inert. Anchor decision precedes projection
           visibility; repair every affected prefix before activation. Local
           projection and authority epoch/cut are compared again at final use.
           Final transport authority serializes burn and bounded send with floor
           changes in the independent recovery domain. An online read followed
           by a local send, a bearer token or a cached activation is insufficient.
           An unavailable/mismatched floor blocks new authority, dispatch and
           unknown-budget release. This is a target obligation, not an existing
           anti-rollback implementation. Already admitted sends may finish while
           a later source commit waits for the deciding lock.
           Join current
           claim/reservation, shared domains, history/fact floor and executor
           custody; no mutable external MRR query may fill the gap before send.
           Pending hard-fact intents in a required domain block fresh use, even
           if local subscriber delivery or projection recomputation has failed.
           An admitted buffer may drain after revocation, but no new release is
           granted under the old image. Partial/unknown bytes preserve the hold.
           This data item is a check input, never a reusable authorization permit. */
    }
    item def EffectObservation {
        item original : SemanticCommitment;
        attribute observationIdentity : String;
        attribute logicalEffect : String;
        attribute attemptIdentity : String;
        attribute commandDigest : String;
        attribute executionImage : String;
        attribute authoritativeReceipt : String;
        attribute domain : EffectObservationDomain;
        attribute outcome : EffectOutcome;
        doc /* Session progression needs an authentic, deduplicated observation
           for this original step, required observation domain and current
           dependencies. Invocation completion is not response-release completion
           or accounting application. Read root/domain/completeness from the
           authoritative immutable observation itself, never a proposal's label.
           An observation identity cannot be rebound to a different body. The
           initial invocation-success profile requires complete evidence; unknown
           or partial observations remain history and cannot justify that edge
           or release an unknown hold. Other edge profiles need explicit review. */
    }
    item def AccountingEvidence {
        item effect : EffectObservation;
        attribute kind : AccountingEvidenceKind;
        attribute reservationIdentity : String;
        attribute dispatchReceipt : String;
        attribute accountApplicationIdentity : String;
        attribute accountAuthorityReceipt : String;
        attribute billingScopeIdentity : String;
        attribute chargeMappingIdentity : String;
        attribute finalCharge : Integer;
        doc /* Evidence for the existing accounting owner, not a new settlement
           API. Require accounting domain, original root/claim/budget domain,
           original reservation and unique application identity. Final usage must
           name its complete billing scope and admitted charge mapping. NoExecution
           needs authoritative dispatch/release evidence excluding possible use;
           a source zero-call, denial or missing outcome is insufficient. Unknown
           or partial usage retains the unresolved exposure. Only atomic account
           application, preserved across recovery, can authorize the corresponding
           balance change. Completion or barrier resolution never refunds a hold.
           Require nonnegative finalCharge and accounting-domain evidence; the
           noExecution kind requires noExecutionProven, while finalUsage requires
           complete evidence for its named scope, not merely a complete invocation.
           This target does not claim an external provider billing guarantee. */
    }
    item def SessionProgressionProposal {
        item original : SemanticCommitment;
        item predecessor : EffectObservation;
        attribute successorStep : String;
        attribute transitionSlot : String;
        attribute expectedRoutineFrontier : String;
        attribute expectedFactFloor : Integer;
        doc /* Scheme reuses Session/Workflow/Governor to derive this proposal.
           Rust checks the original graph edge, required receipt domain and
           current facts/frontier at existing successor admission. Deduplicate
           by original root/transition slot, never receipt/session/attempt nonce.
           Receipt recording may be historical; progression needs current
           authorization. Recheck pending hard-fact domains and original receipt
           requirements at admission, then the final guard at execution. A local
           Session checkpoint or publication acknowledgment cannot advance the
           authoritative frontier. Atomically bind the frontier comparison,
           transition winner, successor claim/reservation and immutable outcome
           in existing admission; no local-advance then separate claim gap.
           Use existing claims/outcomes, not a second Session ledger. */
    }
    item def SourceCommand {
        item policyPublication : PublicationCommand[0..1];
        item hardFactIntent : HardFactIntent[0..1];
        item factProjection : FactProjectionCandidate[0..1];
        doc /* Exactly one request variant. All share the existing authenticated
           source lane and deciding authority, not independent coordinators. */
    }
    port def CandidatePort { out item candidate : SourceCommand; }
    port def ObservationPort { out item observation : PublishedObservation; }
    port def DerivedFactsPort { out item candidate : DerivedFactCandidate; }
    port def EffectObservationPort { out item observation : EffectObservation; }
}
