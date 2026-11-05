// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package WeaverGatewayArchitecture {
    private import ScalarValues::*;
    doc /* Product architecture projections. Parts are logical responsibilities,
       not additional deployable services. Existing Rust authority/broker and Go
       adapters realize them. Protocol and cloud breadth is a target surface;
       deployment and adapter completeness remain in the Org delivery map. */
    item def BoundWork;
    port def WorkPort { out item value : BoundWork; }

    part def ProtocolIngress {
        attribute journeyName : String = "Agent request";
        attribute journeySummary : String = "Keep task identity";
        attribute displayName : String = "Agent + protocol ingress";
        attribute responsibility : String = "LLM APIs / MCP / A2A / ACP\nAuthenticate and normalize\nPreserve task and message identity";
        attribute glyph : String = "agent";
        attribute visualRole : String = "selection";
        port request : WorkPort;
        port result : ~WorkPort;
    }
    part def RoutineProgram {
        attribute journeyName : String = "Routine";
        attribute journeySummary : String = "Required work";
        attribute displayName : String = "Routines + semantics";
        attribute responsibility : String = "Scheme / Agentic AI Lab\nTyped steps, tools and profiles\nJSON/YAML share owned contracts";
        attribute glyph : String = "routine";
        attribute visualRole : String = "semantic";
        port requirements : WorkPort;
        port observations : ~WorkPort;
    }
    part def ModelCatalog {
        attribute journeyName : String = "Model catalog";
        attribute journeySummary : String = "Capabilities + health";
        attribute displayName : String = "Model catalog + virtual models";
        attribute responsibility : String = "Alias to deployment bindings\nCapabilities, regions and quotas\nCurrent health observations";
        attribute glyph : String = "catalog";
        attribute visualRole : String = "selection";
        port bindings : WorkPort;
    }
    part def Routing {
        attribute journeyName : String = "Route proposal";
        attribute journeySummary : String = "Eligible bindings";
        attribute journeyGlyph : String = "route-choice";
        attribute displayName : String = "Go / routing + cloud";
        attribute responsibility : String = "Discovery and model capabilities\nEligible model/provider choices\nBound retry + fallback proposals";
        attribute glyph : String = "routing";
        attribute visualRole : String = "selection";
        port catalog : ~WorkPort;
        port intent : ~WorkPort;
        port requirements : ~WorkPort;
        port proposal : WorkPort;
    }
    part def ReviewedPublication {
        attribute journeyName : String = "Current Policy";
        attribute journeySummary : String = "Reviewed parent";
        attribute displayName : String = "Reviewed Policy publication";
        attribute responsibility : String = "SPEC-qualified Policy modules\nGo carries bound review evidence\nRust commits current Policy + parent";
        attribute glyph : String = "publication";
        attribute visualRole : String = "publication";
        doc /* A logical publication responsibility, not a new Gateway signer.
           The independent producer uses the SPEC Library. Deployment owns its
           verification public key and immutable qualified-catalogue reference. A signature alone cannot qualify NoGain. The Rust deciding transaction associates
           the current Policy with the approved original publication. */
        port policy : WorkPort;
    }
    part def RustExecution {
        attribute journeyName : String = "Actual-use gate";
        attribute journeySummary : String = "Claim + budget";
        attribute journeyGlyph : String = "permission-check";
        attribute displayName : String = "Rust broker / governed send";
        attribute responsibility : String = "Cedar + current reviewed Policy\nClaim + budget + writer seal\nFresh checks on every release";
        attribute glyph : String = "authorization";
        attribute visualRole : String = "execution";
        port policy : ~WorkPort;
        port proposal : ~WorkPort;
        port request : WorkPort;
    }
    part def ModelProviders {
        attribute journeyName : String = "Provider";
        attribute journeySummary : String = "One bound request";
        attribute journeyGlyph : String = "model-provider";
        attribute displayName : String = "LLM protocol adapters";
        attribute responsibility : String = "OpenAI-compatible + Anthropic Messages\nTarget-bound API key or WIF\nBuffered SSE with terminal usage";
        attribute glyph : String = "provider";
        attribute visualRole : String = "selection";
        port request : ~WorkPort;
        port response : WorkPort;
    }
    part def StreamLifecycle {
        attribute journeyName : String = "Stream result";
        attribute journeySummary : String = "Recheck each release";
        attribute displayName : String = "Stream + routine lifecycle";
        attribute responsibility : String = "Rust-to-Go authenticated gRPC\nBounded queues / optional Arrow\nReceipts advance original routine";
        attribute glyph : String = "stream";
        attribute visualRole : String = "execution";
        port response : ~WorkPort;
        port result : WorkPort;
        port observations : WorkPort;
    }
    part gateway {
        part ingress : ProtocolIngress;
        part routine : RoutineProgram;
        part catalog : ModelCatalog;
        part routing : Routing;
        part publication : ReviewedPublication;
        part execution : RustExecution;
        part providers : ModelProviders;
        part stream : StreamLifecycle;
        connection reviewed_policy connect publication.policy to execution.policy;
        connection input connect ingress.request to routing.intent;
        connection semantics connect routine.requirements to routing.requirements;
        connection catalogBindings connect catalog.bindings to routing.catalog;
        connection route connect routing.proposal to execution.proposal;
        connection invoke connect execution.request to providers.request;
        connection streamResult connect providers.response to stream.response;
        connection deliver connect stream.result to ingress.result;
        connection progress connect stream.observations to routine.observations;
    }
}
