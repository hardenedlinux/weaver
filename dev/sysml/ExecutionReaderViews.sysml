// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package WeaverExecutionReaderViews {
    private import ScalarValues::*;
    private import Views::*;
    private import StandardViewDefinitions::*;
    doc /* Reader projections over the original execution and account lineage.
       These views distinguish the authority that decides each action from the
       consumers of its durable records. */
    item def BoundRecord;
    port def BoundRecordPort { out item value : BoundRecord; }
    part def resultProjection_result {
        attribute displayName : String = "Immutable result";
        attribute responsibility : String = "Exact original transition";
        attribute glyph : String = "ledger";
        port incoming : ~BoundRecordPort;
        port outgoing : BoundRecordPort;
    }
    part def resultProjection_source {
        attribute displayName : String = "Source projection";
        attribute responsibility : String = "Materialize once";
        attribute glyph : String = "publication";
        port incoming : ~BoundRecordPort;
        port outgoing : BoundRecordPort;
    }
    part def resultProjection_account {
        attribute displayName : String = "Account projection";
        attribute responsibility : String = "Apply original delta";
        attribute glyph : String = "budget";
        port incoming : ~BoundRecordPort;
        port outgoing : BoundRecordPort;
    }
    part def resultProjection_unknownOutcome {
        attribute displayName : String = "Unknown reply";
        attribute responsibility : String = "Read the original result";
        attribute glyph : String = "recovery";
        port incoming : ~BoundRecordPort;
        port outgoing : BoundRecordPort;
    }
    part resultProjectionBoundary {
        part result : resultProjection_result;
        part source : resultProjection_source;
        part account : resultProjection_account;
        part unknownOutcome : resultProjection_unknownOutcome;
        connection sourceApply connect result.outgoing to source.incoming;
        connection accountApply connect result.outgoing to account.incoming;
        connection exactReadback connect unknownOutcome.outgoing to result.incoming;
    }
    view resultProjection {
        attribute mappedFile : String = "docs/20-29-execution-authority/20-result-projection/20.02-result-projection.d2";
        attribute displayTitle : String = "Apply the committed result";
        attribute displaySubtitle : String = "One decision feeds both stores. Replaying it never calls a provider.";
        attribute displayEyebrow : String = "WEAVER / EXECUTION AND ACCOUNT AUTHORITY";
        attribute readerQuestion : String = "Which record owns the original ledger transition?";
        attribute designAudience : String = "Gateway runtime reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "One decision feeds both stores. Replaying it never calls a provider.";
        attribute designFocus : String = "result";
        attribute visualThemes : String = "sketchbook,blueprint,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose resultProjectionBoundary::result;
        expose resultProjectionBoundary::source;
        expose resultProjectionBoundary::account;
        expose resultProjectionBoundary::unknownOutcome;
        expose resultProjectionBoundary::sourceApply;
        expose resultProjectionBoundary::accountApply;
        expose resultProjectionBoundary::exactReadback;
        render asInterconnectionDiagram;
    }

    part def joinEnqueue_original {
        attribute displayName : String = "Original operation";
        attribute responsibility : String = "Canonical slot";
        attribute glyph : String = "claim";
        port incoming : ~BoundRecordPort;
        port outgoing : BoundRecordPort;
    }
    part def joinEnqueue_current {
        attribute displayName : String = "Current state";
        attribute responsibility : String = "Source, account and fence";
        attribute glyph : String = "policy";
        port incoming : ~BoundRecordPort;
        port outgoing : BoundRecordPort;
    }
    part def joinEnqueue_enqueue {
        attribute displayName : String = "Atomic enqueue";
        attribute responsibility : String = "Compare and claim";
        attribute glyph : String = "ledger";
        port incoming : ~BoundRecordPort;
        port outgoing : BoundRecordPort;
    }
    part def joinEnqueue_durable {
        attribute displayName : String = "Durable queue";
        attribute responsibility : String = "No provider I/O here";
        attribute glyph : String = "publication";
        port incoming : ~BoundRecordPort;
        port outgoing : BoundRecordPort;
    }
    part def joinEnqueue_stale {
        attribute displayName : String = "Changed read set";
        attribute responsibility : String = "Refuse admission";
        attribute glyph : String = "unknown";
        port incoming : ~BoundRecordPort;
        port outgoing : BoundRecordPort;
    }
    part joinEnqueueBoundary {
        part original : joinEnqueue_original;
        part current : joinEnqueue_current;
        part enqueue : joinEnqueue_enqueue;
        part durable : joinEnqueue_durable;
        part stale : joinEnqueue_stale;
        connection bindSlot connect original.outgoing to enqueue.incoming;
        connection compare connect current.outgoing to enqueue.incoming;
        connection commit connect enqueue.outgoing to durable.incoming;
        connection deny connect enqueue.outgoing to stale.incoming;
    }
    view joinEnqueue {
        attribute mappedFile : String = "docs/20-29-execution-authority/21-join-enqueue/21.02-join-enqueue.d2";
        attribute displayTitle : String = "Join and enqueue atomically";
        attribute displaySubtitle : String = "The transaction creates one durable slot for the original operation.";
        attribute displayEyebrow : String = "WEAVER / EXECUTION AND ACCOUNT AUTHORITY";
        attribute readerQuestion : String = "Where does the checked join become queue authority?";
        attribute designAudience : String = "Gateway runtime reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "The transaction creates one durable slot for the original operation.";
        attribute designFocus : String = "enqueue";
        attribute visualThemes : String = "sketchbook,ember,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose joinEnqueueBoundary::original;
        expose joinEnqueueBoundary::current;
        expose joinEnqueueBoundary::enqueue;
        expose joinEnqueueBoundary::durable;
        expose joinEnqueueBoundary::stale;
        expose joinEnqueueBoundary::bindSlot;
        expose joinEnqueueBoundary::compare;
        expose joinEnqueueBoundary::commit;
        expose joinEnqueueBoundary::deny;
        render asInterconnectionDiagram;
    }

    part def executorOffer_queued {
        attribute displayName : String = "Durable queue";
        attribute responsibility : String = "Find original operation";
        attribute glyph : String = "ledger";
        port incoming : ~BoundRecordPort;
        port outgoing : BoundRecordPort;
    }
    part def executorOffer_current {
        attribute displayName : String = "Current authority";
        attribute responsibility : String = "Policy, history and fence";
        attribute glyph : String = "policy";
        port incoming : ~BoundRecordPort;
        port outgoing : BoundRecordPort;
    }
    part def executorOffer_burn {
        attribute displayName : String = "Affine dispatch burn";
        attribute responsibility : String = "Retain exact range";
        attribute glyph : String = "claim";
        port incoming : ~BoundRecordPort;
        port outgoing : BoundRecordPort;
    }
    part def executorOffer_offer {
        attribute displayName : String = "Actual offer gate";
        attribute responsibility : String = "Rust owns submission";
        attribute glyph : String = "authorization";
        port incoming : ~BoundRecordPort;
        port outgoing : BoundRecordPort;
    }
    part def executorOffer_hold {
        attribute displayName : String = "Unknown exposure";
        attribute responsibility : String = "No replacement send";
        attribute glyph : String = "unknown";
        port incoming : ~BoundRecordPort;
        port outgoing : BoundRecordPort;
    }
    part executorOfferBoundary {
        part queued : executorOffer_queued;
        part current : executorOffer_current;
        part burn : executorOffer_burn;
        part offer : executorOffer_offer;
        part hold : executorOffer_hold;
        connection bindOriginal connect queued.outgoing to burn.incoming;
        connection recheck connect current.outgoing to offer.incoming;
        connection joinBurn connect burn.outgoing to offer.incoming;
        connection uncertain connect offer.outgoing to hold.incoming;
    }
    view executorOffer {
        attribute mappedFile : String = "docs/20-29-execution-authority/22-executor-offer/22.02-executor-offer.d2";
        attribute displayTitle : String = "Check at the transport offer";
        attribute displaySubtitle : String = "Dequeue permits lookup. Current authority controls possible submission.";
        attribute displayEyebrow : String = "WEAVER / EXECUTION AND ACCOUNT AUTHORITY";
        attribute readerQuestion : String = "Can dequeued work enter transport after revocation?";
        attribute designAudience : String = "Gateway runtime reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "Dequeue permits lookup. Current authority controls possible submission.";
        attribute designFocus : String = "offer";
        attribute visualThemes : String = "sketchbook,ocean,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose executorOfferBoundary::queued;
        expose executorOfferBoundary::current;
        expose executorOfferBoundary::burn;
        expose executorOfferBoundary::offer;
        expose executorOfferBoundary::hold;
        expose executorOfferBoundary::bindOriginal;
        expose executorOfferBoundary::recheck;
        expose executorOfferBoundary::joinBurn;
        expose executorOfferBoundary::uncertain;
        render asInterconnectionDiagram;
    }

    part def executionEvidence_dispatch {
        attribute displayName : String = "Dispatch ledger";
        attribute responsibility : String = "Exact possible offer";
        attribute glyph : String = "ledger";
        port incoming : ~BoundRecordPort;
        port outgoing : BoundRecordPort;
    }
    part def executionEvidence_closed {
        attribute displayName : String = "Closed executor";
        attribute responsibility : String = "Retire old writers";
        attribute glyph : String = "authorization";
        port incoming : ~BoundRecordPort;
        port outgoing : BoundRecordPort;
    }
    part def executionEvidence_receipt {
        attribute displayName : String = "Terminal evidence";
        attribute responsibility : String = "Bind original operation";
        attribute glyph : String = "history";
        port incoming : ~BoundRecordPort;
        port outgoing : BoundRecordPort;
    }
    part def executionEvidence_reconcile {
        attribute displayName : String = "Evidence join";
        attribute responsibility : String = "No execution or terminal use";
        attribute glyph : String = "recovery";
        port incoming : ~BoundRecordPort;
        port outgoing : BoundRecordPort;
    }
    part def executionEvidence_hold {
        attribute displayName : String = "Unresolved exposure";
        attribute responsibility : String = "Keep the hold";
        attribute glyph : String = "unknown";
        port incoming : ~BoundRecordPort;
        port outgoing : BoundRecordPort;
    }
    part def executionEvidence_settle {
        attribute displayName : String = "Account application";
        attribute responsibility : String = "Settle known usage";
        attribute glyph : String = "budget";
        port incoming : ~BoundRecordPort;
        port outgoing : BoundRecordPort;
    }
    part executionEvidenceBoundary {
        part dispatch : executionEvidence_dispatch;
        part closed : executionEvidence_closed;
        part receipt : executionEvidence_receipt;
        part reconcile : executionEvidence_reconcile;
        part hold : executionEvidence_hold;
        part settle : executionEvidence_settle;
        connection readBurn connect dispatch.outgoing to reconcile.incoming;
        connection fence connect closed.outgoing to reconcile.incoming;
        connection verifyReceipt connect receipt.outgoing to reconcile.incoming;
        connection incomplete connect reconcile.outgoing to hold.incoming;
        connection qualified connect reconcile.outgoing to settle.incoming;
    }
    view executionEvidence {
        attribute mappedFile : String = "docs/20-29-execution-authority/23-execution-reconciliation/23.02-execution-reconciliation.d2";
        attribute displayTitle : String = "Settle from execution evidence";
        attribute displaySubtitle : String = "A zero source counter cannot settle an original reservation.";
        attribute displayEyebrow : String = "WEAVER / EXECUTION AND ACCOUNT AUTHORITY";
        attribute readerQuestion : String = "What proves that no external effect took place?";
        attribute designAudience : String = "Gateway runtime reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "A zero source counter cannot settle an original reservation.";
        attribute designFocus : String = "reconcile";
        attribute visualThemes : String = "sketchbook,field-notes,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose executionEvidenceBoundary::dispatch;
        expose executionEvidenceBoundary::closed;
        expose executionEvidenceBoundary::receipt;
        expose executionEvidenceBoundary::reconcile;
        expose executionEvidenceBoundary::hold;
        expose executionEvidenceBoundary::settle;
        expose executionEvidenceBoundary::readBurn;
        expose executionEvidenceBoundary::fence;
        expose executionEvidenceBoundary::verifyReceipt;
        expose executionEvidenceBoundary::incomplete;
        expose executionEvidenceBoundary::qualified;
        render asInterconnectionDiagram;
    }

    part def accountCommit_reservation {
        attribute displayName : String = "Original reservation";
        attribute responsibility : String = "Bind application ID";
        attribute glyph : String = "claim";
        port incoming : ~BoundRecordPort;
        port outgoing : BoundRecordPort;
    }
    part def accountCommit_usage {
        attribute displayName : String = "Final usage";
        attribute responsibility : String = "Tenant signature + formula";
        attribute glyph : String = "history";
        port incoming : ~BoundRecordPort;
        port outgoing : BoundRecordPort;
    }
    part def accountCommit_atomic {
        attribute displayName : String = "Atomic account commit";
        attribute responsibility : String = "Reservation, hold and balance";
        attribute glyph : String = "ledger";
        port incoming : ~BoundRecordPort;
        port outgoing : BoundRecordPort;
    }
    part def accountCommit_prefix {
        attribute displayName : String = "Protected prefix";
        attribute responsibility : String = "Exact committed outcome";
        attribute glyph : String = "publication";
        port incoming : ~BoundRecordPort;
        port outgoing : BoundRecordPort;
    }
    part def accountCommit_lookup {
        attribute displayName : String = "Lost reply";
        attribute responsibility : String = "Read back the same result";
        attribute glyph : String = "recovery";
        port incoming : ~BoundRecordPort;
        port outgoing : BoundRecordPort;
    }
    part accountCommitBoundary {
        part reservation : accountCommit_reservation;
        part usage : accountCommit_usage;
        part atomic : accountCommit_atomic;
        part prefix : accountCommit_prefix;
        part lookup : accountCommit_lookup;
        connection bindApplication connect reservation.outgoing to atomic.incoming;
        connection joinEvidence connect usage.outgoing to atomic.incoming;
        connection commit connect atomic.outgoing to prefix.incoming;
        connection exactReadback connect lookup.outgoing to prefix.incoming;
    }
    view accountCommit {
        attribute mappedFile : String = "docs/20-29-execution-authority/24-account-commit/24.02-account-commit.d2";
        attribute displayTitle : String = "Commit the original application once";
        attribute displaySubtitle : String = "The independent prefix determines which exact outcome recovery may use.";
        attribute displayEyebrow : String = "WEAVER / EXECUTION AND ACCOUNT AUTHORITY";
        attribute readerQuestion : String = "Which state changes must commit together?";
        attribute designAudience : String = "Gateway runtime reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "The independent prefix determines which exact outcome recovery may use.";
        attribute designFocus : String = "atomic";
        attribute visualThemes : String = "sketchbook,blueprint,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose accountCommitBoundary::reservation;
        expose accountCommitBoundary::usage;
        expose accountCommitBoundary::atomic;
        expose accountCommitBoundary::prefix;
        expose accountCommitBoundary::lookup;
        expose accountCommitBoundary::bindApplication;
        expose accountCommitBoundary::joinEvidence;
        expose accountCommitBoundary::commit;
        expose accountCommitBoundary::exactReadback;
        render asInterconnectionDiagram;
    }

    part def walActivation_frame {
        attribute displayName : String = "Local WAL walFrame";
        attribute responsibility : String = "Retain complete bytes";
        attribute glyph : String = "ledger";
        port incoming : ~BoundRecordPort;
        port outgoing : BoundRecordPort;
    }
    part def walActivation_anchor {
        attribute displayName : String = "Anchor candidate";
        attribute responsibility : String = "Durable acceptance only";
        attribute glyph : String = "claim";
        port incoming : ~BoundRecordPort;
        port outgoing : BoundRecordPort;
    }
    part def walActivation_commitRecord {
        attribute displayName : String = "Protected commit";
        attribute responsibility : String = "One financial delta";
        attribute glyph : String = "budget";
        port incoming : ~BoundRecordPort;
        port outgoing : BoundRecordPort;
    }
    part def walActivation_coverage {
        attribute displayName : String = "Recovery coverage";
        attribute responsibility : String = "Current prefix and WAL";
        attribute glyph : String = "history";
        port incoming : ~BoundRecordPort;
        port outgoing : BoundRecordPort;
    }
    part def walActivation_activate {
        attribute displayName : String = "Active balance image";
        attribute responsibility : String = "Install exact projection";
        attribute glyph : String = "publication";
        port incoming : ~BoundRecordPort;
        port outgoing : BoundRecordPort;
    }
    part walActivationBoundary {
        part walFrame : walActivation_frame;
        part anchor : walActivation_anchor;
        part commitRecord : walActivation_commitRecord;
        part coverage : walActivation_coverage;
        part activate : walActivation_activate;
        connection acceptFrame connect walFrame.outgoing to anchor.incoming;
        connection commit connect anchor.outgoing to commitRecord.incoming;
        connection completeFrames connect walFrame.outgoing to coverage.incoming;
        connection verifyPrefix connect commitRecord.outgoing to coverage.incoming;
        connection install connect coverage.outgoing to activate.incoming;
    }
    view walActivation {
        attribute mappedFile : String = "docs/20-29-execution-authority/25-wal-activation/25.02-wal-activation.d2";
        attribute displayTitle : String = "Activate a confirmed WAL result";
        attribute displaySubtitle : String = "A durable frame and accepted anchor are distinct from a committed balance.";
        attribute displayEyebrow : String = "WEAVER / EXECUTION AND ACCOUNT AUTHORITY";
        attribute readerQuestion : String = "When can a local WAL frame affect a projection?";
        attribute designAudience : String = "Gateway runtime reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "A durable frame and accepted anchor are distinct from a committed balance.";
        attribute designFocus : String = "activate";
        attribute visualThemes : String = "sketchbook,ocean,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose walActivationBoundary::walFrame;
        expose walActivationBoundary::anchor;
        expose walActivationBoundary::commitRecord;
        expose walActivationBoundary::coverage;
        expose walActivationBoundary::activate;
        expose walActivationBoundary::acceptFrame;
        expose walActivationBoundary::commit;
        expose walActivationBoundary::completeFrames;
        expose walActivationBoundary::verifyPrefix;
        expose walActivationBoundary::install;
        render asInterconnectionDiagram;
    }

    part def checkpoint_body {
        attribute displayName : String = "Complete checkpoint";
        attribute responsibility : String = "Original records and holds";
        attribute glyph : String = "ledger";
        port incoming : ~BoundRecordPort;
        port outgoing : BoundRecordPort;
    }
    part def checkpoint_publishRecord {
        attribute displayName : String = "Published checkpoint";
        attribute responsibility : String = "Authenticated committed cut";
        attribute glyph : String = "publication";
        port incoming : ~BoundRecordPort;
        port outgoing : BoundRecordPort;
    }
    part def checkpoint_suffix {
        attribute displayName : String = "Retained WAL suffix";
        attribute responsibility : String = "Exact replay coverage";
        attribute glyph : String = "history";
        port incoming : ~BoundRecordPort;
        port outgoing : BoundRecordPort;
    }
    part def checkpoint_equivalence {
        attribute displayName : String = "Current equivalence";
        attribute responsibility : String = "Read back and compare";
        attribute glyph : String = "policy";
        port incoming : ~BoundRecordPort;
        port outgoing : BoundRecordPort;
    }
    part def checkpoint_prune {
        attribute displayName : String = "Local WAL pruning";
        attribute responsibility : String = "Keep protected history";
        attribute glyph : String = "writer";
        port incoming : ~BoundRecordPort;
        port outgoing : BoundRecordPort;
    }
    part checkpointBoundary {
        part body : checkpoint_body;
        part publishRecord : checkpoint_publishRecord;
        part suffix : checkpoint_suffix;
        part equivalence : checkpoint_equivalence;
        part prune : checkpoint_prune;
        connection retainBody connect body.outgoing to publishRecord.incoming;
        connection readCurrent connect publishRecord.outgoing to equivalence.incoming;
        connection reconstruct connect suffix.outgoing to equivalence.incoming;
        connection allowDeletion connect equivalence.outgoing to prune.incoming;
    }
    view checkpoint {
        attribute mappedFile : String = "docs/20-29-execution-authority/26-checkpoint-truncation/26.02-checkpoint-truncation.d2";
        attribute displayTitle : String = "Publish the full checkpoint before pruning";
        attribute displaySubtitle : String = "Pruning local bytes performs no financial transaction.";
        attribute displayEyebrow : String = "WEAVER / EXECUTION AND ACCOUNT AUTHORITY";
        attribute readerQuestion : String = "What must be proved before deleting old WAL bytes?";
        attribute designAudience : String = "Gateway runtime reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "Pruning local bytes performs no financial transaction.";
        attribute designFocus : String = "prune";
        attribute visualThemes : String = "sketchbook,field-notes,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose checkpointBoundary::body;
        expose checkpointBoundary::publishRecord;
        expose checkpointBoundary::suffix;
        expose checkpointBoundary::equivalence;
        expose checkpointBoundary::prune;
        expose checkpointBoundary::retainBody;
        expose checkpointBoundary::readCurrent;
        expose checkpointBoundary::reconstruct;
        expose checkpointBoundary::allowDeletion;
        render asInterconnectionDiagram;
    }

    part def manifestSwitch_oldRoot {
        attribute displayName : String = "Current manifest";
        attribute responsibility : String = "Keep complete old path";
        attribute glyph : String = "history";
        port incoming : ~BoundRecordPort;
        port outgoing : BoundRecordPort;
    }
    part def manifestSwitch_candidate {
        attribute displayName : String = "Candidate manifest";
        attribute responsibility : String = "Exact checkpoint and suffix";
        attribute glyph : String = "ledger";
        port incoming : ~BoundRecordPort;
        port outgoing : BoundRecordPort;
    }
    part def manifestSwitch_switchRoot {
        attribute displayName : String = "Authoritative switch";
        attribute responsibility : String = "Compare original parent";
        attribute glyph : String = "publication";
        port incoming : ~BoundRecordPort;
        port outgoing : BoundRecordPort;
    }
    part def manifestSwitch_known {
        attribute displayName : String = "Current readback";
        attribute responsibility : String = "Verify new path before prune";
        attribute glyph : String = "policy";
        port incoming : ~BoundRecordPort;
        port outgoing : BoundRecordPort;
    }
    part def manifestSwitch_unknownRoot {
        attribute displayName : String = "Unknown switch";
        attribute responsibility : String = "Keep both paths";
        attribute glyph : String = "unknown";
        port incoming : ~BoundRecordPort;
        port outgoing : BoundRecordPort;
    }
    part manifestSwitchBoundary {
        part oldRoot : manifestSwitch_oldRoot;
        part candidate : manifestSwitch_candidate;
        part switchRoot : manifestSwitch_switchRoot;
        part known : manifestSwitch_known;
        part unknownRoot : manifestSwitch_unknownRoot;
        connection compareParent connect oldRoot.outgoing to switchRoot.incoming;
        connection stage connect candidate.outgoing to switchRoot.incoming;
        connection committed connect switchRoot.outgoing to known.incoming;
        connection unresolved connect switchRoot.outgoing to unknownRoot.incoming;
    }
    view manifestSwitch {
        attribute mappedFile : String = "docs/20-29-execution-authority/27-manifest-switch/27.02-manifest-switch.d2";
        attribute displayTitle : String = "Keep both paths until switch is known";
        attribute displaySubtitle : String = "A successful local rename does not authorize deletion.";
        attribute displayEyebrow : String = "WEAVER / EXECUTION AND ACCOUNT AUTHORITY";
        attribute readerQuestion : String = "Which reconstruction path survives a lost switch reply?";
        attribute designAudience : String = "Gateway runtime reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "A successful local rename does not authorize deletion.";
        attribute designFocus : String = "switchRoot";
        attribute visualThemes : String = "sketchbook,ember,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose manifestSwitchBoundary::oldRoot;
        expose manifestSwitchBoundary::candidate;
        expose manifestSwitchBoundary::switchRoot;
        expose manifestSwitchBoundary::known;
        expose manifestSwitchBoundary::unknownRoot;
        expose manifestSwitchBoundary::compareParent;
        expose manifestSwitchBoundary::stage;
        expose manifestSwitchBoundary::committed;
        expose manifestSwitchBoundary::unresolved;
        render asInterconnectionDiagram;
    }

    part def appendHandoff_base {
        attribute displayName : String = "Immutable base";
        attribute responsibility : String = "Current parent manifest";
        attribute glyph : String = "history";
        port incoming : ~BoundRecordPort;
        port outgoing : BoundRecordPort;
    }
    part def appendHandoff_captured {
        attribute displayName : String = "Closed segments";
        attribute responsibility : String = "Exact cut prefix";
        attribute glyph : String = "ledger";
        port incoming : ~BoundRecordPort;
        port outgoing : BoundRecordPort;
    }
    part def appendHandoff_liveTail {
        attribute displayName : String = "Live generation";
        attribute responsibility : String = "Carry recent append data";
        attribute glyph : String = "stream";
        port incoming : ~BoundRecordPort;
        port outgoing : BoundRecordPort;
    }
    part def appendHandoff_handoff {
        attribute displayName : String = "Manifest handoff";
        attribute responsibility : String = "Keep the original lineage";
        attribute glyph : String = "publication";
        port incoming : ~BoundRecordPort;
        port outgoing : BoundRecordPort;
    }
    part def appendHandoff_nextRoot {
        attribute displayName : String = "New reconstruction";
        attribute responsibility : String = "Compacted base and tail";
        attribute glyph : String = "recovery";
        port incoming : ~BoundRecordPort;
        port outgoing : BoundRecordPort;
    }
    part appendHandoffBoundary {
        part base : appendHandoff_base;
        part captured : appendHandoff_captured;
        part liveTail : appendHandoff_liveTail;
        part handoff : appendHandoff_handoff;
        part nextRoot : appendHandoff_nextRoot;
        connection compareParent connect base.outgoing to handoff.incoming;
        connection compactCut connect captured.outgoing to handoff.incoming;
        connection carryTail connect liveTail.outgoing to handoff.incoming;
        connection publish connect handoff.outgoing to nextRoot.incoming;
    }
    view appendHandoff {
        attribute mappedFile : String = "docs/20-29-execution-authority/28-append-handoff/28.02-append-handoff.d2";
        attribute displayTitle : String = "Compact the cut and carry live appends";
        attribute displaySubtitle : String = "The new manifest carries the same original obligations.";
        attribute displayEyebrow : String = "WEAVER / EXECUTION AND ACCOUNT AUTHORITY";
        attribute readerQuestion : String = "What happens to live appends during compaction?";
        attribute designAudience : String = "Gateway runtime reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "The new manifest carries the same original obligations.";
        attribute designFocus : String = "handoff";
        attribute visualThemes : String = "sketchbook,ocean,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose appendHandoffBoundary::base;
        expose appendHandoffBoundary::captured;
        expose appendHandoffBoundary::liveTail;
        expose appendHandoffBoundary::handoff;
        expose appendHandoffBoundary::nextRoot;
        expose appendHandoffBoundary::compareParent;
        expose appendHandoffBoundary::compactCut;
        expose appendHandoffBoundary::carryTail;
        expose appendHandoffBoundary::publish;
        render asInterconnectionDiagram;
    }

    part def admissionFloor_appendBody {
        attribute displayName : String = "Durable append body";
        attribute responsibility : String = "Retain exact original data";
        attribute glyph : String = "ledger";
        port incoming : ~BoundRecordPort;
        port outgoing : BoundRecordPort;
    }
    part def admissionFloor_floor {
        attribute displayName : String = "Protected floor";
        attribute responsibility : String = "Publish original admission";
        attribute glyph : String = "publication";
        port incoming : ~BoundRecordPort;
        port outgoing : BoundRecordPort;
    }
    part def admissionFloor_localView {
        attribute displayName : String = "Restored local view";
        attribute responsibility : String = "May omit pending tail";
        attribute glyph : String = "unknown";
        port incoming : ~BoundRecordPort;
        port outgoing : BoundRecordPort;
    }
    part def admissionFloor_recover {
        attribute displayName : String = "Current recovery join";
        attribute responsibility : String = "Compare floor and owner";
        attribute glyph : String = "authorization";
        port incoming : ~BoundRecordPort;
        port outgoing : BoundRecordPort;
    }
    part def admissionFloor_continueWork {
        attribute displayName : String = "Recover original tail";
        attribute responsibility : String = "Keep lineage and holds";
        attribute glyph : String = "recovery";
        port incoming : ~BoundRecordPort;
        port outgoing : BoundRecordPort;
    }
    part admissionFloorBoundary {
        part appendBody : admissionFloor_appendBody;
        part floor : admissionFloor_floor;
        part localView : admissionFloor_localView;
        part recover : admissionFloor_recover;
        part continueWork : admissionFloor_continueWork;
        connection publish connect appendBody.outgoing to floor.incoming;
        connection currentFloor connect floor.outgoing to recover.incoming;
        connection checkSnapshot connect localView.outgoing to recover.incoming;
        connection admitOriginal connect recover.outgoing to continueWork.incoming;
    }
    view admissionFloor {
        attribute mappedFile : String = "docs/20-29-execution-authority/29-admission-floor/29.02-admission-floor.d2";
        attribute displayTitle : String = "Recover the independent admission floor";
        attribute displaySubtitle : String = "A local manifest cannot stand in for the original control log.";
        attribute displayEyebrow : String = "WEAVER / EXECUTION AND ACCOUNT AUTHORITY";
        attribute readerQuestion : String = "How can recovery detect an omitted pending tail?";
        attribute designAudience : String = "Gateway runtime reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "A local manifest cannot stand in for the original control log.";
        attribute designFocus : String = "floor";
        attribute visualThemes : String = "sketchbook,blueprint,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose admissionFloorBoundary::appendBody;
        expose admissionFloorBoundary::floor;
        expose admissionFloorBoundary::localView;
        expose admissionFloorBoundary::recover;
        expose admissionFloorBoundary::continueWork;
        expose admissionFloorBoundary::publish;
        expose admissionFloorBoundary::currentFloor;
        expose admissionFloorBoundary::checkSnapshot;
        expose admissionFloorBoundary::admitOriginal;
        render asInterconnectionDiagram;
    }
}
