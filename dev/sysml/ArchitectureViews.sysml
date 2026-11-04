// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package WeaverViews {
    private import ScalarValues::*;
    private import Views::*;
    private import StandardViewDefinitions::*;

    view architecture {
        attribute visualBands : String = "[[\"semanticPublisher\",\"controlAdapter\"],[\"policy\",\"ledger\",\"broker\"],[\"executor\",\"provider\",\"telemetry\"]]";
        attribute visualBandTitles : String = "[\"Choose a provider within the original task\",\"Join permission, original claim and budget\",\"Control actual bytes and observe the result\"]";
        attribute visualBandIcons : String = "[\"routing\",\"authorization\",\"writer\"]";
        attribute exampleIllustration : String = "agent-request";
        attribute visualNotation : String = "objects";
        attribute captionContext : String = "overview";
        attribute designAudience : String = "Gateway readers";
        attribute designMedium : String = "GitHub README and linked English Org";
        attribute designMessage : String = "An agent summarizes a report.\nOriginal scope and budget stay bound.";
        attribute designFocus : String = "ledger,executor";
        attribute visualThemes : String = "sketchbook,ocean,comfortable,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"RIGHT\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"44\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"64\",\"elk.layered.wrapping.strategy\":\"MULTI_EDGE\",\"elk.aspectRatio\":\"1.15\",\"elk.separateConnectedComponents\":\"false\"}";
        attribute visualWidth : Integer = 1120;

        requirement specContract : WeaverZeroTrust::ZeroTrustContractRefinement;
        requirement executionContract : WeaverExecution::ConsumeBeforeSend;
        attribute mappedFile : String = "docs/architecture/diagrams/00a-readme-overview.d2";
        attribute displayTitle : String = "One agent task. Every effect stays accountable.";
        attribute displaySubtitle : String = "Scheme defines meaning. Go coordinates. Rust controls actual effects.";
        attribute readerQuestion : String = "What happens when your agent asks an LLM for help?";
        attribute displayEyebrow : String = "WEAVER / AGENT GATEWAY";
        expose WeaverExecution::gateway::semanticPublisher;
        expose WeaverExecution::gateway::controlAdapter;
        expose WeaverExecution::gateway::policy;
        expose WeaverExecution::gateway::ledger;
        expose WeaverExecution::gateway::broker;
        expose WeaverExecution::gateway::executor;
        expose WeaverExecution::gateway::provider;
        expose WeaverExecution::gateway::telemetry;
        expose WeaverExecution::gateway::proposeTask;
        expose WeaverExecution::gateway::proposeEffect;
        expose WeaverExecution::gateway::checkPolicy;
        expose WeaverExecution::gateway::consumedClaim;
        expose WeaverExecution::gateway::recheckUse;
        expose WeaverExecution::gateway::boundedWrite;
        render asInterconnectionDiagram;
    }

    view contractRefinement {
        attribute captionContext : String = "refinement";
        attribute designAudience : String = "Security reviewers";
        attribute designMedium : String = "GitHub README and linked English Org";
        attribute designMessage : String = "Trace the SPEC requirements into the same actual-use view.";
        attribute designFocus : String = "application,enforcement";
        attribute visualThemes : String = "sketchbook,field-notes,comfortable,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"20\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"34\"}";
        attribute visualWidth : Integer = 980;

        requirement specContract : WeaverZeroTrust::ZeroTrustContractRefinement;
        requirement executionContract : WeaverExecution::ConsumeBeforeSend;
        attribute mappedFile : String = "docs/50-59-research-program/59-provider-rpc/59.51-zero-trust-contract-refinement.d2";
        attribute displayTitle : String = "From SPEC contract to actual use.";
        attribute displaySubtitle : String = "cedar-poo-spec supplies semantics. Weaver owns the execution refinement.";
        attribute readerQuestion : String = "How do SPEC requirements reach final execution?";
        attribute displayEyebrow : String = "WEAVER / SPEC-BASED ZERO TRUST";
        doc /* Library contract to application/actual-use refinement. Connections
           carry requirement interpretations, not network calls or send permits. */
        expose WeaverZeroTrust::refinement::core;
        expose WeaverZeroTrust::refinement::usage;
        expose WeaverZeroTrust::refinement::parents;
        expose WeaverZeroTrust::refinement::application;
        expose WeaverZeroTrust::refinement::enforcement;
        expose WeaverZeroTrust::refinement::coreRules;
        expose WeaverZeroTrust::refinement::ongoingUse;
        expose WeaverZeroTrust::refinement::parentScope;
        expose WeaverZeroTrust::refinement::sameContext;
        render asInterconnectionDiagram;
    }

    action def ExecutionOrder {
        action propose : WeaverExecution::Propose;
        action reserve : WeaverExecution::Enqueue;
        action consume : WeaverExecution::Consume;
        action finalSend : WeaverExecution::GuardAndSend;
        action observe : WeaverExecution::RecoverOutcome;
        first propose;
        succession first propose then reserve;
        succession first reserve then consume;
        succession first consume then finalSend;
        succession first finalSend then observe;
    }
    view execution : ActionFlowView {
        expose ExecutionOrder;
    }

    view assurance {
        attribute visualBands : String = "[[\"specification\",\"schedules\"],[\"semantics\",\"implementation\"]]";
        attribute designAudience : String = "Contributors";
        attribute designMedium : String = "GitHub README and linked English Org";
        attribute designMessage : String = "Use distinct verification owners to answer distinct engineering questions.";
        attribute designFocus : String = "semantics,implementation";
        attribute visualThemes : String = "sketchbook,field-notes,comfortable,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"RIGHT\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"48\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"72\",\"elk.hierarchyHandling\":\"INCLUDE_CHILDREN\"}";
        attribute visualWidth : Integer = 1120;

        requirement specContract : WeaverZeroTrust::ZeroTrustContractRefinement;
        requirement executionContract : WeaverExecution::ConsumeBeforeSend;
        attribute mappedFile : String = "docs/50-59-research-program/59-provider-rpc/59.21-verification-ownership.d2";
        attribute displayTitle : String = "One contract. Different obligations.";
        attribute displaySubtitle : String = "Allocation, failure schedules, semantic laws and actual effects need distinct evidence.";
        attribute readerQuestion : String = "What does each engineering layer establish?";
        attribute displayEyebrow : String = "WEAVER / CHECKING THE CONTRACT";
        expose WeaverProject::AssuranceResponsibilities::specification;
        expose WeaverProject::AssuranceResponsibilities::schedules;
        expose WeaverProject::AssuranceResponsibilities::semantics;
        expose WeaverProject::AssuranceResponsibilities::implementation;
        render asInterconnectionDiagram;
    }
    view zeroTrust {
        attribute visualBands : String = "[[\"semanticPublisher\",\"controlAdapter\"],[\"policy\",\"ledger\"],[\"broker\",\"executor\"]]";
        attribute designAudience : String = "Gateway operators";
        attribute designMedium : String = "GitHub README and linked English Org";
        attribute designMessage : String = "An authenticated proposal still needs current authorization at each actual effect.";
        attribute designFocus : String = "policy,broker";
        attribute visualThemes : String = "sketchbook,ember,comfortable,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"48\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"72\",\"elk.hierarchyHandling\":\"INCLUDE_CHILDREN\"}";
        attribute visualWidth : Integer = 1120;

        requirement specContract : WeaverZeroTrust::ZeroTrustContractRefinement;
        requirement executionContract : WeaverExecution::ConsumeBeforeSend;
        attribute mappedFile : String = "docs/architecture/diagrams/00d-zero-trust-overview.d2";
        attribute displayTitle : String = "Zero Trust at every effect.";
        attribute displaySubtitle : String = "Current authority and original state meet at the actual execution boundary.";
        attribute readerQuestion : String = "What prevents a proposal from becoming an unauthorized effect?";
        attribute displayEyebrow : String = "WEAVER / PRODUCT ARCHITECTURE";
        attribute leanEnvironment : String = "required";
        expose WeaverExecution::gateway::semanticPublisher;
        expose WeaverExecution::gateway::controlAdapter;
        expose WeaverExecution::gateway::policy;
        expose WeaverExecution::gateway::ledger;
        expose WeaverExecution::gateway::broker;
        expose WeaverExecution::gateway::executor;
        expose WeaverExecution::gateway::proposeTask;
        expose WeaverExecution::gateway::controlAdapter_sourceCommands_to_ledger_sourceCommands;
        expose WeaverExecution::gateway::checkPolicy;
        expose WeaverExecution::gateway::consumedClaim;
        expose WeaverExecution::gateway::recheckUse;
        render asInterconnectionDiagram;
    }

    view storage {
        attribute visualBands : String = "[[\"registry\",\"custody\"],[\"ledger\",\"driver\"],[\"transaction\",\"broker\"],[\"retained\",\"publication\"]]";
        attribute designAudience : String = "Runtime engineers";
        attribute designMedium : String = "GitHub README and linked English Org";
        attribute designMessage : String = "Shared claims and unresolved exposure survive independent execution and recovery.";
        attribute designFocus : String = "transaction,retained";
        attribute visualThemes : String = "sketchbook,blueprint,comfortable,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"48\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"72\",\"elk.hierarchyHandling\":\"INCLUDE_CHILDREN\"}";
        attribute visualWidth : Integer = 1120;

        requirement atomicity:WeaverExecution::TursoAdmissionAtomicity;
        requirement custody:WeaverExecution::TursoMvccCustody;
        requirement domains:WeaverExecution::SharedDomainAuthority;
        requirement origin:WeaverExecution::OriginalTaskBinding;
        requirement budget:WeaverExecution::SharedBudget;
        requirement effects:WeaverExecution::ConsumeBeforeSend;
        attribute mappedFile:String="docs/50-59-research-program/59-provider-rpc/59.77-mrr-turso-storage.d2";
        attribute displayTitle:String="Shared constraints. Independent effects.";
        attribute displaySubtitle:String="MRR Data owns the physical driver. Weaver owns admission and actual effects.";
        attribute readerQuestion:String="How do claims, budget and fencing stay atomic through recovery?";
        attribute displayEyebrow:String="WEAVER / STORAGE AND EXECUTION";
        expose WeaverStorage::admission::ledger;
        expose WeaverStorage::admission::driver;
        expose WeaverStorage::admission::transaction;
        expose WeaverStorage::admission::broker;
        expose WeaverStorage::admission::custody;
        expose WeaverStorage::admission::registry;
        expose WeaverStorage::admission::rootBinding;
        expose WeaverStorage::admission::publication;
        expose WeaverStorage::admission::retained;
        expose WeaverStorage::admission::storage;
        expose WeaverStorage::admission::scope;
        expose WeaverStorage::admission::finalUse;
        expose WeaverStorage::admission::actualSend;
        expose WeaverStorage::admission::authorityOrder;
        expose WeaverStorage::admission::unresolved;
        render asInterconnectionDiagram;
    }

    view rangeRecovery {
        attribute captionContext : String = "stream";
        attribute designAudience : String = "Gateway operators";
        attribute designMedium : String = "GitHub README and linked English Org";
        attribute designMessage : String = "Follow a partial range into retained exposure without reopening its original claim.";
        attribute designFocus : String = "ledger,retained";
        attribute visualThemes : String = "sketchbook,field-notes,comfortable,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"48\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"72\",\"elk.hierarchyHandling\":\"INCLUDE_CHILDREN\"}";
        attribute visualWidth : Integer = 980;

        requirement progress : StreamingExecution::DurableRangeProgressJoin;
        requirement finalUse : StreamingExecution::RangeFinalGuard;
        attribute mappedFile : String = "docs/50-59-research-program/58-streaming-execution/58.05-range-progress-recovery.d2";
        attribute displayTitle : String = "Recovery cannot unspend a range.";
        attribute displaySubtitle : String = "Durable consumption constrains message progress, custody and final bytes.";
        attribute readerQuestion : String = "What prevents a stale queued message from reopening a spent prefix?";
        attribute displayEyebrow : String = "WEAVER / STREAM RECOVERY";
        expose StreamingExecution::streamingPath::ledger;
        expose StreamingExecution::streamingPath::transport;
        expose StreamingExecution::streamingPath::retained;
        expose StreamingExecution::streamingPath::observe;
        expose StreamingExecution::streamingPath::retain;
        render asInterconnectionDiagram;
    }

    view routeSelection {
        attribute visualNotation : String = "objects";
        attribute visualBands : String = "[[\"ingress\",\"routine\",\"catalog\"],[\"routing\"]]";
        attribute mappedFile : String = "docs/10-19-llm-gateway/10-routing-and-inference/10.02-llm-routing.d2";
        attribute displayTitle : String = "Choose an eligible model";
        attribute displaySubtitle : String = "Select from the published catalog, including reviewed provider imports.";
        attribute displayEyebrow : String = "WEAVER / ROUTING";
        attribute readerQuestion : String = "What can constrain a route proposal?";
        attribute designAudience : String = "Gateway developers and operators";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "Match the task against the current model directory.";
        attribute designFocus : String = "routing";
        attribute captionContext : String = "journey";
        attribute visualThemes : String = "sketchbook,ocean,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"18\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"32\"}";
        attribute visualWidth : Integer = 980;
        requirement finalUse : WeaverExecution::ConsumeBeforeSend;
        expose WeaverGatewayArchitecture::gateway::ingress;
        expose WeaverGatewayArchitecture::gateway::routine;
        expose WeaverGatewayArchitecture::gateway::catalog;
        expose WeaverGatewayArchitecture::gateway::routing;
        expose WeaverGatewayArchitecture::gateway::input;
        expose WeaverGatewayArchitecture::gateway::semantics;
        expose WeaverGatewayArchitecture::gateway::catalogBindings;
        render asInterconnectionDiagram;
    }

    view routeExecution {
        attribute visualNotation : String = "objects";
        attribute visualBands : String = "[[\"routing\",\"publication\"],[\"execution\",\"providers\",\"stream\"]]";
        attribute mappedFile : String = "docs/10-19-llm-gateway/10-routing-and-inference/10.05-route-execution.d2";
        attribute displayTitle : String = "Use the selected route";
        attribute displaySubtitle : String = "WIF refresh precedes the Rust broker send guard.";
        attribute displayEyebrow : String = "WEAVER / ROUTING";
        attribute readerQuestion : String = "What can authorize actual provider use?";
        attribute designAudience : String = "Gateway developers and operators";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "Rust prepares the relay grant before locking.\nFinal use checks the live grant, witness and Cedar.";
        attribute designFocus : String = "execution";
        attribute captionContext : String = "journey";
        attribute visualThemes : String = "sketchbook,ember,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"18\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"32\"}";
        attribute visualWidth : Integer = 980;
        requirement finalUse : WeaverExecution::ConsumeBeforeSend;
        requirement callerOAuth : ProviderRpc::SenderBoundProviderOAuth;
        expose WeaverGatewayArchitecture::gateway::routing;
        expose WeaverGatewayArchitecture::gateway::publication;
        expose WeaverGatewayArchitecture::gateway::execution;
        expose WeaverGatewayArchitecture::gateway::providers;
        expose WeaverGatewayArchitecture::gateway::stream;
        expose WeaverGatewayArchitecture::gateway::route;
        expose WeaverGatewayArchitecture::gateway::reviewed_policy;
        expose WeaverGatewayArchitecture::gateway::invoke;
        expose WeaverGatewayArchitecture::gateway::streamResult;
        render asInterconnectionDiagram;
    }

    view streamAdmission {
        attribute mappedFile : String = "docs/architecture/diagrams/15-stream-message-authorization.d2";
        attribute displayTitle : String = "Authorize one message range";
        attribute displaySubtitle : String = "Authenticate the caller and join the original claim, hold and current owner.";
        attribute displayEyebrow : String = "WEAVER / FLOW";
        attribute readerQuestion : String = "What must be bound before a range can write?";
        attribute designAudience : String = "Gateway developers and operators";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "Authenticate the caller and join the original claim, hold and current owner.";
        attribute designFocus : String = "guard";
        attribute captionContext : String = "stream";
        attribute visualThemes : String = "sketchbook,blueprint,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"18\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"32\"}";
        attribute visualWidth : Integer = 980;
        requirement finalUse : StreamingExecution::RangeFinalGuard;
        expose StreamingExecution::streamingPath::adapter;
        expose StreamingExecution::streamingPath::server;
        expose StreamingExecution::streamingPath::ledger;
        expose StreamingExecution::streamingPath::guard;
        expose StreamingExecution::streamingPath::transport;
        expose StreamingExecution::streamingPath::propose;
        expose StreamingExecution::streamingPath::admit;
        expose StreamingExecution::streamingPath::consume;
        expose StreamingExecution::streamingPath::writeRange;
        render asInterconnectionDiagram;
    }

    view gateway {
        attribute visualBands : String = "[[\"ingress\",\"routine\",\"catalog\"],[\"publication\",\"routing\"],[\"execution\",\"providers\",\"stream\"]]";
        attribute captionContext : String = "journey";
        attribute designAudience : String = "Application developers";
        attribute designMedium : String = "GitHub README and linked English Org";
        attribute designMessage : String = "Separate eligible model selection from authorized execution and streamed results.";
        attribute designFocus : String = "routing,execution";
        attribute visualThemes : String = "sketchbook,blueprint,comfortable,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"48\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"72\",\"elk.hierarchyHandling\":\"INCLUDE_CHILDREN\"}";
        attribute visualWidth : Integer = 1120;

        requirement specContract : WeaverZeroTrust::ZeroTrustContractRefinement;
        requirement executionContract : WeaverExecution::ConsumeBeforeSend;
        attribute mappedFile : String = "docs/architecture/diagrams/00c-gateway-runtime.d2";
        attribute displayTitle : String = "From agent intent to governed inference.";
        attribute displaySubtitle : String = "Routines define work. Routing selects bindings. Rust mediates effects.";
        attribute readerQuestion : String = "How does a request cross the Gateway?";
        attribute displayEyebrow : String = "WEAVER / PRODUCT ARCHITECTURE";
        expose WeaverGatewayArchitecture::gateway::ingress;
        expose WeaverGatewayArchitecture::gateway::routine;
        expose WeaverGatewayArchitecture::gateway::catalog;
        expose WeaverGatewayArchitecture::gateway::routing;
        expose WeaverGatewayArchitecture::gateway::publication;
        expose WeaverGatewayArchitecture::gateway::reviewed_policy;
        expose WeaverGatewayArchitecture::gateway::execution;
        expose WeaverGatewayArchitecture::gateway::providers;
        expose WeaverGatewayArchitecture::gateway::stream;
        expose WeaverGatewayArchitecture::gateway::input;
        expose WeaverGatewayArchitecture::gateway::semantics;
        expose WeaverGatewayArchitecture::gateway::catalogBindings;
        expose WeaverGatewayArchitecture::gateway::route;
        expose WeaverGatewayArchitecture::gateway::invoke;
        expose WeaverGatewayArchitecture::gateway::streamResult;
        expose WeaverGatewayArchitecture::gateway::deliver;
        expose WeaverGatewayArchitecture::gateway::progress;
        render asInterconnectionDiagram;
    }

}
