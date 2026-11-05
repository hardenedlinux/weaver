// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package WeaverCorrespondenceReaderView {
    private import ScalarValues::*;
    private import Views::*;
    private import StandardViewDefinitions::*;
    doc /* Read each row across concrete events, Quint schedules and required
       Lean/evidence obligations. The relations record review correspondence.
       They do not certify a runtime refinement. */
    item def Correspondence;
    port def CorrespondencePort { out item value : Correspondence; }
    part def consumeEventRole {
        attribute displayName : String = "Consume grant";
        attribute responsibility : String = "Reply may be lost";
        attribute glyph : String = "claim";
        port incoming : ~CorrespondencePort;
        port outgoing : CorrespondencePort;
    }
    part def consumeScheduleRole {
        attribute displayName : String = "Consume applied";
        attribute responsibility : String = "Track reply separately";
        attribute glyph : String = "history";
        port incoming : ~CorrespondencePort;
        port outgoing : CorrespondencePort;
    }
    part def consumeEvidenceRole {
        attribute displayName : String = "Keep original claim";
        attribute responsibility : String = "No duplicate consume";
        attribute glyph : String = "policy";
        port incoming : ~CorrespondencePort;
        port outgoing : CorrespondencePort;
    }
    part def commitEventRole {
        attribute displayName : String = "Commit ledger";
        attribute responsibility : String = "Authoritative CAS";
        attribute glyph : String = "ledger";
        port incoming : ~CorrespondencePort;
        port outgoing : CorrespondencePort;
    }
    part def commitScheduleRole {
        attribute displayName : String = "Send committed";
        attribute responsibility : String = "Abort may race";
        attribute glyph : String = "publication";
        port incoming : ~CorrespondencePort;
        port outgoing : CorrespondencePort;
    }
    part def commitEvidenceRole {
        attribute displayName : String = "Retain the hold";
        attribute responsibility : String = "No release on silence";
        attribute glyph : String = "budget";
        port incoming : ~CorrespondencePort;
        port outgoing : CorrespondencePort;
    }
    part def claimEventRole {
        attribute displayName : String = "Issue handle";
        attribute responsibility : String = "Bind durable claim";
        attribute glyph : String = "authorization";
        port incoming : ~CorrespondencePort;
        port outgoing : CorrespondencePort;
    }
    part def claimScheduleRole {
        attribute displayName : String = "Dispatch claimed";
        attribute responsibility : String = "At most one call";
        attribute glyph : String = "claim";
        port incoming : ~CorrespondencePort;
        port outgoing : CorrespondencePort;
    }
    part def claimEvidenceRole {
        attribute displayName : String = "Require custody";
        attribute responsibility : String = "No replayed handle";
        attribute glyph : String = "policy";
        port incoming : ~CorrespondencePort;
        port outgoing : CorrespondencePort;
    }
    part def sendEventRole {
        attribute displayName : String = "Enter transport";
        attribute responsibility : String = "Current final gate";
        attribute glyph : String = "writer";
        port incoming : ~CorrespondencePort;
        port outgoing : CorrespondencePort;
    }
    part def sendScheduleRole {
        attribute displayName : String = "Transport entry";
        attribute responsibility : String = "Old owner may resume";
        attribute glyph : String = "stream";
        port incoming : ~CorrespondencePort;
        port outgoing : CorrespondencePort;
    }
    part def sendEvidenceRole {
        attribute displayName : String = "Mediate actual bytes";
        attribute responsibility : String = "Fence stale owners";
        attribute glyph : String = "authorization";
        port incoming : ~CorrespondencePort;
        port outgoing : CorrespondencePort;
    }
    part def observeEventRole {
        attribute displayName : String = "Observe outcome";
        attribute responsibility : String = "Independent receipt";
        attribute glyph : String = "telemetry";
        port incoming : ~CorrespondencePort;
        port outgoing : CorrespondencePort;
    }
    part def observeScheduleRole {
        attribute displayName : String = "Observe result";
        attribute responsibility : String = "No atomic completion";
        attribute glyph : String = "history";
        port incoming : ~CorrespondencePort;
        port outgoing : CorrespondencePort;
    }
    part def observeEvidenceRole {
        attribute displayName : String = "Close with evidence";
        attribute responsibility : String = "Account for usage";
        attribute glyph : String = "ledger";
        port incoming : ~CorrespondencePort;
        port outgoing : CorrespondencePort;
    }

    part review {
        part consumeEvent : consumeEventRole;
        part consumeSchedule : consumeScheduleRole;
        part consumeEvidence : consumeEvidenceRole;
        part commitEvent : commitEventRole;
        part commitSchedule : commitScheduleRole;
        part commitEvidence : commitEvidenceRole;
        part claimEvent : claimEventRole;
        part claimSchedule : claimScheduleRole;
        part claimEvidence : claimEvidenceRole;
        part sendEvent : sendEventRole;
        part sendSchedule : sendScheduleRole;
        part sendEvidence : sendEvidenceRole;
        part observeEvent : observeEventRole;
        part observeSchedule : observeScheduleRole;
        part observeEvidence : observeEvidenceRole;
        connection consumeStep connect consumeEvent.outgoing to consumeSchedule.incoming;
        connection consumeLaw connect consumeSchedule.outgoing to consumeEvidence.incoming;
        connection commitStep connect commitEvent.outgoing to commitSchedule.incoming;
        connection commitLaw connect commitSchedule.outgoing to commitEvidence.incoming;
        connection commitBoundary connect consumeEvent.outgoing to commitEvent.incoming;
        connection claimStep connect claimEvent.outgoing to claimSchedule.incoming;
        connection claimLaw connect claimSchedule.outgoing to claimEvidence.incoming;
        connection claimBoundary connect commitEvent.outgoing to claimEvent.incoming;
        connection sendStep connect sendEvent.outgoing to sendSchedule.incoming;
        connection sendLaw connect sendSchedule.outgoing to sendEvidence.incoming;
        connection sendBoundary connect claimEvent.outgoing to sendEvent.incoming;
        connection observeStep connect observeEvent.outgoing to observeSchedule.incoming;
        connection observeLaw connect observeSchedule.outgoing to observeEvidence.incoming;
        connection observeBoundary connect sendEvent.outgoing to observeEvent.incoming;
    }

    view correspondence {
        attribute mappedFile : String = "docs/architecture/diagrams/12-execution-correspondence.d2";
        attribute displayTitle : String = "Follow each effect into its evidence";
        attribute displaySubtitle : String = "Concrete event, Quint schedule and Lean or physical evidence.";
        attribute displayEyebrow : String = "WEAVER / EXECUTION ASSURANCE";
        attribute readerQuestion : String = "What evidence belongs to each boundary?";
        attribute designAudience : String = "Runtime reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "Read left to right: runtime event, Quint schedule, evidence.";
        attribute designFocus : String = "sendEvent,sendEvidence";
        attribute visualThemes : String = "sketchbook,field-notes,compact,reading";
        attribute visualOptions : String = "{\"elk.direction\":\"DOWN\"}";
        attribute visualWidth : Integer = 980;
        attribute visualNotation : String = "objects";
        attribute visualBands : String = "[[\"consumeEvent\",\"consumeSchedule\",\"consumeEvidence\"],[\"commitEvent\",\"commitSchedule\",\"commitEvidence\"],[\"claimEvent\",\"claimSchedule\",\"claimEvidence\"],[\"sendEvent\",\"sendSchedule\",\"sendEvidence\"],[\"observeEvent\",\"observeSchedule\",\"observeEvidence\"]]";
        requirement actualUse : WeaverExecution::ConsumeBeforeSend;
        expose review::consumeEvent;
        expose review::consumeSchedule;
        expose review::consumeEvidence;
        expose review::commitEvent;
        expose review::commitSchedule;
        expose review::commitEvidence;
        expose review::claimEvent;
        expose review::claimSchedule;
        expose review::claimEvidence;
        expose review::sendEvent;
        expose review::sendSchedule;
        expose review::sendEvidence;
        expose review::observeEvent;
        expose review::observeSchedule;
        expose review::observeEvidence;
        expose review::consumeStep;
        expose review::consumeLaw;
        expose review::commitStep;
        expose review::commitLaw;
        expose review::commitBoundary;
        expose review::claimStep;
        expose review::claimLaw;
        expose review::claimBoundary;
        expose review::sendStep;
        expose review::sendLaw;
        expose review::sendBoundary;
        expose review::observeStep;
        expose review::observeLaw;
        expose review::observeBoundary;
        render asInterconnectionDiagram;
    }
}
