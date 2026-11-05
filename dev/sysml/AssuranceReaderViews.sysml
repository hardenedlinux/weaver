// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package WeaverAssuranceReaderViews {
    private import ScalarValues::*;
    private import Views::*;
    private import StandardViewDefinitions::*;
    doc /* Reader projections of conditional assurance designs. These facts do
       not create hardware requirements for the Gateway's software boundary. */
    item def Evidence;
    port def EvidencePort { out item value : Evidence; }
    part def ReaderNode {
        port incoming : ~EvidencePort;
        port outgoing : EvidencePort;
    }
    part def signer_request :> ReaderNode {
        attribute displayName : String = "Immutable request";
        attribute responsibility : String = "Bind original statement";
        attribute glyph : String = "claim";
    }
    part def signer_prefix :> ReaderNode {
        attribute displayName : String = "Protected prefix";
        attribute responsibility : String = "Commit row and promise";
        attribute glyph : String = "ledger";
    }
    part def signer_session :> ReaderNode {
        attribute displayName : String = "Current key session";
        attribute responsibility : String = "Check live authority";
        attribute glyph : String = "authentication";
    }
    part def signer_releaseGate :> ReaderNode {
        attribute displayName : String = "Signature release";
        attribute responsibility : String = "Join exact commit and key";
        attribute glyph : String = "authorization";
    }
    part def signer_readback :> ReaderNode {
        attribute displayName : String = "Unknown reply";
        attribute responsibility : String = "Resolve against the owner";
        attribute glyph : String = "recovery";
    }
    part signerBoundary {
        part p_request : signer_request;
        part p_prefix : signer_prefix;
        part p_session : signer_session;
        part p_releaseGate : signer_releaseGate;
        part p_readback : signer_readback;
        connection commit connect p_request.outgoing to p_prefix.incoming;
        connection bindCommit connect p_prefix.outgoing to p_releaseGate.incoming;
        connection checkSession connect p_session.outgoing to p_releaseGate.incoming;
        connection resolve connect p_readback.outgoing to p_prefix.incoming;
    }
    view signer {
        attribute mappedFile : String = "docs/30-39-assurance/31-protected-signer/31.02-protected-signer.d2";
        attribute displayTitle : String = "Commit the statement before release";
        attribute displaySubtitle : String = "A current signing session must match the exact protected commit.";
        attribute displayEyebrow : String = "WEAVER / ASSURANCE BOUNDARY";
        attribute readerQuestion : String = "What authorizes release at the actual key boundary?";
        attribute designAudience : String = "Assurance reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "A current signing session must match the exact protected commit.";
        attribute designFocus : String = "p_releaseGate";
        attribute visualThemes : String = "sketchbook,ember,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose signerBoundary::p_request;
        expose signerBoundary::p_prefix;
        expose signerBoundary::p_session;
        expose signerBoundary::p_releaseGate;
        expose signerBoundary::p_readback;
        expose signerBoundary::commit;
        expose signerBoundary::bindCommit;
        expose signerBoundary::checkSession;
        expose signerBoundary::resolve;
        render asInterconnectionDiagram;
    }

    part def keySession_oldWork :> ReaderNode {
        attribute displayName : String = "Old work";
        attribute responsibility : String = "Queued and running jobs";
        attribute glyph : String = "message";
    }
    part def keySession_closePath :> ReaderNode {
        attribute displayName : String = "Close key boundary";
        attribute responsibility : String = "Qualify old output paths";
        attribute glyph : String = "authorization";
    }
    part def keySession_epoch :> ReaderNode {
        attribute displayName : String = "Protected successor";
        attribute responsibility : String = "Commit and observe epoch";
        attribute glyph : String = "ledger";
    }
    part def keySession_emit :> ReaderNode {
        attribute displayName : String = "Actual emission";
        attribute responsibility : String = "Verify live handle";
        attribute glyph : String = "writer";
    }
    part keySessionBoundary {
        part p_oldWork : keySession_oldWork;
        part p_closePath : keySession_closePath;
        part p_epoch : keySession_epoch;
        part p_emit : keySession_emit;
        connection retire connect p_oldWork.outgoing to p_closePath.incoming;
        connection qualify connect p_closePath.outgoing to p_epoch.incoming;
        connection recheck connect p_epoch.outgoing to p_emit.incoming;
    }
    view keySession {
        attribute mappedFile : String = "docs/30-39-assurance/32-key-boundary/32.02-key-boundary.d2";
        attribute displayTitle : String = "Close the old output path";
        attribute displaySubtitle : String = "Queue clearing cannot qualify a successor key epoch.";
        attribute displayEyebrow : String = "WEAVER / ASSURANCE BOUNDARY";
        attribute readerQuestion : String = "Can queued work survive a revoked signing session?";
        attribute designAudience : String = "Assurance reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "Queue clearing cannot qualify a successor key epoch.";
        attribute designFocus : String = "p_emit";
        attribute visualThemes : String = "sketchbook,blueprint,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose keySessionBoundary::p_oldWork;
        expose keySessionBoundary::p_closePath;
        expose keySessionBoundary::p_epoch;
        expose keySessionBoundary::p_emit;
        expose keySessionBoundary::retire;
        expose keySessionBoundary::qualify;
        expose keySessionBoundary::recheck;
        render asInterconnectionDiagram;
    }

    part def deviceEvidence_history :> ReaderNode {
        attribute displayName : String = "Historical receipt";
        attribute responsibility : String = "Keep original commit";
        attribute glyph : String = "history";
    }
    part def deviceEvidence_floor :> ReaderNode {
        attribute displayName : String = "Protected floor";
        attribute responsibility : String = "Recover complete prefix";
        attribute glyph : String = "ledger";
    }
    part def deviceEvidence_fresh :> ReaderNode {
        attribute displayName : String = "Fresh isolation";
        attribute responsibility : String = "Current device and output";
        attribute glyph : String = "authentication";
    }
    part def deviceEvidence_activate :> ReaderNode {
        attribute displayName : String = "Current activation";
        attribute responsibility : String = "Join floor and evidence";
        attribute glyph : String = "authorization";
    }
    part deviceEvidenceBoundary {
        part p_history : deviceEvidence_history;
        part p_floor : deviceEvidence_floor;
        part p_fresh : deviceEvidence_fresh;
        part p_activate : deviceEvidence_activate;
        connection recover connect p_history.outgoing to p_floor.incoming;
        connection currentFloor connect p_floor.outgoing to p_activate.incoming;
        connection verifyFresh connect p_fresh.outgoing to p_activate.incoming;
    }
    view deviceEvidence {
        attribute mappedFile : String = "docs/30-39-assurance/33-device-isolation/33.02-device-isolation.d2";
        attribute displayTitle : String = "Separate history from fresh qualification";
        attribute displaySubtitle : String = "Recover the durable prefix and qualify the current device separately.";
        attribute displayEyebrow : String = "WEAVER / ASSURANCE BOUNDARY";
        attribute readerQuestion : String = "Can an old isolation receipt qualify a new device context?";
        attribute designAudience : String = "Assurance reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "Recover the durable prefix and qualify the current device separately.";
        attribute designFocus : String = "p_activate";
        attribute visualThemes : String = "sketchbook,field-notes,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose deviceEvidenceBoundary::p_history;
        expose deviceEvidenceBoundary::p_floor;
        expose deviceEvidenceBoundary::p_fresh;
        expose deviceEvidenceBoundary::p_activate;
        expose deviceEvidenceBoundary::recover;
        expose deviceEvidenceBoundary::currentFloor;
        expose deviceEvidenceBoundary::verifyFresh;
        render asInterconnectionDiagram;
    }

    part def continuation_original :> ReaderNode {
        attribute displayName : String = "Original root";
        attribute responsibility : String = "Keep claim and budget";
        attribute glyph : String = "claim";
    }
    part def continuation_oldAttempt :> ReaderNode {
        attribute displayName : String = "Fenced decision";
        attribute responsibility : String = "Retain original history";
        attribute glyph : String = "history";
    }
    part def continuation_fresh :> ReaderNode {
        attribute displayName : String = "Fresh attempt";
        attribute responsibility : String = "Bind new evidence";
        attribute glyph : String = "recovery";
    }
    part def continuation_rootCAS :> ReaderNode {
        attribute displayName : String = "One root commit";
        attribute responsibility : String = "Compare exact authority";
        attribute glyph : String = "ledger";
    }
    part def continuation_effect :> ReaderNode {
        attribute displayName : String = "Guarded effect";
        attribute responsibility : String = "Use current Rust owner";
        attribute glyph : String = "authorization";
    }
    part continuationBoundary {
        part p_original : continuation_original;
        part p_oldAttempt : continuation_oldAttempt;
        part p_fresh : continuation_fresh;
        part p_rootCAS : continuation_rootCAS;
        part p_effect : continuation_effect;
        connection bindOriginal connect p_original.outgoing to p_rootCAS.incoming;
        connection continueFresh connect p_oldAttempt.outgoing to p_fresh.incoming;
        connection qualify connect p_fresh.outgoing to p_rootCAS.incoming;
        connection checkUse connect p_rootCAS.outgoing to p_effect.incoming;
    }
    view continuation {
        attribute mappedFile : String = "docs/30-39-assurance/35-intent-continuation/35.02-intent-continuation.d2";
        attribute displayTitle : String = "Continue the same root";
        attribute displaySubtitle : String = "A new physical attempt preserves the original obligation and unknown exposure.";
        attribute displayEyebrow : String = "WEAVER / ASSURANCE BOUNDARY";
        attribute readerQuestion : String = "How can a fenced attempt resume without inventing a new claim?";
        attribute designAudience : String = "Assurance reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "A new physical attempt preserves the original obligation and unknown exposure.";
        attribute designFocus : String = "p_rootCAS";
        attribute visualThemes : String = "sketchbook,ocean,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose continuationBoundary::p_original;
        expose continuationBoundary::p_oldAttempt;
        expose continuationBoundary::p_fresh;
        expose continuationBoundary::p_rootCAS;
        expose continuationBoundary::p_effect;
        expose continuationBoundary::bindOriginal;
        expose continuationBoundary::continueFresh;
        expose continuationBoundary::qualify;
        expose continuationBoundary::checkUse;
        render asInterconnectionDiagram;
    }

    part def gatewayHead_observed :> ReaderNode {
        attribute displayName : String = "Observed head";
        attribute responsibility : String = "Authority observation";
        attribute glyph : String = "history";
    }
    part def gatewayHead_root :> ReaderNode {
        attribute displayName : String = "Original root";
        attribute responsibility : String = "Keep profile and scope";
        attribute glyph : String = "claim";
    }
    part def gatewayHead_current :> ReaderNode {
        attribute displayName : String = "Current fence";
        attribute responsibility : String = "Owner and authority head";
        attribute glyph : String = "authorization";
    }
    part def gatewayHead_rootCAS :> ReaderNode {
        attribute displayName : String = "Root CAS";
        attribute responsibility : String = "Compare exact current state";
        attribute glyph : String = "ledger";
    }
    part def gatewayHead_blocked :> ReaderNode {
        attribute displayName : String = "Stale attempt";
        attribute responsibility : String = "Refuse or reread";
        attribute glyph : String = "unknown";
    }
    part gatewayHeadBoundary {
        part p_observed : gatewayHead_observed;
        part p_root : gatewayHead_root;
        part p_current : gatewayHead_current;
        part p_rootCAS : gatewayHead_rootCAS;
        part p_blocked : gatewayHead_blocked;
        connection joinRead connect p_observed.outgoing to p_rootCAS.incoming;
        connection bindOriginal connect p_root.outgoing to p_rootCAS.incoming;
        connection compare connect p_current.outgoing to p_rootCAS.incoming;
        connection stale connect p_rootCAS.outgoing to p_blocked.incoming;
    }
    view gatewayHead {
        attribute mappedFile : String = "docs/30-39-assurance/36-gateway-head-cas/36.02-gateway-head-cas.d2";
        attribute displayTitle : String = "Compare the current authority head";
        attribute displaySubtitle : String = "An earlier read cannot grant a later effect.";
        attribute displayEyebrow : String = "WEAVER / ASSURANCE BOUNDARY";
        attribute readerQuestion : String = "Which head must agree at original-root completion?";
        attribute designAudience : String = "Assurance reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "An earlier read cannot grant a later effect.";
        attribute designFocus : String = "p_rootCAS";
        attribute visualThemes : String = "sketchbook,blueprint,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose gatewayHeadBoundary::p_observed;
        expose gatewayHeadBoundary::p_root;
        expose gatewayHeadBoundary::p_current;
        expose gatewayHeadBoundary::p_rootCAS;
        expose gatewayHeadBoundary::p_blocked;
        expose gatewayHeadBoundary::joinRead;
        expose gatewayHeadBoundary::bindOriginal;
        expose gatewayHeadBoundary::compare;
        expose gatewayHeadBoundary::stale;
        render asInterconnectionDiagram;
    }

    part def brokerQueue_consume :> ReaderNode {
        attribute displayName : String = "Durable consume";
        attribute responsibility : String = "Spend exact nonce";
        attribute glyph : String = "claim";
    }
    part def brokerQueue_queue :> ReaderNode {
        attribute displayName : String = "Queue accepted";
        attribute responsibility : String = "Retain original operation";
        attribute glyph : String = "ledger";
    }
    part def brokerQueue_write :> ReaderNode {
        attribute displayName : String = "Local write";
        attribute responsibility : String = "Actual invocation";
        attribute glyph : String = "writer";
    }
    part def brokerQueue_provider :> ReaderNode {
        attribute displayName : String = "Provider outcome";
        attribute responsibility : String = "Separate external evidence";
        attribute glyph : String = "provider";
    }
    part def brokerQueue_held :> ReaderNode {
        attribute displayName : String = "Unknown outcome";
        attribute responsibility : String = "Keep budget and history";
        attribute glyph : String = "unknown";
    }
    part brokerQueueBoundary {
        part p_consume : brokerQueue_consume;
        part p_queue : brokerQueue_queue;
        part p_write : brokerQueue_write;
        part p_provider : brokerQueue_provider;
        part p_held : brokerQueue_held;
        connection admitOnce connect p_consume.outgoing to p_queue.incoming;
        connection finalGate connect p_queue.outgoing to p_write.incoming;
        connection observe connect p_write.outgoing to p_provider.incoming;
        connection uncertain connect p_write.outgoing to p_held.incoming;
    }
    view brokerQueue {
        attribute mappedFile : String = "docs/30-39-assurance/37-broker-consumption-queue/37.02-broker-consumption-queue.d2";
        attribute displayTitle : String = "Keep consumption, queueing and sending separate";
        attribute displaySubtitle : String = "Unknown outcomes retain the original claim and reservation.";
        attribute displayEyebrow : String = "WEAVER / ASSURANCE BOUNDARY";
        attribute readerQuestion : String = "What does a spent nonce prove about sending?";
        attribute designAudience : String = "Assurance reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "Unknown outcomes retain the original claim and reservation.";
        attribute designFocus : String = "p_consume";
        attribute visualThemes : String = "sketchbook,ember,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose brokerQueueBoundary::p_consume;
        expose brokerQueueBoundary::p_queue;
        expose brokerQueueBoundary::p_write;
        expose brokerQueueBoundary::p_provider;
        expose brokerQueueBoundary::p_held;
        expose brokerQueueBoundary::admitOnce;
        expose brokerQueueBoundary::finalGate;
        expose brokerQueueBoundary::observe;
        expose brokerQueueBoundary::uncertain;
        render asInterconnectionDiagram;
    }

    part def rangeRecovery_range :> ReaderNode {
        attribute displayName : String = "Original range";
        attribute responsibility : String = "Manifest and dedup slot";
        attribute glyph : String = "stream";
    }
    part def rangeRecovery_spent :> ReaderNode {
        attribute displayName : String = "Durable progress";
        attribute responsibility : String = "Keep consumed prefix";
        attribute glyph : String = "ledger";
    }
    part def rangeRecovery_owner :> ReaderNode {
        attribute displayName : String = "Current owner";
        attribute responsibility : String = "Fresh epoch and fence";
        attribute glyph : String = "authentication";
    }
    part def rangeRecovery_guard :> ReaderNode {
        attribute displayName : String = "Next guarded write";
        attribute responsibility : String = "Same range, unsent suffix";
        attribute glyph : String = "authorization";
    }
    part def rangeRecovery_held :> ReaderNode {
        attribute displayName : String = "Unknown prefix";
        attribute responsibility : String = "Keep unresolved exposure";
        attribute glyph : String = "unknown";
    }
    part rangeRecoveryBoundary {
        part p_range : rangeRecovery_range;
        part p_spent : rangeRecovery_spent;
        part p_owner : rangeRecovery_owner;
        part p_guard : rangeRecovery_guard;
        part p_held : rangeRecovery_held;
        connection bindRange connect p_range.outgoing to p_guard.incoming;
        connection resumeKnown connect p_spent.outgoing to p_guard.incoming;
        connection recheck connect p_owner.outgoing to p_guard.incoming;
        connection retainUnknown connect p_spent.outgoing to p_held.incoming;
    }
    view rangeRecovery {
        attribute mappedFile : String = "docs/30-39-assurance/38-logical-range-recovery/38.02-logical-range-recovery.d2";
        attribute displayTitle : String = "Keep the range and renew authority";
        attribute displaySubtitle : String = "The range identity and worker epoch serve different purposes.";
        attribute displayEyebrow : String = "WEAVER / ASSURANCE BOUNDARY";
        attribute readerQuestion : String = "How can an old range continue under a fresh owner?";
        attribute designAudience : String = "Assurance reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "The range identity and worker epoch serve different purposes.";
        attribute designFocus : String = "p_guard";
        attribute visualThemes : String = "sketchbook,ocean,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose rangeRecoveryBoundary::p_range;
        expose rangeRecoveryBoundary::p_spent;
        expose rangeRecoveryBoundary::p_owner;
        expose rangeRecoveryBoundary::p_guard;
        expose rangeRecoveryBoundary::p_held;
        expose rangeRecoveryBoundary::bindRange;
        expose rangeRecoveryBoundary::resumeKnown;
        expose rangeRecoveryBoundary::recheck;
        expose rangeRecoveryBoundary::retainUnknown;
        render asInterconnectionDiagram;
    }
}
