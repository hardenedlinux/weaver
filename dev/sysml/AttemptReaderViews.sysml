// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package WeaverAttemptReaderViews {
    private import ScalarValues::*;
    private import Views::*;
    private import StandardViewDefinitions::*;
    doc /* Reader scopes for the documented original attempt lifecycle. The two
       scopes share the dispatch claim and separate authority from observation. */
    item def Transition;
    port def TransitionPort { out item value : Transition; }

    part def admission_proposed {
        attribute displayName : String = "Proposed";
        attribute responsibility : String = "Original task";
        attribute glyph : String = "message";
        port predecessor : ~TransitionPort;
        port successor : TransitionPort;
    }
    part def admission_prepared {
        attribute displayName : String = "Prepared";
        attribute responsibility : String = "Reserve the hold";
        attribute glyph : String = "budget";
        port predecessor : ~TransitionPort;
        port successor : TransitionPort;
    }
    part def admission_pending {
        attribute displayName : String = "Consume pending";
        attribute responsibility : String = "Persist exact command";
        attribute glyph : String = "ledger";
        port predecessor : ~TransitionPort;
        port successor : TransitionPort;
    }
    part def admission_consumed {
        attribute displayName : String = "Grant consumed";
        attribute responsibility : String = "Positive owner reply";
        attribute glyph : String = "claim";
        port predecessor : ~TransitionPort;
        port successor : TransitionPort;
    }
    part def admission_committed {
        attribute displayName : String = "Send committed";
        attribute responsibility : String = "Authoritative CAS";
        attribute glyph : String = "publication";
        port predecessor : ~TransitionPort;
        port successor : TransitionPort;
    }
    part def admission_claimed {
        attribute displayName : String = "Dispatch claimed";
        attribute responsibility : String = "Original claim stays spent";
        attribute glyph : String = "authorization";
        port predecessor : ~TransitionPort;
        port successor : TransitionPort;
    }
    part def admission_aborted {
        attribute displayName : String = "Aborted";
        attribute responsibility : String = "No dispatch tombstone";
        attribute glyph : String = "unknown";
        port predecessor : ~TransitionPort;
        port successor : TransitionPort;
    }
    part admissionStates {
        part proposed : admission_proposed;
        part prepared : admission_prepared;
        part pending : admission_pending;
        part consumed : admission_consumed;
        part committed : admission_committed;
        part claimed : admission_claimed;
        part aborted : admission_aborted;
        connection prepare connect proposed.successor to prepared.predecessor;
        connection persist connect prepared.successor to pending.predecessor;
        connection positiveReply connect pending.successor to consumed.predecessor;
        connection commitCAS connect consumed.successor to committed.predecessor;
        connection claimCAS connect committed.successor to claimed.predecessor;
        connection denyOrCancel connect prepared.successor to aborted.predecessor;
        connection abortWins connect pending.successor to aborted.predecessor;
        connection commitDenied connect consumed.successor to aborted.predecessor;
        connection claimAbsent connect committed.successor to aborted.predecessor;
    }
    view admission {
        attribute mappedFile : String = "docs/architecture/diagrams/03-attempt-state.d2";
        attribute displayTitle : String = "Claim once or close the attempt";
        attribute displaySubtitle : String = "The claim and abort race on durable state.";
        attribute displayEyebrow : String = "WEAVER / ATTEMPT LIFECYCLE";
        attribute readerQuestion : String = "When can an attempt acquire dispatch authority?";
        attribute designAudience : String = "Gateway runtime reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "The claim and abort race on durable state.";
        attribute designFocus : String = "claimed";
        attribute visualThemes : String = "sketchbook,ember,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose admissionStates::proposed;
        expose admissionStates::prepared;
        expose admissionStates::pending;
        expose admissionStates::consumed;
        expose admissionStates::committed;
        expose admissionStates::claimed;
        expose admissionStates::aborted;
        expose admissionStates::prepare;
        expose admissionStates::persist;
        expose admissionStates::positiveReply;
        expose admissionStates::commitCAS;
        expose admissionStates::claimCAS;
        expose admissionStates::denyOrCancel;
        expose admissionStates::abortWins;
        expose admissionStates::commitDenied;
        expose admissionStates::claimAbsent;
        render asInterconnectionDiagram;
    }

    part def outcome_claimed {
        attribute displayName : String = "Dispatch claimed";
        attribute responsibility : String = "Original claim stays spent";
        attribute glyph : String = "authorization";
        port predecessor : ~TransitionPort;
        port successor : TransitionPort;
    }
    part def outcome_unknown {
        attribute displayName : String = "Outcome unknown";
        attribute responsibility : String = "Keep uncertain exposure";
        attribute glyph : String = "unknown";
        port predecessor : ~TransitionPort;
        port successor : TransitionPort;
    }
    part def outcome_noSubmit {
        attribute displayName : String = "No submission proved";
        attribute responsibility : String = "Keep spent claim";
        attribute glyph : String = "claim";
        port predecessor : ~TransitionPort;
        port successor : TransitionPort;
    }
    part def outcome_reconcile {
        attribute displayName : String = "Scoped recovery";
        attribute responsibility : String = "Inspect and settle";
        attribute glyph : String = "recovery";
        port predecessor : ~TransitionPort;
        port successor : TransitionPort;
    }
    part def outcome_recorded {
        attribute displayName : String = "Result recorded";
        attribute responsibility : String = "Outcome evidence only";
        attribute glyph : String = "ledger";
        port predecessor : ~TransitionPort;
        port successor : TransitionPort;
    }
    part outcomeStates {
        part claimed : outcome_claimed;
        part unknown : outcome_unknown;
        part noSubmit : outcome_noSubmit;
        part reconcile : outcome_reconcile;
        part recorded : outcome_recorded;
        connection uncertain connect claimed.successor to unknown.predecessor;
        connection proofOfNoSend connect claimed.successor to noSubmit.predecessor;
        connection outcomeEvidence connect claimed.successor to recorded.predecessor;
        connection freshRecovery connect unknown.successor to reconcile.predecessor;
        connection freshCleanup connect noSubmit.successor to reconcile.predecessor;
        connection noResend connect reconcile.successor to recorded.predecessor;
    }
    view outcome {
        attribute mappedFile : String = "docs/architecture/diagrams/03a-attempt-observation.d2";
        attribute displayTitle : String = "Recover the outcome of a spent claim";
        attribute displaySubtitle : String = "Recovery admits evidence about the original claim.";
        attribute displayEyebrow : String = "WEAVER / ATTEMPT LIFECYCLE";
        attribute readerQuestion : String = "How is an existing claim reconciled?";
        attribute designAudience : String = "Gateway runtime reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "Recovery admits evidence about the original claim.";
        attribute designFocus : String = "unknown";
        attribute visualThemes : String = "sketchbook,ocean,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose outcomeStates::claimed;
        expose outcomeStates::unknown;
        expose outcomeStates::noSubmit;
        expose outcomeStates::reconcile;
        expose outcomeStates::recorded;
        expose outcomeStates::uncertain;
        expose outcomeStates::proofOfNoSend;
        expose outcomeStates::outcomeEvidence;
        expose outcomeStates::freshRecovery;
        expose outcomeStates::freshCleanup;
        expose outcomeStates::noResend;
        render asInterconnectionDiagram;
    }
}
