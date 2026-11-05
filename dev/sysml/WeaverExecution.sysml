// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

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
    requirement def TursoMvccCustody {
        doc /* Explicit MVCC retains one MRR Data Database under one process
           lease. Admission, consumption and final callbacks hold shared custody
           and the same authoritative origin/budget/history-root mutexes through native
           commit or abort. Global mutations, owner transfers and schema changes
           require exclusive custody and drain all live family scopes. Acquire
           custody before resolving current roots and starting a snapshot. New
           families may share either root; they acquire the same sorted mutexes.
           Whole-domain unions drain every scope and fence old permits with new
           root epochs. Only disjoint roots may overlap. Native conflicts
           never replay callbacks or refund unknown exposure. Restart recovers
           consumption, not volatile permits. Custody is not anti-rollback. */
    }
    requirement def SharedDomainAuthority {
        doc /* Current authenticated source atomically registers an immutable
           origin, canonical task and budget/history binding. A family alias
           resolves to that original and cannot own another task or consumption.
           Domain unions preserve every member, reservation and history event;
           aggregate holds must fit the minimum original cap. Root epochs advance
           before new use, fencing request, provider and stream owners. A lost
           migration reply recovers its original operation/digest receipt. Native
           final use validates exact manifests and history coverage under the
           resolved root locks. New family, route, nonce and restored worker do
           not authorize independent accounting. Genuine origin identity is a
           source-admission premise; coherent rollback needs an independent floor. */
        doc /* Revocation before or after a committed union still governs actual
           use. A recovered migration receipt or historical Go publication
           cannot restore the old Policy, root epoch or execution owner.
           Refused work does not consume another claim or release unknown budget. */
    }
    requirement def OriginalTaskBinding {
        doc /* Preserve family, declared node, profile, endpoint and exact wire body commitment. */
        doc /* A stable source-owned task key maps to one canonical family and
           origin across source epochs. Original task/domain commitments and
           registration decision commit with the task. Final use rejoins that
           registry; partial recovery cannot backfill it. Fresh commands compare
           the current source epoch, while replay of a committed decision is
           observational only. Authentic assignment of the stable upstream task
           key remains an issuer premise, not content-based deduplication. */
    }
    requirement def SharedBudget {
        doc /* Original node holds fit both their immutable task budget and the
           authoritative shared root cap across all member families. */
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
        doc /* Bind the dispatch permit to the domain stamp used by Cedar in the
           deciding transaction. The queued-to-unknown CAS must affect one row. */
        doc /* Final stream use joins the exact durable range sequence, offset,
           length and unwritten unknown state to the owned permit, message cursor
           and next sequence. An inconsistent receipt denies the writer and
           retains unknown exposure; it cannot prove not-sent or authorize repair.
           This detects partial recovery inconsistency, not coherent database rollback. */
    }
    requirement def CurrentFinalGuard {
        doc /* Serialize the final policy/history revision and fence check with actual send. */
        doc /* Authority publication and domain migration take the exclusive owner
           gate. A live final-send scope excludes these mutations through commit
           or rollback. After commit, acknowledgment can overlap a new CAS.
           Reviewed staging also takes the exclusive gate. Its durable pending
           barrier excludes a fresh final-use guard until a decision clears it.
           A rejected parent or epoch cannot rebase an original command. The
           deployment-qualified review uses the same staging and final-use gate.
           Lost source and transport acknowledgments preserve separate outcomes. */
        doc /* Provider queue encoding precedes the domain lock. Consume retains
           verified profile bytes and their semantic key. Every effect rereads
           the registry identity, digest and bytes and the current task floor
           under the deciding scope, alongside live OAuth, Cedar and fencing. */
    }
    requirement def ProviderCurrentnessPerformance {
        doc /* Time domain view, publication and reviewed head, profile, and
           original claim reconciliation separately in the deciding scope. Split
           publication into pending, review match and original task birth.
           Split claim time into original task, reservation manifest and history.
           Record review and original preflight and Rust session open outside
           the domain lock. Include those intervals in throughput accounting.
           Domain lock wait, native begin and commit, Cedar and provider effects
           have separate observations. Throughput is terminal receipts divided
           by elapsed wave time, with completion and send counts retained. */
        doc /* The provider warms a single Turso SQL program before locking.
           Every deciding scope binds its family and opens a fresh cursor on
           that transaction. Program reuse preserves the full domain join.
           The domain view and reservation reconciliation are scope-local.
           History equality, capacity, revocation, Policy and fence remain live. */
        doc /* Shared roots serialize. Independent roots may overlap under MVCC.
           Qualify both with the same binary, ingress, original workload, provider,
           and held-budget verification. Hold and wait intervals can overlap.
           The sum of protected service demands is a lower bound on a wave
       sharing one root. Cross-root time is bounded by the longest dependency
       chain and can also be constrained by native writer and IO capacity.
       Report wall time and sampled work separately. A diagnostic speed result
           carries no authority and does not establish a production SLO. */
    }

    part def SharedDomainScheduler {
        doc /* Rust registers one ticket for the exact origin, budget and
           history roots in separate namespaces. The oldest conflicting
           ticket precedes later conflicts even while waiting on another root.
           Disjoint tickets can run together. Publication and migration
           use a global ticket. Queue admission grants transaction
           custody only. The live authorization remains in the transaction. */
        doc /* Root discovery without a consumed stamp must rejoin exact
           keys if a global ticket completed during discovery or waiting.
           A cancelled waiter acquires no custody. Once granted, the
           deciding scope retains custody through commit or rollback. */
        doc /* Go limits admission, publishes configuration and propagates
           cancellation. Rust owns the queue and all effect lifetimes.
           An uncertain effect retains the original claim and budget. */
        attribute localSchedulingP99LimitMicros : Integer = 1000;
    }

    part def ProviderStorageLifecycle {
        part scheduler : SharedDomainScheduler;
        doc /* The database owner lives with the server and owns the process
           custody and MVCC gates. A blocking provider operation opens one
           verified Turso session and holds it through completion or failure.
           No session with an unresolved transaction may begin another scope. */
        doc /* An original-task candidate holds bounded static evidence.
           It may travel with the affine dispatch, and each use matches the
           exact original task row and the live publication linkage again.
           A mismatch runs the original validation on the deciding image.
           The domain lookup joins live roots, epochs and original membership.
           Admission reuses that scope's keys for capacity and history writes.
           Later scopes can select stripes from the consumed stamp. Before any
           effect the current stamp must name the same keys under the domain grant.
           A stale selection can only reach validation and rollback. The stamp
           cannot stand in for live claims, history, policy or fencing. */
        doc /* Admission, consume, final request write and each response
           release own separate short deciding scopes. The transaction and
           cursors end at commit or rollback. Transport and client waits
           may span scopes. A writer seal cannot turn unknown into a refund.
           A successful new stream has five fixed scopes for admission, consume,
           dispatch burn, request write and terminal commit. Every output
           range requires one final queue scope. Preparation adds one scope
           per group. A single-range group yields two scopes per range.
           These are base deciding scopes. Receiver invalidation adds an
           observed variable number of read-only requalification scopes;
           they must be reported separately and included in total latency. */
        attribute fixedDecidingScopes : Integer = 5;
        attribute decidingScopesPerResponseRange : Integer = 2;
    }

    part def ProviderDeliveryLifecycle {
        doc /* One real MPSC reservation future owns capacity waiting. The
           producer keeps acknowledged inert frames while servicing the oldest
           receiver's exact-view refresh. No transaction survives a capacity
           wait, and terminal completion joins every pending handoff. */
        doc /* Diagnostic scope traces retain at most sixty-four records.
           Flush indexed chunks only after SQL, authority and scheduler custody
           end. A final marker and contiguous offsets are required before any
           throughput or fairness result can be accepted. Requalification scopes
           cannot silently displace terminal or admission records. */
        attribute diagnosticChunkRecords : Integer = 64;
        attribute queueSlots : Integer = 2;
        attribute stagedReceiverFrames : Integer = 1;
        attribute maximumUnacceptedFrames : Integer = 3;
        attribute originalDeliveryDeadlineMicros : Integer = 1000000;
        attribute finalTurnP99TargetMicros : Integer = 1000;
        attribute readyToGoP99TargetMicros : Integer = 1000;
        assert constraint { maximumUnacceptedFrames == queueSlots + stagedReceiverFrames }
    }

    part def ProviderDomainReadMatrix {
        doc /* Run paired fresh and cached SQL programs on the same image.
           Vary response ranges, concurrency and shared or independent roots.
           Count scopes and retained sends. Measure locked domain read cost,
           prewarm, native begin and commit, domain wait and terminal wall
           time separately. P95 and P99 use completed-stream observations.
           Shared-root waves serialize their conflicting scopes. Independent
           roots may overlap subject to native IO and global barriers. */
        part lifecycle : ProviderStorageLifecycle;
        attribute shortRanges : Integer = 5;
        attribute longRanges : Integer = 13;
        attribute lowConcurrency : Integer = 1;
        attribute highConcurrency : Integer = 4;
        attribute shortScopes : Integer = 15;
        attribute longScopes : Integer = 31;
        attribute streamsPerArm : Integer = 128;
        assert constraint { shortScopes == lifecycle.fixedDecidingScopes + lifecycle.decidingScopesPerResponseRange * shortRanges }
        assert constraint { longScopes == lifecycle.fixedDecidingScopes + lifecycle.decidingScopesPerResponseRange * longRanges }
    }

    part def ProviderSharedTailExperiment {
        doc /* Interleave no-injection and controlled CPU pressure blocks
           on one image. Compare separate and joined progress reads in
           alternating order within each block. For each completed stream,
           correlate terminal latency with worker scheduling delay, domain
           stripe wait, domain hold, native commit and domain read time.
           Native commit and domain read intervals lie inside lock hold.
           A host timer probe measures wake-up delay independently. Native
           wall intervals can include scheduler pauses. */
        doc /* Read dispatch state, next sequence and pending release in one
           deciding image. Check the same live authorization and range
           conditions before reservation or completion. The final send
           still requires its own authority check and commit protocol. */
        part lifecycle : ProviderStorageLifecycle;
        attribute responseRanges : Integer = 13;
        attribute concurrency : Integer = 4;
        attribute streamsPerArm : Integer = 128;
        attribute decidingScopes : Integer = 31;
        assert constraint { decidingScopes == lifecycle.fixedDecidingScopes + lifecycle.decidingScopesPerResponseRange * responseRanges }
    }

    part def ProviderTransportBatchExample {
        doc /* Thirteen response events yield thirteen ranges when each
           Protobuf frame carries one event. Four-row Arrow capacity
           yields three full ranges and one terminal range for the same
           event stream. Row authorization stays per event. Scope counts
           describe this example before any timing measurement. */
        doc /* Run four parallel streams on one image. Compare Protobuf and
           Arrow one-row arms with Arrow four-row batches. Vary shared roots
           and CPU pressure. Separate Rust queue to Go receive time, payload
           codec, ticket wait and commit. Record whole-stream P95 and P99
           and completed-stream throughput. */
        attribute concurrency : Integer = 4;
        attribute queueToGoP99LimitMicros : Integer = 1000;
        part lifecycle : ProviderStorageLifecycle;
        attribute responseEvents : Integer = 13;
        attribute protobufRanges : Integer = 13;
        attribute arrowRowsPerBatch : Integer = 4;
        attribute arrowRanges : Integer = 4;
        attribute protobufScopes : Integer = 31;
        attribute arrowScopes : Integer = 13;
        assert constraint { (arrowRanges - 1) * arrowRowsPerBatch < responseEvents and responseEvents <= arrowRanges * arrowRowsPerBatch }
        assert constraint { protobufScopes == lifecycle.fixedDecidingScopes + lifecycle.decidingScopesPerResponseRange * protobufRanges }
        assert constraint { arrowScopes == lifecycle.fixedDecidingScopes + lifecycle.decidingScopesPerResponseRange * arrowRanges }
    }

    part def ProviderRangePreparationGroup {
        doc /* The Rust provider worker may group up to four contiguous
           complete output ranges decoded from already buffered SSE,
       with at most thirty-two row decisions per preparation ticket.
           It opens one preparation ticket and one Turso transaction.
           Every row passes Cedar on the deciding image. All exact pending
           records and the cursor advance commit together. The worker
           receives affine capabilities only after commit acknowledgment. */
        doc /* Transport capacity and codec work stay outside the deciding
           transaction. Every final queue insertion rechecks the current
           policy, original claim, fence and exact pending range. A later
           member requires its immediate predecessor to be released. A
           failed insert, lost commit response or restart issues no new
           capability. Unknown ranges retain their original budget hold. */
        part lifecycle : ProviderStorageLifecycle;
        attribute maximumRangesPerPreparation : Integer = 4;
        attribute maximumRowsPerPreparation : Integer = 32;
        attribute fixtureRanges : Integer = 13;
        attribute fixturePreparationGroups : Integer = 4;
        attribute fixtureDecidingScopes : Integer = 22;
        assert constraint { fixtureDecidingScopes == lifecycle.fixedDecidingScopes + fixtureRanges + fixturePreparationGroups }
        attribute sameDomainTicketP99TargetMicros : Integer = 1000;
    }

    requirement def BoundedProviderEgressWindow {
        doc /* Candidate architecture. One acknowledged durable response-window
           burn binds the canonical origin, original claim, shared exposure,
           maximum row interval and an exclusive effect-owner incarnation.
           Activation also joins the exact guarded provider response. Loss,
       ambiguity and replacement retire the window and retain the hold. */
        doc /* Every exact frame crosses a current Cedar and original-claim
           guard in the owner turn that transfers it to transport. All live
           authority inputs belong to the same projected image. Mutations
           close the affected conflict components before durable CAS and
           reopen only on the exact fenced image and outcome. */
    }

    requirement def ProviderSemanticProgress {
        doc /* The complete authorization image excludes provider_runs.next_event
           and provider_releases progress. Only fresh exact range insertion with
           cursor CAS, and exact unknown-to-released CAS preserve that image.
           A sealed Rust token is available only to these two audited paths.
           They still register and settle a unique close/commit/activate ticket,
           but neither advance the semantic revision nor block an older,
           acknowledged range. They never authorize their own uncommitted frame. */
        doc /* Policy/schema/review/pending, OAuth/witness, original claim,
           consumed run state/target, immutable plan/profile, shared budget,
           three-level quota, history and domain/fence edits remain semantic.
           Terminal completion is semantic. Generic SQL always invalidates.
           Any ambiguous native progress outcome seals the owner; restart
           cannot adopt a queued role. Progress cannot reconcile witness IO.
           Every new range retains the full live deciding Cedar/claim guard. */
    }

    requirement def ProviderDeliveryJoin {
        doc /* Every production writer enters WriteScope: register a unique
           outcome ticket before scheduler or database waiting, commit one Turso
           outcome, then resolve exactly that ticket. Semantic writers close
           delivery and advance its revision; certified progress preserves it.
           Unknown native outcomes seal the owner;
           witness append uncertainty remains pending until exact-path durable
           reconciliation. Known empty rollback may reopen only after the old
           exclusive transaction is definitively joined and cannot commit late. */
        doc /* All journal profiles retain one logical Rust execution owner.
           Conflict identity contains original origin, shared budget/history,
           API key, user and tenant in distinct namespaces. Metering projection
           is immutable and installed only after acknowledged configuration commit.
           Production exposes no raw Session or SQL execution surface.
           Arc-held frame roles retain process custody through their lifetime.
           After engine and last role retirement, explicitly unlock the lease;
           a duplicated custody-file descriptor is not an execution role. */
        doc /* Queue frames are inert until acknowledged release commit. One
           noncloneable receiver cursor consumes exact owner/session/plan/span
           under the same mutex as writer closure. Compare the live revision;
           a changed view reruns existing Cedar, claim, domain and OAuth guards
           outside that mutex without another send, range burn or reservation.
           Check real OAuth expiry and the original monotonic delivery deadline
           in the deciding turn. Keep at most one staged receiver frame plus\n           two real MPSC slots. Service requalification while polling the same\n           capacity future; join all pending handoffs before terminal completion.\n           Tonic acceptance is not client acknowledgment. */
    }

    requirement def ProviderEgressPromotion {
        doc /* Promotion requires every Policy, OAuth witness, original claim,
           shared budget, history, domain, profile and fence writer to close
           affected owner lanes before its first durable effect. Keep each
           uncertain operation outstanding across lost responses and recovery.
           Activate only an exact full image after all outcomes are resolved.
           A native rollback cannot erase an independent witness append. */
        doc /* The last Weaver-controlled response handoff is the receiver's
           transfer to Tonic. Staging is inert. Live Cedar, original claim,
           real OAuth expiry, cut, owner and one-use cursor belong to that same
           nonblocking turn. Type-enforced writer custody and receiver fencing
           remain implementation prerequisites; model success alone cannot
           promote the currently unimplemented response-window profile. */
    }

    part def ProviderEgressReadyBudget {
        doc /* Engineering budgets for one ready Protobuf frame in the bounded
           lane. They require measured maxima for this envelope and a paired
           end-to-end P99 qualification. A pending control cut, unavailable
           transport credit or provider wait has a separate accounting lane. */
        attribute framePreparationMicros : Integer = 100;
        attribute olderReadyTurns : Integer = 3;
        attribute ownerTurnMicros : Integer = 150;
        attribute schedulerOverheadMicros : Integer = 50;
        attribute localHandoffMicros : Integer = 200;
        attribute readyEnvelopeMicros : Integer = 950;
        attribute readyP99TargetMicros : Integer = 1000;
        assert constraint { readyEnvelopeMicros == framePreparationMicros + (olderReadyTurns + 1) * ownerTurnMicros + schedulerOverheadMicros + localHandoffMicros }
        assert constraint { readyEnvelopeMicros < readyP99TargetMicros }
    }

    item def EgressWindowEvidence;
    port def EgressWindowPort { out item evidence : EgressWindowEvidence; }

    part def WindowIntentStore {
        attribute displayName : String = "Turso / burn window";
        attribute responsibility : String = "Bind original claim\nRetain the shared hold";
        attribute glyph : String = "ledger";
        attribute visualRole : String = "publication";
        port admitted : EgressWindowPort;
    }
    part def EgressMutationBarrier {
        attribute displayName : String = "Rust / close";
        attribute responsibility : String = "Policy + OAuth + domains\nKeep every pending ID";
        attribute glyph : String = "policy";
        attribute visualRole : String = "governance";
        port closed : EgressWindowPort;
    }
    part def EgressAuthorityCut {
        attribute displayName : String = "Rust / activate";
        attribute responsibility : String = "Join DB + OAuth witness\nResolve all pending IDs";
        attribute glyph : String = "publication";
        attribute visualRole : String = "publication";
        port closed : ~EgressWindowPort;
        port image : EgressWindowPort;
    }
    part def InertProviderFrame {
        attribute displayName : String = "Rust / prepare frame";
        attribute responsibility : String = "Exact bytes and next span\nReserve transport credit";
        attribute glyph : String = "stream";
        attribute visualRole : String = "semantic";
        port stagedBytes : EgressWindowPort;
    }
    part def ProviderEgressOwnerTurn {
        attribute displayName : String = "Rust / receiver owner";
        attribute responsibility : String = "Cedar + claim + expiry\nFence + next interval";
        attribute glyph : String = "authorization";
        attribute visualRole : String = "execution";
        port admission : ~EgressWindowPort;
        port current : ~EgressWindowPort;
        port ready : ~EgressWindowPort;
        port offer : EgressWindowPort;
    }
    part def ProviderEgressTransport {
        attribute displayName : String = "Tonic / accept once";
        attribute responsibility : String = "One current Rust owner\nObserve delivery later";
        attribute glyph : String = "stream";
        attribute visualRole : String = "execution";
        port acceptedBytes : ~EgressWindowPort;
    }

    part def DeliveryValidation {
        attribute displayName : String = "Turso / validate";
        attribute responsibility : String = "Cedar + claim + hold\nKeep the semantic cut";
        attribute glyph : String = "ledger";
        attribute visualRole : String = "ledger";
        port closed : ~EgressWindowPort;
        port validated : EgressWindowPort;
    }
    part def CertifiedRangeProgress {
        attribute displayName : String = "Turso / range progress";
        attribute responsibility : String = "Append or release exactly\nKeep prior permission";
        attribute glyph : String = "ledger";
        attribute visualRole : String = "ledger";
        port preserved : EgressWindowPort;
    }
    part def DeliveryReceiver {
        attribute displayName : String = "Rust / consume once";
        attribute responsibility : String = "Live cut + owner + expiry\nOne next cursor";
        attribute glyph : String = "authorization";
        attribute visualRole : String = "execution";
        port validated : ~EgressWindowPort;
        port staged : ~EgressWindowPort;
        port progress : ~EgressWindowPort;
        port offer : EgressWindowPort;
    }
    part providerDeliveryJoin {
        part changes : EgressMutationBarrier;
        part validated : DeliveryValidation;
        part progress : CertifiedRangeProgress;
        part staged : InertProviderFrame;
        part receiver : DeliveryReceiver;
        part tonic : ProviderEgressTransport;
        connection closeBeforeWrite connect changes.closed to validated.closed;
        connection exactRevision connect validated.validated to receiver.validated;
        connection inertOnly connect staged.stagedBytes to receiver.staged;
        connection unchangedMeaning connect progress.preserved to receiver.progress;
        connection oneOffer connect receiver.offer to tonic.acceptedBytes;
    }

    part providerEgressWindow {
        part mutation : EgressMutationBarrier;
        part durable : WindowIntentStore;
        part publication : EgressAuthorityCut;
        part preparation : InertProviderFrame;
        part owner : ProviderEgressOwnerTurn;
        part transport : ProviderEgressTransport;
        connection closedCut connect mutation.closed to publication.closed;
        connection burn connect durable.admitted to owner.admission;
        connection currentImage connect publication.image to owner.current;
        connection inertFrame connect preparation.stagedBytes to owner.ready;
        connection liveTransfer connect owner.offer to transport.acceptedBytes;
    }

    part def ProviderRangeScopeFairness {
        doc /* A later ticket granted before an older conflicting
           waiter is an inversion. Compare within one shared-root wave and across
           families. Measure wait and hold per prepare and final queue,
           plus the spread of accumulated waits across concurrent flows.
           Ordinals come from the scheduler registration and grant events.
           Same-root waves require zero conflicting inversions. FIFO orders
           conflicting tickets. Native IO and earlier scopes still bound latency. */
        doc /* After the live gate, read the exact pending range and check
           digest and queue-time authority. Queue acceptance precedes the
           release-marker write and native commit. Rollback retains the
           durable pending marker and original reservation. Early-marker
           and prewarmed-program experiments are isolated diagnostics
           until repeatable throughput and tail measurements justify a change. */
        part lifecycle : ProviderStorageLifecycle;
        attribute responseRanges : Integer = 13;
        attribute concurrency : Integer = 4;
        attribute prepareScopesPerRange : Integer = 1;
        attribute queueScopesPerRange : Integer = 1;
        assert constraint { prepareScopesPerRange + queueScopesPerRange == lifecycle.decidingScopesPerResponseRange }
    }

    part def ProviderCurrentnessBudget {
        doc /* Proposed allocation for mean locked read time per completed stream
           in the five-range local MVCC fixture. The long-range matrix measures scaling.
           Admit a performance claim only after controlled, repeatable evidence.
           Full recovery reconciliation grows with the union of domain origins
           and retained claims. A bounded transactional projection is a future
           option contingent on verified equivalence and fail-closed recovery.
           Publication qualifies immutable review and original receipt evidence
           outside the lock. The deciding scope matches exact rows, latest
           reviewer epoch, current revision and fence, and reads the pending
           barrier. A candidate carries no authority across a changed image. */
        part lifecycle : ProviderStorageLifecycle;
        attribute fixtureResponseRanges : Integer = 5;
        attribute fixtureDecidingScopes : Integer = 15;
        assert constraint { fixtureDecidingScopes == lifecycle.fixedDecidingScopes + lifecycle.decidingScopesPerResponseRange * fixtureResponseRanges }
        attribute domainReadBudgetNs : Integer = 2000000;
        attribute publicationReadBudgetNs : Integer = 5000000;
        attribute profileReadBudgetNs : Integer = 3000000;
        attribute claimReadBudgetNs : Integer = 10000000;
        attribute currentnessReadBudgetNs : Integer = 20000000;
        assert constraint { domainReadBudgetNs + publicationReadBudgetNs + profileReadBudgetNs + claimReadBudgetNs <= currentnessReadBudgetNs }
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
    action def DeriveSemanticCandidate {
        in item original : PolicyEvidenceDesign::SemanticCommitment;
        out item candidate : PolicyEvidenceDesign::SourceCommand;
        doc /* Derivation preserves independently admitted original meaning.
           This action grants no publication, consumption or transport right. */
    }
    action def OrchestrateSourcePublication {
        in item candidate : PolicyEvidenceDesign::SourceCommand;
        out item command : PolicyEvidenceDesign::SourceCommand;
        doc /* Preserve original commitment while submitting authenticated
           current-source commands; reconcile uncertain outcomes by identity. */
    }
    action def CommitOriginalAdmission {
        in item command : PolicyEvidenceDesign::SourceCommand;
        out item observation : PolicyEvidenceDesign::PublishedObservation;
        doc /* Existing deciding transaction, current authority and immutable
           original binding. Commit produces an observation, never external IO. */
    }
    action def GuardFinalEffect {
        in item permit : ConsumedPermit;
        out item request : CanonicalWireRequest;
        doc /* Rejoin actual current authority and retained consumption under
           final custody. An inert candidate cannot invoke this action. */
    }
    part def SchemeSemanticPublisher {
        attribute overviewName : String = "Task contract";
        attribute overviewSummary : String = "Original scope";
        attribute overviewGlyph : String = "task-contract";
        action deriveCandidate : DeriveSemanticCandidate;
        doc /* Normative semantic allocation: reuse Agentic AI Lab Governor to
           select admitted original scope and Governance to assess obligations,
           evidence and source assets. Scheme defines routine meaning, original
           task identity and permitted alias/derivation relations. The original
           binds claim, profile commitment and shared budget/history domains;
           reconnect, source rotation and route fallback cannot redefine it.
           Governor selects eligible steps; Governance assesses the configured
           Profile through open generic dispatch. They compose in the source
           program but do not share a replaceable selector/assessment method.
           The downstream GovernanceScopeContract exposes assessment only;
           Gateway projects the upstream public governor contract directly.
           This is semantic ownership, not a separate identity issuer service.
           An authenticated independent original must precede compilation;
           Scheme cannot authenticate that original merely by echoing it.
           Existing SourceExpectation/BoundSource checks preserve typed original
           equality, not the truth of a caller-selected task key. End-to-end
           authentic task-key issuance remains a delivery gap (59.82).
           Output is an inert typed candidate through sourceCandidates. Reuse
           inherited Record/Function contracts and Scheme-to-Rust FFI conversion;
           no new governance DSL, credential system or parallel source ledger.
           Scheme does not own database commits, spend-state, budget settlement,
           transport credentials or final sends. A successful semantic assessment
           cannot mint a ConsumedPermit or release an unknown reservation. */
        attribute leanDeclaration : String = "CedarPooSpec.Gateway.ProfileObject.Publication";
        attribute leanFields : String = "context,session,selected,projected";
        attribute securityName : String = "Scheme / Original contract";
        attribute securityResponsibility : String = "Task scope and required parents\nPublished selected profile\nConfiguration grants no send right";
        attribute displayName : String = "Scheme / Semantics";
        attribute responsibility : String = "Governor: eligible steps\nGovernance: profile assessment\nChecked Cedar projection";
        attribute glyph : String = "routine";
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
        attribute overviewName : String = "Route proposal";
        attribute overviewSummary : String = "Suggest a provider";
        attribute overviewGlyph : String = "route-choice";
        action publishCandidate : OrchestrateSourcePublication;
        doc /* Preserve the semantic original through configuration normalization,
           protocol aliasing and authenticated publication. JSON/YAML populates
           the same admitted contracts; it cannot define another authorization
           language. Routing, retries and fallback select candidates within that
           original. Go neither invents original task keys from session labels
           nor treats compile/publication acknowledgments as final-use permits. */
        attribute displayName : String = "Go / Control + routing";
        attribute leanDeclaration : String = "CedarPooSpec.Gateway.Context";
        attribute leanFields : String = "scope,policyRevision,ownerEpoch,historyRevision,factFloor";
        attribute securityName : String = "Go / Source publication";
        attribute securityGlyph : String = "publication";
        attribute securityResponsibility : String = "Carry the original context\nPublish over authenticated gRPC\nUnknown replies stay unresolved";
        attribute responsibility : String = "Cloud + protocol integration\nOne owned source image\nAuthenticated publication + routing";
        attribute glyph : String = "routing";
        attribute visualRole : String = "selection";
        doc /* BootstrapProducer receives the server's typed CompileSource
           artifact over authenticated gRPC and reobserves source authority.
           Its bounded typed projection freezes and validates one owned image, then
           shares the private publication implementation with file configuration.
           It neither JSON-roundtrips nor repeats normalization across these
           internal functions. No borrowed protobuf container escapes. Source
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
        attribute overviewName : String = "Current checks";
        attribute overviewSummary : String = "Cedar decides";
        attribute overviewGlyph : String = "policy";
        doc /* Cedar/SPEC owns reusable authorization meaning and conditional
           preservation laws. Rust materializes authenticated actual context and
           evaluates the existing Cedar mechanism; it does not reimplement
           Scheme semantics or add an independent identity authorization DSL.
           Imported proof declarations must exist in the pinned dependency;
           target Gateway declarations are not evidence of a checked import. */
        attribute leanDeclaration : String = "CedarPooSpec.Gateway.Receipt";
        attribute leanFields : String = "preparationValid,contextMatches,sourceMatches,effectMatches,stateMatches,checksAccepted,policyCurrent,requestValid,entitiesValid,allowed";
        attribute securityName : String = "Cedar / Actual request";
        attribute securityResponsibility : String = "Exact effect, facts and schema\nCurrent Policy + profile checks\nError-free Allow is one premise";
        attribute displayName : String = "Cedar / Policy";
        attribute responsibility : String = "Evaluate the exact effect\nRequire error-free permission\nAllow is not a send handle";
        attribute glyph : String = "policy";
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
        attribute overviewName : String = "Claim + budget";
        attribute overviewSummary : String = "Record before sending";
        attribute overviewGlyph : String = "budget-ledger";
        action commitOriginal : CommitOriginalAdmission;
        doc /* Implement the semantic original binding in the existing source
           deciding transaction, with exact-outcome recovery and current fencing.
           Rust validates provenance and equality; it cannot infer whether two
           entirely relabeled tasks are the same original from body equality.
           Retain claim, domain lineage and unknown holds across source handoff.
           Model allocation does not close the authentic-key issuance gap. */
        attribute leanDeclaration : String = "CedarPooSpec.Gateway.ZeroTrust.Proposal";
        attribute leanFields : String = "before,receipt,contextBound,authorityId,after,consumption";
        attribute securityName : String = "Rust / Original consumption";
        attribute securityResponsibility : String = "Original operation + grant\nCommit both ledgers with budget\nRenewed grants cannot replay work";
        attribute displayName : String = "Rust / Authority ledger";
        attribute responsibility : String = "MRR Data Backend / Turso\nClaim, budget and fence together\nPersist original consumption";
        attribute glyph : String = "ledger";
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
           or provider exactly-once delivery. Explicit MVCC shares one process
           owner and Database. Family scopes can overlap; global mutation and
           publication excludes all live scopes. Final use overlaps only across
           independent original claim/budget/history families. */
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
        attribute overviewName : String = "Final-use gate";
        attribute overviewSummary : String = "Recheck actual use";
        attribute overviewGlyph : String = "permission-check";
        action guardEffect : GuardFinalEffect;
        attribute leanDeclaration : String = "CedarPooSpec.Gateway.ZeroTrust.FinalUse";
        attribute leanFields : String = "sameView,authenticated,current,profileAuthority,committed,unknownRetained,notRevoked,mediated";
        attribute securityName : String = "Rust / Final-use guard";
        attribute securityResponsibility : String = "Identity, profile and current view\nDurable consume + unknown holds\nFence every actual external effect";
        attribute displayName : String = "Rust / Final broker";
        attribute responsibility : String = "Own consumed opportunities\nGuard dispatch and each range\nUnknown exposure remains held";
        attribute glyph : String = "authorization";
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
           Provider dispatch holds its deciding transaction through fixed-body
           write and TLS flush; WriteSeal then retires every application writer.
           The sole owned HTTP driver reads headers only after commit, outside
           this gate. Dropping it on commit loss cannot leave a background writer.
           The original dispatched row records guarded callback completion, not
           remote execution. A lost native acknowledgment poisons old custody;
           recovery retains the burn and unknown hold without recreating IO.
           Response queue insertion rejoins the current independent row guard. */
        port consumed : ~ConsumedPort;
        port wire : WirePort;
    }
    part def HttpsExecutor {
        attribute overviewName : String = "Bounded write";
        attribute overviewSummary : String = "Write + flush + seal";
        attribute overviewGlyph : String = "bounded-write";
        attribute leanDeclaration : String = "CedarPooSpec.Gateway.ZeroTrust.CommittedPrefix";
        attribute leanFields : String = "tail,installed";
        attribute securityName : String = "Rust / Stream continuity";
        attribute securityGlyph : String = "stream";
        attribute securityResponsibility : String = "Retain original spent prefix\nReassess each new governed use\nRecovery cannot mint permission";
        attribute displayName : String = "Bounded HTTPS executor";
        attribute responsibility : String = "Provider write + flush + seal\nNo implicit retry or fallback\nRetain partial / unknown exposure";
        attribute glyph : String = "writer";
        attribute visualRole : String = "execution";
        doc /* Exact committed target and body, no inherited proxy, redirect or automatic retry.
           Streaming providers use the sealed Hyper/TLS owner and await headers
           outside their deciding scope. The separate generic request adapter
           retains its established conservative response-returning guard. */
        port wire : ~WirePort;
        port provider : WirePort;
    }
    part def LlmProviderEndpoint {
        attribute overviewName : String = "LLM provider";
        attribute overviewSummary : String = "Return a result";
        attribute overviewGlyph : String = "model-provider";
        attribute displayName : String = "LLM / Tool endpoint";
        attribute responsibility : String = "Bound route and request\nExternal effects and responses\nNo inferred exactly-once\ndelivery";
        attribute glyph : String = "provider";
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
        attribute overviewName : String = "Local metrics";
        attribute overviewSummary : String = "No execution rights";
        attribute overviewGlyph : String = "telemetry";
        attribute displayName : String = "Telemetry";
        attribute responsibility : String = "Local counters\nAuthenticated reads\nNo execution rights";
        attribute glyph : String = "telemetry";
        attribute visualRole : String = "capture";
        doc /* Current Go source/startup producers emit fixed-label local slog
           metadata; native integration fixtures supply clocked phase records.
           These ordinary stderr diagnostics are not the target bounded event
           bus, loss counters, exporter, durable audit or readiness authority.
           Their presence cannot prove completion or discharge unknown holds. */
        doc /* Local metrics are implemented by weaver-telemetry and the Go
           telemetry package, enabled with each existing runtime owner. Fixed
           counters accept no payload, identity label, arbitrary trace context,
           callback or exporter. Existing authenticated gRPC carries snapshots;
           Rust additionally checks current source authority. No new listener.
           Snapshots are independent relaxed atomic observations, not a coherent
           ledger image. Saturating updates use constant space but do not promise
           wait-free latency under contention. Counter reset on restart cannot
           clear durable claims or unknown holds. OTLP, traces, security event
           export and durable audit remain delivery gates requiring explicit
           destination/credential publication and Policy. */
        doc /* Observe already extracted metadata with bounded nonblocking
           submission. Do not re-read a mutable request, retry an effect or mutate
           authority/history/accounting from a telemetry callback. */
    }
    requirement def TelemetryNoninterference {
        doc /* Metrics cannot issue sends, change claims, settle budgets or
           acknowledge source commits. Only fixed counter kinds cross the API;
           no prompt, response text, credential or variable-cardinality identity.
           Rust source-only inspection and Go authenticated inspection use existing
           listeners. Unknown effects stay consumed/held across arbitrary reads
           and local-counter reset. No external exporter is currently enabled. */
    }
    part def DerivedEvidenceAdapter {
        attribute overviewName : String = "Evidence";
        attribute overviewSummary : String = "Bound observations";
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
        connection proposeTask connect semanticPublisher.sourceCandidates to controlAdapter.sourceCandidates;
        connection controlAdapter_sourceCommands_to_ledger_sourceCommands connect controlAdapter.sourceCommands to ledger.sourceCommands;
        connection ledger_sourceOutcomes_to_controlAdapter_sourceOutcomes connect ledger.sourceOutcomes to controlAdapter.sourceOutcomes;
        connection controlAdapter_semanticObservations_to_semanticPublisher_sourceObservations connect controlAdapter.semanticObservations to semanticPublisher.sourceObservations;
        connection ledger_effectOutcomes_to_controlAdapter_effectObservations connect ledger.effectOutcomes to controlAdapter.effectObservations;
        connection controlAdapter_semanticEffectObservations_to_semanticPublisher_effectObservations connect controlAdapter.semanticEffectObservations to semanticPublisher.effectObservations;
        connection derivedEvidence_candidates_to_semanticPublisher_derivedFacts connect derivedEvidence.candidates to semanticPublisher.derivedFacts;
        connection proposeEffect connect controlAdapter.proposals to ledger.proposals;
        connection checkPolicy connect ledger.policyEvaluation to policy.evaluation;
        connection ledger_observations_to_controlAdapter_observations connect ledger.observations to controlAdapter.observations;
        connection consumedClaim connect ledger.consumed to broker.consumed;
        connection recheckUse connect broker.wire to executor.wire;
        connection boundedWrite connect executor.provider to provider.request;
    }
    part targetDeployment : ExecutionAuthorityDeployment;
}
