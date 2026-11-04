// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package WeaverFloorReaderViews {
    private import ScalarValues::*;
    private import Views::*;
    private import StandardViewDefinitions::*;
    doc /* Evidence relationships for the conditional protected floor design.
       The subjects describe durable facts and checks rather than services. */
    item def Evidence;
    port def EvidencePort { out item value : Evidence; }
    requirement def OriginalFloorDecision {
        doc /* The original immutable intent remains held until its exact committed
           decision is observed. Historical commitment does not qualify current use. */
    }

    part def floorOrdering_intent {
        attribute displayName : String = "Accepted intent";
        attribute responsibility : String = "Original cut stays bound";
        attribute glyph : String = "claim";
        port incoming : ~EvidencePort;
        port outgoing : EvidencePort;
    }
    part def floorOrdering_fence {
        attribute displayName : String = "Context fence";
        attribute responsibility : String = "Orders against commit";
        attribute glyph : String = "authorization";
        port incoming : ~EvidencePort;
        port outgoing : EvidencePort;
    }
    part def floorOrdering_ordering {
        attribute displayName : String = "Durable decision";
        attribute responsibility : String = "One authoritative image";
        attribute glyph : String = "ledger";
        port incoming : ~EvidencePort;
        port outgoing : EvidencePort;
    }
    part def floorOrdering_committed {
        attribute displayName : String = "Commit won";
        attribute responsibility : String = "Preserve exact outcome";
        attribute glyph : String = "history";
        port incoming : ~EvidencePort;
        port outgoing : EvidencePort;
    }
    part def floorOrdering_held {
        attribute displayName : String = "Fence won";
        attribute responsibility : String = "Retain the original hold";
        attribute glyph : String = "unknown";
        port incoming : ~EvidencePort;
        port outgoing : EvidencePort;
    }
    part floorOrderingFacts {
        part intent : floorOrdering_intent;
        part fence : floorOrdering_fence;
        part ordering : floorOrdering_ordering;
        part committed : floorOrdering_committed;
        part held : floorOrdering_held;
        connection exactIntent connect intent.outgoing to ordering.incoming;
        connection serialize connect fence.outgoing to ordering.incoming;
        connection commitFirst connect ordering.outgoing to committed.incoming;
        connection fenceFirst connect ordering.outgoing to held.incoming;
    }
    view floorOrdering {
        attribute mappedFile : String = "docs/30-39-assurance/34-floor-decision/34.02-floor-decision.d2";
        attribute displayTitle : String = "Order commit and reset";
        attribute displaySubtitle : String = "The durable deciding image records which transition won.";
        attribute displayEyebrow : String = "WEAVER / RECOVERY DESIGN";
        attribute readerQuestion : String = "Which operation wins the original intent?";
        attribute designAudience : String = "Recovery reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "The durable deciding image records which transition won.";
        attribute designFocus : String = "ordering";
        attribute visualThemes : String = "sketchbook,ember,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"18\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"32\"}";
        attribute visualWidth : Integer = 980;
        requirement decision : OriginalFloorDecision;
        expose floorOrderingFacts::intent;
        expose floorOrderingFacts::fence;
        expose floorOrderingFacts::ordering;
        expose floorOrderingFacts::committed;
        expose floorOrderingFacts::held;
        expose floorOrderingFacts::exactIntent;
        expose floorOrderingFacts::serialize;
        expose floorOrderingFacts::commitFirst;
        expose floorOrderingFacts::fenceFirst;
        render asInterconnectionDiagram;
    }

    part def floorRecovery_readback {
        attribute displayName : String = "Exact readback";
        attribute responsibility : String = "Current recovery session";
        attribute glyph : String = "recovery";
        port incoming : ~EvidencePort;
        port outgoing : EvidencePort;
    }
    part def floorRecovery_slot {
        attribute displayName : String = "Original slot";
        attribute responsibility : String = "Acknowledge that commit";
        attribute glyph : String = "ledger";
        port incoming : ~EvidencePort;
        port outgoing : EvidencePort;
    }
    part def floorRecovery_current {
        attribute displayName : String = "Current cut";
        attribute responsibility : String = "Check floor and Policy";
        attribute glyph : String = "policy";
        port incoming : ~EvidencePort;
        port outgoing : EvidencePort;
    }
    part def floorRecovery_recheck {
        attribute displayName : String = "Final-use guard";
        attribute responsibility : String = "Fence each actual effect";
        attribute glyph : String = "authorization";
        port incoming : ~EvidencePort;
        port outgoing : EvidencePort;
    }
    part floorRecoveryFacts {
        part readback : floorRecovery_readback;
        part slot : floorRecovery_slot;
        part current : floorRecovery_current;
        part recheck : floorRecovery_recheck;
        connection acknowledge connect readback.outgoing to slot.incoming;
        connection freshCheck connect current.outgoing to recheck.incoming;
        connection historicalOnly connect readback.outgoing to recheck.incoming;
    }
    view floorRecovery {
        attribute mappedFile : String = "docs/30-39-assurance/34-floor-decision/34.04-floor-recovery.d2";
        attribute displayTitle : String = "Read back, then qualify";
        attribute displaySubtitle : String = "An old commit resolves its own slot. The current release needs a fresh check.";
        attribute displayEyebrow : String = "WEAVER / RECOVERY DESIGN";
        attribute readerQuestion : String = "When may an old decision affect a new session?";
        attribute designAudience : String = "Recovery reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "An old commit resolves its own slot. The current release needs a fresh check.";
        attribute designFocus : String = "recheck";
        attribute visualThemes : String = "sketchbook,blueprint,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"18\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"32\"}";
        attribute visualWidth : Integer = 980;
        requirement decision : OriginalFloorDecision;
        expose floorRecoveryFacts::readback;
        expose floorRecoveryFacts::slot;
        expose floorRecoveryFacts::current;
        expose floorRecoveryFacts::recheck;
        expose floorRecoveryFacts::acknowledge;
        expose floorRecoveryFacts::freshCheck;
        expose floorRecoveryFacts::historicalOnly;
        render asInterconnectionDiagram;
    }
}
