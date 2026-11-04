// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package WeaverReaderDesigns {
    private import ScalarValues::*;
    doc /* Presentation values, not runtime services. D2 retains the exact
       legacy protocol observations. These source declarations control the
       Library's reading measure and grammar without flattening ownership. */
    part def ReaderDesign {
        attribute audience : String = "Gateway readers";
        attribute medium : String = "GitHub document at 830 CSS pixels";
        attribute width : Integer = 1120;
        attribute textColumns : Integer = 22;
        attribute componentPacking : String = "stack";
        attribute themes : String = "sketchbook,comfortable,reading";
    }
    part system : ReaderDesign {
        attribute 'message' : String = "Read responsibilities inside their ownership boundaries.";
        attribute options : String = "{\"elk.direction\":\"DOWN\",\"elk.hierarchyHandling\":\"INCLUDE_CHILDREN\",\"elk.spacing.nodeNode\":\"24\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"40\"}";
    }
    part routing : ReaderDesign {
        attribute 'message' : String = "Compare eligible paths; a proposed route does not grant execution.";
        attribute themes : String = "sketchbook,ocean,comfortable,reading";
        attribute options : String = "{\"elk.direction\":\"DOWN\",\"elk.hierarchyHandling\":\"INCLUDE_CHILDREN\",\"elk.layered.nodePlacement.strategy\":\"BRANDES_KOEPF\",\"elk.spacing.nodeNode\":\"20\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"36\"}";
    }
    part 'flow' : ReaderDesign {
        attribute 'message' : String = "Follow the original intent through current checks and durable outcomes.";
        attribute themes : String = "sketchbook,blueprint,comfortable,reading";
        attribute options : String = "{\"elk.direction\":\"DOWN\",\"elk.hierarchyHandling\":\"INCLUDE_CHILDREN\",\"elk.layered.nodePlacement.strategy\":\"NETWORK_SIMPLEX\",\"elk.spacing.nodeNode\":\"20\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"36\"}";
    }
    part 'state' : ReaderDesign {
        attribute 'message' : String = "Distinguish committed state, conditional recovery and unresolved exposure.";
        attribute themes : String = "sketchbook,ember,comfortable,reading";
        attribute options : String = "{\"elk.direction\":\"DOWN\",\"elk.hierarchyHandling\":\"INCLUDE_CHILDREN\",\"elk.layered.cycleBreaking.strategy\":\"GREEDY\",\"elk.spacing.nodeNode\":\"24\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"44\"}";
    }
    part data : ReaderDesign {
        attribute 'message' : String = "Read record ownership and atomic joins before recovery projections.";
        attribute themes : String = "sketchbook,blueprint,comfortable,reading";
        attribute options : String = "{\"elk.direction\":\"DOWN\",\"elk.hierarchyHandling\":\"INCLUDE_CHILDREN\",\"elk.layered.considerModelOrder.strategy\":\"NODES_AND_EDGES\",\"elk.spacing.nodeNode\":\"24\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"44\"}";
    }
    part assurance : ReaderDesign {
        attribute 'message' : String = "Separate a contract, its premises and its independent evidence.";
        attribute themes : String = "sketchbook,field-notes,comfortable,reading";
        attribute options : String = "{\"elk.direction\":\"DOWN\",\"elk.hierarchyHandling\":\"INCLUDE_CHILDREN\",\"elk.spacing.nodeNode\":\"24\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"40\"}";
    }
}
