// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package WeaverArchitectureReaderViews {
    private import ScalarValues::*;
    private import Views::*;
    private import StandardViewDefinitions::*;
    doc /* Read the scoped responsibilities and facts against the referenced
       architecture contracts. These views allocate no new runtime authority. */
    item def ReaderFact;
    port def FactPort { out item value : ReaderFact; }
    part def ReaderNode {
        port incoming : ~FactPort;
        port outgoing : FactPort;
    }
    part def boundaries_meaning :> ReaderNode {
        attribute displayName : String = "Scheme governance";
        attribute responsibility : String = "Typed policy and contracts";
        attribute glyph : String = "routine";
        attribute illustration : String = "task-contract";
    }
    part def boundaries_control :> ReaderNode {
        attribute displayName : String = "Go control";
        attribute responsibility : String = "Route and publish intent";
        attribute glyph : String = "routing";
        attribute illustration : String = "route-choice";
    }
    part def boundaries_guard :> ReaderNode {
        attribute displayName : String = "Rust broker";
        attribute responsibility : String = "Current claim and policy";
        attribute glyph : String = "authorization";
        attribute illustration : String = "permission-check";
    }
    part def boundaries_writer :> ReaderNode {
        attribute displayName : String = "Final writer";
        attribute responsibility : String = "Only bounded provider use";
        attribute glyph : String = "writer";
        attribute illustration : String = "bounded-write";
    }
    part def boundaries_metrics :> ReaderNode {
        attribute displayName : String = "Telemetry";
        attribute responsibility : String = "Observe without authority";
        attribute glyph : String = "telemetry";
    }
    part boundariesBoundary {
        part p_meaning : boundaries_meaning;
        part p_control : boundaries_control;
        part p_guard : boundaries_guard;
        part p_writer : boundaries_writer;
        part p_metrics : boundaries_metrics;
        connection carrySemantics connect p_meaning.outgoing to p_control.incoming;
        connection propose connect p_control.outgoing to p_guard.incoming;
        connection authorizeUse connect p_guard.outgoing to p_writer.incoming;
        connection observe connect p_writer.outgoing to p_metrics.incoming;
    }
    view boundaries {
        attribute mappedFile : String = "docs/architecture/diagrams/01-system-boundaries.d2";
        attribute displayTitle : String = "Trace authority to the final writer";
        attribute displaySubtitle : String = "Scheme supplies semantics. Go coordinates. Rust owns actual effects.";
        attribute displayEyebrow : String = "WEAVER / SCOPED READER VIEW";
        attribute readerQuestion : String = "Who owns meaning, coordination and actual effects?";
        attribute designAudience : String = "Gateway design and runtime reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "Scheme supplies semantics. Go coordinates. Rust owns actual effects.";
        attribute designFocus : String = "p_writer";
        attribute visualThemes : String = "sketchbook,ocean,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        attribute visualNotation : String = "objects";
        attribute visualBands : String = "[[\"p_meaning\",\"p_control\"],[\"p_guard\",\"p_writer\",\"p_metrics\"]]";
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose boundariesBoundary::p_meaning;
        expose boundariesBoundary::p_control;
        expose boundariesBoundary::p_guard;
        expose boundariesBoundary::p_writer;
        expose boundariesBoundary::p_metrics;
        expose boundariesBoundary::carrySemantics;
        expose boundariesBoundary::propose;
        expose boundariesBoundary::authorizeUse;
        expose boundariesBoundary::observe;
        render asInterconnectionDiagram;
    }

    part def relationships_contract :> ReaderNode {
        attribute displayName : String = "Governed contract";
        attribute responsibility : String = "Original task and profile";
        attribute glyph : String = "policy";
    }
    part def relationships_coordination :> ReaderNode {
        attribute displayName : String = "Cloud coordination";
        attribute responsibility : String = "Current route proposal";
        attribute glyph : String = "routing";
    }
    part def relationships_authority :> ReaderNode {
        attribute displayName : String = "Execution authority";
        attribute responsibility : String = "Claim, budget and fence";
        attribute glyph : String = "authorization";
    }
    part def relationships_provider :> ReaderNode {
        attribute displayName : String = "Provider interface";
        attribute responsibility : String = "Bound request and stream";
        attribute glyph : String = "provider";
    }
    part def relationships_ledger :> ReaderNode {
        attribute displayName : String = "Durable ledger";
        attribute responsibility : String = "Original effects and outcomes";
        attribute glyph : String = "ledger";
    }
    part relationshipsBoundary {
        part p_contract : relationships_contract;
        part p_coordination : relationships_coordination;
        part p_authority : relationships_authority;
        part p_provider : relationships_provider;
        part p_ledger : relationships_ledger;
        connection taskMeaning connect p_contract.outgoing to p_coordination.incoming;
        connection boundProposal connect p_coordination.outgoing to p_authority.incoming;
        connection currentState connect p_ledger.outgoing to p_authority.incoming;
        connection mediate connect p_authority.outgoing to p_provider.incoming;
    }
    view relationships {
        attribute mappedFile : String = "docs/architecture/diagrams/01-system-relationships.d2";
        attribute displayTitle : String = "Follow the three ownership handoffs";
        attribute displaySubtitle : String = "Read the typed contract, the proposal and the actual effect separately.";
        attribute displayEyebrow : String = "WEAVER / SCOPED READER VIEW";
        attribute readerQuestion : String = "Which direction does each responsibility depend on?";
        attribute designAudience : String = "Gateway design and runtime reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "Read the typed contract, the proposal and the actual effect separately.";
        attribute designFocus : String = "p_authority";
        attribute visualThemes : String = "sketchbook,blueprint,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose relationshipsBoundary::p_contract;
        expose relationshipsBoundary::p_coordination;
        expose relationshipsBoundary::p_authority;
        expose relationshipsBoundary::p_provider;
        expose relationshipsBoundary::p_ledger;
        expose relationshipsBoundary::taskMeaning;
        expose relationshipsBoundary::boundProposal;
        expose relationshipsBoundary::currentState;
        expose relationshipsBoundary::mediate;
        render asInterconnectionDiagram;
    }

    part def fencing_oldOwner :> ReaderNode {
        attribute displayName : String = "Old worker";
        attribute responsibility : String = "May retain queued work";
        attribute glyph : String = "unknown";
    }
    part def fencing_head :> ReaderNode {
        attribute displayName : String = "Current owner head";
        attribute responsibility : String = "Bind incarnation and epoch";
        attribute glyph : String = "authentication";
    }
    part def fencing_guard :> ReaderNode {
        attribute displayName : String = "Final-use CAS";
        attribute responsibility : String = "Compare the live fence";
        attribute glyph : String = "authorization";
    }
    part def fencing_writer :> ReaderNode {
        attribute displayName : String = "Mediated writer";
        attribute responsibility : String = "One original effect";
        attribute glyph : String = "writer";
    }
    part fencingBoundary {
        part p_oldOwner : fencing_oldOwner;
        part p_head : fencing_head;
        part p_guard : fencing_guard;
        part p_writer : fencing_writer;
        connection staleAttempt connect p_oldOwner.outgoing to p_guard.incoming;
        connection currentFence connect p_head.outgoing to p_guard.incoming;
        connection permitCurrent connect p_guard.outgoing to p_writer.incoming;
    }
    view fencing {
        attribute mappedFile : String = "docs/architecture/diagrams/05-fencing-boundaries.d2";
        attribute displayTitle : String = "Compare the fence at actual use";
        attribute displaySubtitle : String = "A cached permission cannot authorize a stale writer.";
        attribute displayEyebrow : String = "WEAVER / SCOPED READER VIEW";
        attribute readerQuestion : String = "Where must an old owner be rejected?";
        attribute designAudience : String = "Gateway design and runtime reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "A cached permission cannot authorize a stale writer.";
        attribute designFocus : String = "p_guard";
        attribute visualThemes : String = "sketchbook,ember,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose fencingBoundary::p_oldOwner;
        expose fencingBoundary::p_head;
        expose fencingBoundary::p_guard;
        expose fencingBoundary::p_writer;
        expose fencingBoundary::staleAttempt;
        expose fencingBoundary::currentFence;
        expose fencingBoundary::permitCurrent;
        render asInterconnectionDiagram;
    }

    part def codePolicy_source :> ReaderNode {
        attribute displayName : String = "Governed source";
        attribute responsibility : String = "Typed contracts and rules";
        attribute glyph : String = "routine";
    }
    part def codePolicy_facts :> ReaderNode {
        attribute displayName : String = "Authoritative facts";
        attribute responsibility : String = "History and current scope";
        attribute glyph : String = "history";
    }
    part def codePolicy_decision :> ReaderNode {
        attribute displayName : String = "Cedar decision";
        attribute responsibility : String = "Exact request and entities";
        attribute glyph : String = "policy";
    }
    part def codePolicy_consume :> ReaderNode {
        attribute displayName : String = "Original consumption";
        attribute responsibility : String = "Reserve the budget";
        attribute glyph : String = "ledger";
    }
    part def codePolicy_effect :> ReaderNode {
        attribute displayName : String = "Rust final use";
        attribute responsibility : String = "Recheck and mediate";
        attribute glyph : String = "authorization";
    }
    part codePolicyBoundary {
        part p_source : codePolicy_source;
        part p_facts : codePolicy_facts;
        part p_decision : codePolicy_decision;
        part p_consume : codePolicy_consume;
        part p_effect : codePolicy_effect;
        connection loadPolicy connect p_source.outgoing to p_decision.incoming;
        connection joinFacts connect p_facts.outgoing to p_decision.incoming;
        connection allow connect p_decision.outgoing to p_consume.incoming;
        connection currentUse connect p_consume.outgoing to p_effect.incoming;
    }
    view codePolicy {
        attribute mappedFile : String = "docs/architecture/diagrams/08-code-as-policy.d2";
        attribute displayTitle : String = "Use Cedar at the effect boundary";
        attribute displaySubtitle : String = "Policy evaluates the exact request against the authoritative state.";
        attribute displayEyebrow : String = "WEAVER / SCOPED READER VIEW";
        attribute readerQuestion : String = "How does a Policy decision constrain actual bytes?";
        attribute designAudience : String = "Gateway design and runtime reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "Policy evaluates the exact request against the authoritative state.";
        attribute designFocus : String = "p_decision";
        attribute visualThemes : String = "sketchbook,ocean,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose codePolicyBoundary::p_source;
        expose codePolicyBoundary::p_facts;
        expose codePolicyBoundary::p_decision;
        expose codePolicyBoundary::p_consume;
        expose codePolicyBoundary::p_effect;
        expose codePolicyBoundary::loadPolicy;
        expose codePolicyBoundary::joinFacts;
        expose codePolicyBoundary::allow;
        expose codePolicyBoundary::currentUse;
        render asInterconnectionDiagram;
    }

    part def zeroAssurance_contract :> ReaderNode {
        attribute displayName : String = "SPEC contract";
        attribute responsibility : String = "Zero Trust premises";
        attribute glyph : String = "policy";
    }
    part def zeroAssurance_quint :> ReaderNode {
        attribute displayName : String = "Quint schedules";
        attribute responsibility : String = "Find unsafe interleavings";
        attribute glyph : String = "routine";
    }
    part def zeroAssurance_lean :> ReaderNode {
        attribute displayName : String = "Lean laws";
        attribute responsibility : String = "Prove scoped invariants";
        attribute glyph : String = "history";
    }
    part def zeroAssurance_actual :> ReaderNode {
        attribute displayName : String = "Observed runtime";
        attribute responsibility : String = "Fault and send receipts";
        attribute glyph : String = "telemetry";
    }
    part def zeroAssurance_refinement :> ReaderNode {
        attribute displayName : String = "Refinement review";
        attribute responsibility : String = "Match the actual effect";
        attribute glyph : String = "authorization";
    }
    part zeroAssuranceBoundary {
        part p_contract : zeroAssurance_contract;
        part p_quint : zeroAssurance_quint;
        part p_lean : zeroAssurance_lean;
        part p_actual : zeroAssurance_actual;
        part p_refinement : zeroAssurance_refinement;
        connection stateRules connect p_contract.outgoing to p_quint.incoming;
        connection semanticLaws connect p_contract.outgoing to p_lean.incoming;
        connection schedules connect p_quint.outgoing to p_refinement.incoming;
        connection laws connect p_lean.outgoing to p_refinement.incoming;
        connection runtimeEvidence connect p_actual.outgoing to p_refinement.incoming;
    }
    view zeroAssurance {
        attribute mappedFile : String = "docs/architecture/diagrams/11-zero-trust-assurance.d2";
        attribute displayTitle : String = "Compose independent evidence";
        attribute displaySubtitle : String = "Model exploration, proof and runtime tests answer different questions.";
        attribute displayEyebrow : String = "WEAVER / SCOPED READER VIEW";
        attribute readerQuestion : String = "What evidence supports a mediated effect?";
        attribute designAudience : String = "Gateway design and runtime reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "Model exploration, proof and runtime tests answer different questions.";
        attribute designFocus : String = "p_refinement";
        attribute visualThemes : String = "sketchbook,field-notes,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose zeroAssuranceBoundary::p_contract;
        expose zeroAssuranceBoundary::p_quint;
        expose zeroAssuranceBoundary::p_lean;
        expose zeroAssuranceBoundary::p_actual;
        expose zeroAssuranceBoundary::p_refinement;
        expose zeroAssuranceBoundary::stateRules;
        expose zeroAssuranceBoundary::semanticLaws;
        expose zeroAssuranceBoundary::schedules;
        expose zeroAssuranceBoundary::laws;
        expose zeroAssuranceBoundary::runtimeEvidence;
        render asInterconnectionDiagram;
    }

    part def policyExecution_request :> ReaderNode {
        attribute displayName : String = "Bound request";
        attribute responsibility : String = "Principal, action and resource";
        attribute glyph : String = "message";
    }
    part def policyExecution_cedar :> ReaderNode {
        attribute displayName : String = "Cedar evaluation";
        attribute responsibility : String = "Current entities and Policy";
        attribute glyph : String = "policy";
    }
    part def policyExecution_escrow :> ReaderNode {
        attribute displayName : String = "Original claim";
        attribute responsibility : String = "Budget and history";
        attribute glyph : String = "budget";
    }
    part def policyExecution_guard :> ReaderNode {
        attribute displayName : String = "Rust actual-use guard";
        attribute responsibility : String = "Join permission and custody";
        attribute glyph : String = "authorization";
    }
    part def policyExecution_writer :> ReaderNode {
        attribute displayName : String = "Transport writer";
        attribute responsibility : String = "Use the bound payload";
        attribute glyph : String = "writer";
    }
    part policyExecutionBoundary {
        part p_request : policyExecution_request;
        part p_cedar : policyExecution_cedar;
        part p_escrow : policyExecution_escrow;
        part p_guard : policyExecution_guard;
        part p_writer : policyExecution_writer;
        connection evaluate connect p_request.outgoing to p_cedar.incoming;
        connection permit connect p_cedar.outgoing to p_guard.incoming;
        connection currentClaim connect p_escrow.outgoing to p_guard.incoming;
        connection mediate connect p_guard.outgoing to p_writer.incoming;
    }
    view policyExecution {
        attribute mappedFile : String = "docs/architecture/diagrams/13-policy-to-execution.d2";
        attribute displayTitle : String = "Join permission with current execution";
        attribute displaySubtitle : String = "An Allow is evidence for the actual effect, alongside live state and custody.";
        attribute displayEyebrow : String = "WEAVER / SCOPED READER VIEW";
        attribute readerQuestion : String = "When does a Cedar Allow become usable?";
        attribute designAudience : String = "Gateway design and runtime reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "An Allow is evidence for the actual effect, alongside live state and custody.";
        attribute designFocus : String = "p_guard";
        attribute visualThemes : String = "sketchbook,ember,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose policyExecutionBoundary::p_request;
        expose policyExecutionBoundary::p_cedar;
        expose policyExecutionBoundary::p_escrow;
        expose policyExecutionBoundary::p_guard;
        expose policyExecutionBoundary::p_writer;
        expose policyExecutionBoundary::evaluate;
        expose policyExecutionBoundary::permit;
        expose policyExecutionBoundary::currentClaim;
        expose policyExecutionBoundary::mediate;
        render asInterconnectionDiagram;
    }

    part def adapterBroker_adapter :> ReaderNode {
        attribute displayName : String = "Go adapter";
        attribute responsibility : String = "Propose exact target";
        attribute glyph : String = "routing";
    }
    part def adapterBroker_context :> ReaderNode {
        attribute displayName : String = "Original context";
        attribute responsibility : String = "Retain claim and Policy";
        attribute glyph : String = "claim";
    }
    part def adapterBroker_broker :> ReaderNode {
        attribute displayName : String = "Rust broker";
        attribute responsibility : String = "Verify current effect";
        attribute glyph : String = "authorization";
        attribute illustration : String = "permission-check";
    }
    part def adapterBroker_send :> ReaderNode {
        attribute displayName : String = "Bound transport";
        attribute responsibility : String = "No implicit reroute";
        attribute glyph : String = "writer";
        attribute illustration : String = "bounded-write";
    }
    part def adapterBroker_stream :> ReaderNode {
        attribute displayName : String = "Response stream";
        attribute responsibility : String = "Keep one source";
        attribute glyph : String = "stream";
    }
    part adapterBrokerBoundary {
        part p_adapter : adapterBroker_adapter;
        part p_context : adapterBroker_context;
        part p_broker : adapterBroker_broker;
        part p_send : adapterBroker_send;
        part p_stream : adapterBroker_stream;
        connection propose connect p_adapter.outgoing to p_broker.incoming;
        connection bindOriginal connect p_context.outgoing to p_broker.incoming;
        connection guardedUse connect p_broker.outgoing to p_send.incoming;
        connection boundResult connect p_send.outgoing to p_stream.incoming;
    }
    view adapterBroker {
        attribute mappedFile : String = "docs/architecture/diagrams/14-adapter-broker-boundary.d2";
        attribute displayTitle : String = "Keep SDK proposals inside the broker boundary";
        attribute displaySubtitle : String = "A new target or payload must be assessed at actual use.";
        attribute displayEyebrow : String = "WEAVER / SCOPED READER VIEW";
        attribute readerQuestion : String = "Who may retry, redirect or open a provider stream?";
        attribute designAudience : String = "Gateway design and runtime reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "A new target or payload must be assessed at actual use.";
        attribute designFocus : String = "p_broker";
        attribute visualThemes : String = "sketchbook,ocean,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        attribute visualNotation : String = "objects";
        attribute visualBands : String = "[[\"p_adapter\",\"p_context\"],[\"p_broker\",\"p_send\",\"p_stream\"]]";
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose adapterBrokerBoundary::p_adapter;
        expose adapterBrokerBoundary::p_context;
        expose adapterBrokerBoundary::p_broker;
        expose adapterBrokerBoundary::p_send;
        expose adapterBrokerBoundary::p_stream;
        expose adapterBrokerBoundary::propose;
        expose adapterBrokerBoundary::bindOriginal;
        expose adapterBrokerBoundary::guardedUse;
        expose adapterBrokerBoundary::boundResult;
        render asInterconnectionDiagram;
    }

    part def spentState_presented :> ReaderNode {
        attribute displayName : String = "Validation context";
        attribute responsibility : String = "Exact original nonce";
        attribute glyph : String = "claim";
    }
    part def spentState_consume :> ReaderNode {
        attribute displayName : String = "Authority consume";
        attribute responsibility : String = "Compare and spend once";
        attribute glyph : String = "ledger";
    }
    part def spentState_unknownResult :> ReaderNode {
        attribute displayName : String = "Unknown reply";
        attribute responsibility : String = "Recover same operation";
        attribute glyph : String = "unknown";
    }
    part def spentState_effect :> ReaderNode {
        attribute displayName : String = "Guarded effect";
        attribute responsibility : String = "Only current qualified use";
        attribute glyph : String = "authorization";
    }
    part spentStateBoundary {
        part p_presented : spentState_presented;
        part p_consume : spentState_consume;
        part p_unknownResult : spentState_unknownResult;
        part p_effect : spentState_effect;
        connection verifyEvidence connect p_presented.outgoing to p_consume.incoming;
        connection uncertain connect p_consume.outgoing to p_unknownResult.incoming;
        connection readOriginal connect p_unknownResult.outgoing to p_consume.incoming;
        connection committed connect p_consume.outgoing to p_effect.incoming;
    }
    view spentState {
        attribute mappedFile : String = "docs/architecture/diagrams/16-authoritative-spent-state.d2";
        attribute displayTitle : String = "Resolve the original spent state";
        attribute displaySubtitle : String = "Unknown consumption keeps the original exposure until authoritative readback.";
        attribute displayEyebrow : String = "WEAVER / SCOPED READER VIEW";
        attribute readerQuestion : String = "Which record proves an authority has already been used?";
        attribute designAudience : String = "Gateway design and runtime reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "Unknown consumption keeps the original exposure until authoritative readback.";
        attribute designFocus : String = "p_consume";
        attribute visualThemes : String = "sketchbook,ember,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose spentStateBoundary::p_presented;
        expose spentStateBoundary::p_consume;
        expose spentStateBoundary::p_unknownResult;
        expose spentStateBoundary::p_effect;
        expose spentStateBoundary::verifyEvidence;
        expose spentStateBoundary::uncertain;
        expose spentStateBoundary::readOriginal;
        expose spentStateBoundary::committed;
        render asInterconnectionDiagram;
    }

    part def logicalObservation_task :> ReaderNode {
        attribute displayName : String = "Original task";
        attribute responsibility : String = "Canonical message identity";
        attribute glyph : String = "message";
    }
    part def logicalObservation_messageKey :> ReaderNode {
        attribute displayName : String = "Original claim";
        attribute responsibility : String = "Stable across reconnect";
        attribute glyph : String = "claim";
    }
    part def logicalObservation_fresh :> ReaderNode {
        attribute displayName : String = "Fresh attempt";
        attribute responsibility : String = "New nonce, same scope";
        attribute glyph : String = "routing";
    }
    part def logicalObservation_receipt :> ReaderNode {
        attribute displayName : String = "Late observation";
        attribute responsibility : String = "Join original outcome";
        attribute glyph : String = "history";
    }
    part def logicalObservation_hold :> ReaderNode {
        attribute displayName : String = "Unknown budget";
        attribute responsibility : String = "Retain the original hold";
        attribute glyph : String = "unknown";
    }
    part logicalObservationBoundary {
        part p_task : logicalObservation_task;
        part p_messageKey : logicalObservation_messageKey;
        part p_fresh : logicalObservation_fresh;
        part p_receipt : logicalObservation_receipt;
        part p_hold : logicalObservation_hold;
        connection bindIdentity connect p_task.outgoing to p_messageKey.incoming;
        connection retainScope connect p_messageKey.outgoing to p_fresh.incoming;
        connection observeOriginal connect p_receipt.outgoing to p_messageKey.incoming;
        connection retainUnknown connect p_messageKey.outgoing to p_hold.incoming;
    }
    view logicalObservation {
        attribute mappedFile : String = "docs/architecture/diagrams/17-logical-message-observation.d2";
        attribute displayTitle : String = "Keep one logical message";
        attribute displaySubtitle : String = "A receipt can describe the original outcome without changing its claim.";
        attribute displayEyebrow : String = "WEAVER / SCOPED READER VIEW";
        attribute readerQuestion : String = "Can a new nonce or late receipt replace the original message?";
        attribute designAudience : String = "Gateway design and runtime reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "A receipt can describe the original outcome without changing its claim.";
        attribute designFocus : String = "p_messageKey";
        attribute visualThemes : String = "sketchbook,blueprint,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose logicalObservationBoundary::p_task;
        expose logicalObservationBoundary::p_messageKey;
        expose logicalObservationBoundary::p_fresh;
        expose logicalObservationBoundary::p_receipt;
        expose logicalObservationBoundary::p_hold;
        expose logicalObservationBoundary::bindIdentity;
        expose logicalObservationBoundary::retainScope;
        expose logicalObservationBoundary::observeOriginal;
        expose logicalObservationBoundary::retainUnknown;
        render asInterconnectionDiagram;
    }

    part def sharedBudget_aliasKey :> ReaderNode {
        attribute displayName : String = "Protocol aliases";
        attribute responsibility : String = "Resolve stable origin";
        attribute glyph : String = "routing";
    }
    part def sharedBudget_original :> ReaderNode {
        attribute displayName : String = "Original claim";
        attribute responsibility : String = "One canonical message";
        attribute glyph : String = "claim";
    }
    part def sharedBudget_domain :> ReaderNode {
        attribute displayName : String = "Shared domain";
        attribute responsibility : String = "Budget and history";
        attribute glyph : String = "budget";
    }
    part def sharedBudget_useGate :> ReaderNode {
        attribute displayName : String = "Final-use CAS";
        attribute responsibility : String = "Join the same state";
        attribute glyph : String = "authorization";
    }
    part sharedBudgetBoundary {
        part p_aliasKey : sharedBudget_aliasKey;
        part p_original : sharedBudget_original;
        part p_domain : sharedBudget_domain;
        part p_useGate : sharedBudget_useGate;
        connection resolve connect p_aliasKey.outgoing to p_original.incoming;
        connection retainScope connect p_original.outgoing to p_domain.incoming;
        connection compare connect p_domain.outgoing to p_useGate.incoming;
    }
    view sharedBudget {
        attribute mappedFile : String = "docs/architecture/diagrams/18-shared-identity-budget.d2";
        attribute displayTitle : String = "Join the original shared domain";
        attribute displaySubtitle : String = "Aliases and reconnects preserve the same account and history.";
        attribute displayEyebrow : String = "WEAVER / SCOPED READER VIEW";
        attribute readerQuestion : String = "Can a new logical key avoid shared obligations?";
        attribute designAudience : String = "Gateway design and runtime reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "Aliases and reconnects preserve the same account and history.";
        attribute designFocus : String = "p_domain";
        attribute visualThemes : String = "sketchbook,ocean,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose sharedBudgetBoundary::p_aliasKey;
        expose sharedBudgetBoundary::p_original;
        expose sharedBudgetBoundary::p_domain;
        expose sharedBudgetBoundary::p_useGate;
        expose sharedBudgetBoundary::resolve;
        expose sharedBudgetBoundary::retainScope;
        expose sharedBudgetBoundary::compare;
        render asInterconnectionDiagram;
    }

    part def migration_original :> ReaderNode {
        attribute displayName : String = "Original domain";
        attribute responsibility : String = "Claims and held budget";
        attribute glyph : String = "budget";
    }
    part def migration_history :> ReaderNode {
        attribute displayName : String = "Durable history";
        attribute responsibility : String = "Keep all observations";
        attribute glyph : String = "history";
    }
    part def migration_migration :> ReaderNode {
        attribute displayName : String = "Authorized migration";
        attribute responsibility : String = "Commit current lineage";
        attribute glyph : String = "ledger";
    }
    part def migration_current :> ReaderNode {
        attribute displayName : String = "Current domain";
        attribute responsibility : String = "Original obligations retained";
        attribute glyph : String = "publication";
    }
    part def migration_old :> ReaderNode {
        attribute displayName : String = "Old worker";
        attribute responsibility : String = "Reject old fence";
        attribute glyph : String = "unknown";
    }
    part migrationBoundary {
        part p_original : migration_original;
        part p_history : migration_history;
        part p_migration : migration_migration;
        part p_current : migration_current;
        part p_old : migration_old;
        connection retainClaims connect p_original.outgoing to p_migration.incoming;
        connection retainHistory connect p_history.outgoing to p_migration.incoming;
        connection publish connect p_migration.outgoing to p_current.incoming;
        connection fence connect p_migration.outgoing to p_old.incoming;
    }
    view migration {
        attribute mappedFile : String = "docs/architecture/diagrams/19-finite-domains-and-migration.d2";
        attribute displayTitle : String = "Retain the original domain lineage";
        attribute displaySubtitle : String = "Migration preserves outstanding holds and history before fencing old owners.";
        attribute displayEyebrow : String = "WEAVER / SCOPED READER VIEW";
        attribute readerQuestion : String = "What survives a domain migration?";
        attribute designAudience : String = "Gateway design and runtime reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "Migration preserves outstanding holds and history before fencing old owners.";
        attribute designFocus : String = "p_migration";
        attribute visualThemes : String = "sketchbook,field-notes,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose migrationBoundary::p_original;
        expose migrationBoundary::p_history;
        expose migrationBoundary::p_migration;
        expose migrationBoundary::p_current;
        expose migrationBoundary::p_old;
        expose migrationBoundary::retainClaims;
        expose migrationBoundary::retainHistory;
        expose migrationBoundary::publish;
        expose migrationBoundary::fence;
        render asInterconnectionDiagram;
    }

    part def anchorEgress_anchor :> ReaderNode {
        attribute displayName : String = "Independent anchor";
        attribute responsibility : String = "Current durable prefix";
        attribute glyph : String = "ledger";
    }
    part def anchorEgress_recovery :> ReaderNode {
        attribute displayName : String = "Recovery image";
        attribute responsibility : String = "Match original commit";
        attribute glyph : String = "recovery";
    }
    part def anchorEgress_owner :> ReaderNode {
        attribute displayName : String = "Transport owner";
        attribute responsibility : String = "Fresh writer fence";
        attribute glyph : String = "authentication";
    }
    part def anchorEgress_guard :> ReaderNode {
        attribute displayName : String = "Egress gate";
        attribute responsibility : String = "Compare current evidence";
        attribute glyph : String = "authorization";
    }
    part def anchorEgress_bytes :> ReaderNode {
        attribute displayName : String = "Bound provider bytes";
        attribute responsibility : String = "One original effect";
        attribute glyph : String = "writer";
    }
    part anchorEgressBoundary {
        part p_anchor : anchorEgress_anchor;
        part p_recovery : anchorEgress_recovery;
        part p_owner : anchorEgress_owner;
        part p_guard : anchorEgress_guard;
        part p_bytes : anchorEgress_bytes;
        connection recover connect p_anchor.outgoing to p_recovery.incoming;
        connection joinCurrent connect p_recovery.outgoing to p_guard.incoming;
        connection checkFence connect p_owner.outgoing to p_guard.incoming;
        connection mediate connect p_guard.outgoing to p_bytes.incoming;
    }
    view anchorEgress {
        attribute mappedFile : String = "docs/architecture/diagrams/20-anchor-recovery-and-egress.d2";
        attribute displayTitle : String = "Anchor recovery before actual egress";
        attribute displaySubtitle : String = "The deciding state must survive rollback and stale workers.";
        attribute displayEyebrow : String = "WEAVER / SCOPED READER VIEW";
        attribute readerQuestion : String = "Which cuts protect recovery and actual egress?";
        attribute designAudience : String = "Gateway design and runtime reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "The deciding state must survive rollback and stale workers.";
        attribute designFocus : String = "p_guard";
        attribute visualThemes : String = "sketchbook,ember,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose anchorEgressBoundary::p_anchor;
        expose anchorEgressBoundary::p_recovery;
        expose anchorEgressBoundary::p_owner;
        expose anchorEgressBoundary::p_guard;
        expose anchorEgressBoundary::p_bytes;
        expose anchorEgressBoundary::recover;
        expose anchorEgressBoundary::joinCurrent;
        expose anchorEgressBoundary::checkFence;
        expose anchorEgressBoundary::mediate;
        render asInterconnectionDiagram;
    }

    part def journalLifecycle_seal :> ReaderNode {
        attribute displayName : String = "Seal original intent";
        attribute responsibility : String = "Bind the request";
        attribute glyph : String = "claim";
    }
    part def journalLifecycle_commitRecord :> ReaderNode {
        attribute displayName : String = "Commit the journal";
        attribute responsibility : String = "Record exact outcome";
        attribute glyph : String = "ledger";
    }
    part def journalLifecycle_activate :> ReaderNode {
        attribute displayName : String = "Activate current owner";
        attribute responsibility : String = "Verify commit and fence";
        attribute glyph : String = "authorization";
    }
    part def journalLifecycle_write :> ReaderNode {
        attribute displayName : String = "Bound writer";
        attribute responsibility : String = "Own actual bytes";
        attribute glyph : String = "writer";
    }
    part def journalLifecycle_unknownReply :> ReaderNode {
        attribute displayName : String = "Unknown reply";
        attribute responsibility : String = "Read the original commit";
        attribute glyph : String = "recovery";
    }
    part journalLifecycleBoundary {
        part p_seal : journalLifecycle_seal;
        part p_commitRecord : journalLifecycle_commitRecord;
        part p_activate : journalLifecycle_activate;
        part p_write : journalLifecycle_write;
        part p_unknownReply : journalLifecycle_unknownReply;
        connection commit connect p_seal.outgoing to p_commitRecord.incoming;
        connection verifyEvidence connect p_commitRecord.outgoing to p_activate.incoming;
        connection delegate connect p_activate.outgoing to p_write.incoming;
        connection readBack connect p_unknownReply.outgoing to p_commitRecord.incoming;
    }
    view journalLifecycle {
        attribute mappedFile : String = "docs/architecture/diagrams/21-composed-journal-transport-lifecycle.d2";
        attribute displayTitle : String = "Activate only a committed transport";
        attribute displaySubtitle : String = "A lost response does not create another owner or send.";
        attribute displayEyebrow : String = "WEAVER / SCOPED READER VIEW";
        attribute readerQuestion : String = "How do seal, commit and activation constrain a writer?";
        attribute designAudience : String = "Gateway design and runtime reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "A lost response does not create another owner or send.";
        attribute designFocus : String = "p_activate";
        attribute visualThemes : String = "sketchbook,ocean,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose journalLifecycleBoundary::p_seal;
        expose journalLifecycleBoundary::p_commitRecord;
        expose journalLifecycleBoundary::p_activate;
        expose journalLifecycleBoundary::p_write;
        expose journalLifecycleBoundary::p_unknownReply;
        expose journalLifecycleBoundary::commit;
        expose journalLifecycleBoundary::verifyEvidence;
        expose journalLifecycleBoundary::delegate;
        expose journalLifecycleBoundary::readBack;
        render asInterconnectionDiagram;
    }

    part def manifest_manifest :> ReaderNode {
        attribute displayName : String = "Finite manifest";
        attribute responsibility : String = "Bind original stream";
        attribute glyph : String = "stream";
    }
    part def manifest_range :> ReaderNode {
        attribute displayName : String = "Exact range";
        attribute responsibility : String = "Affine capability";
        attribute glyph : String = "claim";
    }
    part def manifest_budget :> ReaderNode {
        attribute displayName : String = "Shared budget";
        attribute responsibility : String = "Reserve before writing";
        attribute glyph : String = "budget";
    }
    part def manifest_rangeGate :> ReaderNode {
        attribute displayName : String = "Current range gate";
        attribute responsibility : String = "Check owner and progress";
        attribute glyph : String = "authorization";
    }
    part def manifest_held :> ReaderNode {
        attribute displayName : String = "Unknown partial write";
        attribute responsibility : String = "Hold original exposure";
        attribute glyph : String = "unknown";
    }
    part manifestBoundary {
        part p_manifest : manifest_manifest;
        part p_range : manifest_range;
        part p_budget : manifest_budget;
        part p_rangeGate : manifest_rangeGate;
        part p_held : manifest_held;
        connection bindRange connect p_manifest.outgoing to p_range.incoming;
        connection consume connect p_range.outgoing to p_rangeGate.incoming;
        connection reserve connect p_budget.outgoing to p_rangeGate.incoming;
        connection retainPartial connect p_rangeGate.outgoing to p_held.incoming;
    }
    view manifest {
        attribute mappedFile : String = "docs/architecture/diagrams/22-finite-stream-manifest.d2";
        attribute displayTitle : String = "Reserve each manifest range once";
        attribute displaySubtitle : String = "The original claim and shared budget survive a writer restart.";
        attribute displayEyebrow : String = "WEAVER / SCOPED READER VIEW";
        attribute readerQuestion : String = "What prevents two owners from sending the same range?";
        attribute designAudience : String = "Gateway design and runtime reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "The original claim and shared budget survive a writer restart.";
        attribute designFocus : String = "p_rangeGate";
        attribute visualThemes : String = "sketchbook,blueprint,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose manifestBoundary::p_manifest;
        expose manifestBoundary::p_range;
        expose manifestBoundary::p_budget;
        expose manifestBoundary::p_rangeGate;
        expose manifestBoundary::p_held;
        expose manifestBoundary::bindRange;
        expose manifestBoundary::consume;
        expose manifestBoundary::reserve;
        expose manifestBoundary::retainPartial;
        render asInterconnectionDiagram;
    }

    part def driverCompletion_driver :> ReaderNode {
        attribute displayName : String = "Original driver";
        attribute responsibility : String = "Own the range writer";
        attribute glyph : String = "writer";
    }
    part def driverCompletion_progress :> ReaderNode {
        attribute displayName : String = "Durable progress";
        attribute responsibility : String = "Exact known prefix";
        attribute glyph : String = "ledger";
    }
    part def driverCompletion_receipt :> ReaderNode {
        attribute displayName : String = "Completion evidence";
        attribute responsibility : String = "Bind driver and range";
        attribute glyph : String = "history";
    }
    part def driverCompletion_complete :> ReaderNode {
        attribute displayName : String = "Recovery decision";
        attribute responsibility : String = "Join current custody";
        attribute glyph : String = "recovery";
    }
    part def driverCompletion_held :> ReaderNode {
        attribute displayName : String = "Unknown suffix";
        attribute responsibility : String = "Keep budget and stop";
        attribute glyph : String = "unknown";
    }
    part driverCompletionBoundary {
        part p_driver : driverCompletion_driver;
        part p_progress : driverCompletion_progress;
        part p_receipt : driverCompletion_receipt;
        part p_complete : driverCompletion_complete;
        part p_held : driverCompletion_held;
        connection record connect p_driver.outgoing to p_progress.incoming;
        connection knownPrefix connect p_progress.outgoing to p_complete.incoming;
        connection proveCompletion connect p_receipt.outgoing to p_complete.incoming;
        connection retainUnknown connect p_complete.outgoing to p_held.incoming;
    }
    view driverCompletion {
        attribute mappedFile : String = "docs/architecture/diagrams/23-driver-completion-recovery.d2";
        attribute displayTitle : String = "Recover original completion evidence";
        attribute displaySubtitle : String = "A late receipt only describes the range it is bound to.";
        attribute displayEyebrow : String = "WEAVER / SCOPED READER VIEW";
        attribute readerQuestion : String = "When may recovery advance beyond a partially written range?";
        attribute designAudience : String = "Gateway design and runtime reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "A late receipt only describes the range it is bound to.";
        attribute designFocus : String = "p_complete";
        attribute visualThemes : String = "sketchbook,field-notes,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose driverCompletionBoundary::p_driver;
        expose driverCompletionBoundary::p_progress;
        expose driverCompletionBoundary::p_receipt;
        expose driverCompletionBoundary::p_complete;
        expose driverCompletionBoundary::p_held;
        expose driverCompletionBoundary::record;
        expose driverCompletionBoundary::knownPrefix;
        expose driverCompletionBoundary::proveCompletion;
        expose driverCompletionBoundary::retainUnknown;
        render asInterconnectionDiagram;
    }

    part def writerSettlement_writer :> ReaderNode {
        attribute displayName : String = "Original writer";
        attribute responsibility : String = "Current FD and buffers";
        attribute glyph : String = "writer";
    }
    part def writerSettlement_seal :> ReaderNode {
        attribute displayName : String = "Writer closure";
        attribute responsibility : String = "Prove old path retired";
        attribute glyph : String = "authorization";
    }
    part def writerSettlement_record :> ReaderNode {
        attribute displayName : String = "Durable completion";
        attribute responsibility : String = "Bind original range";
        attribute glyph : String = "ledger";
    }
    part def writerSettlement_usage :> ReaderNode {
        attribute displayName : String = "Final usage receipt";
        attribute responsibility : String = "Qualified original evidence";
        attribute glyph : String = "history";
    }
    part def writerSettlement_settle :> ReaderNode {
        attribute displayName : String = "Settlement decision";
        attribute responsibility : String = "Release only known amount";
        attribute glyph : String = "budget";
    }
    part writerSettlementBoundary {
        part p_writer : writerSettlement_writer;
        part p_seal : writerSettlement_seal;
        part p_record : writerSettlement_record;
        part p_usage : writerSettlement_usage;
        part p_settle : writerSettlement_settle;
        connection close connect p_writer.outgoing to p_seal.incoming;
        connection commit connect p_seal.outgoing to p_record.incoming;
        connection complete connect p_record.outgoing to p_settle.incoming;
        connection joinUsage connect p_usage.outgoing to p_settle.incoming;
    }
    view writerSettlement {
        attribute mappedFile : String = "docs/architecture/diagrams/24-writer-settlement-closure.d2";
        attribute displayTitle : String = "Close the writer before final accounting";
        attribute displaySubtitle : String = "Late usage cannot reopen the original stream or reservation.";
        attribute displayEyebrow : String = "WEAVER / SCOPED READER VIEW";
        attribute readerQuestion : String = "What makes writer completion safe to settle?";
        attribute designAudience : String = "Gateway design and runtime reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "Late usage cannot reopen the original stream or reservation.";
        attribute designFocus : String = "p_settle";
        attribute visualThemes : String = "sketchbook,ember,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose writerSettlementBoundary::p_writer;
        expose writerSettlementBoundary::p_seal;
        expose writerSettlementBoundary::p_record;
        expose writerSettlementBoundary::p_usage;
        expose writerSettlementBoundary::p_settle;
        expose writerSettlementBoundary::close;
        expose writerSettlementBoundary::commit;
        expose writerSettlementBoundary::complete;
        expose writerSettlementBoundary::joinUsage;
        render asInterconnectionDiagram;
    }

    part def settlementAnchor_decision :> ReaderNode {
        attribute displayName : String = "Original settlement";
        attribute responsibility : String = "Exact reservation and delta";
        attribute glyph : String = "budget";
    }
    part def settlementAnchor_anchor :> ReaderNode {
        attribute displayName : String = "Independent prefix";
        attribute responsibility : String = "Commit exact decision";
        attribute glyph : String = "ledger";
    }
    part def settlementAnchor_gate :> ReaderNode {
        attribute displayName : String = "Account application";
        attribute responsibility : String = "Apply original ID once";
        attribute glyph : String = "authorization";
    }
    part def settlementAnchor_readback :> ReaderNode {
        attribute displayName : String = "Lost response";
        attribute responsibility : String = "Read back original outcome";
        attribute glyph : String = "recovery";
    }
    part settlementAnchorBoundary {
        part p_decision : settlementAnchor_decision;
        part p_anchor : settlementAnchor_anchor;
        part p_gate : settlementAnchor_gate;
        part p_readback : settlementAnchor_readback;
        connection commit connect p_decision.outgoing to p_anchor.incoming;
        connection applyExact connect p_anchor.outgoing to p_gate.incoming;
        connection recover connect p_readback.outgoing to p_anchor.incoming;
    }
    view settlementAnchor {
        attribute mappedFile : String = "docs/architecture/diagrams/25-settlement-anchor-recovery.d2";
        attribute displayTitle : String = "Recover the anchored settlement";
        attribute displaySubtitle : String = "The original application ID owns the exact balance delta.";
        attribute displayEyebrow : String = "WEAVER / SCOPED READER VIEW";
        attribute readerQuestion : String = "How is an account write recovered without applying it twice?";
        attribute designAudience : String = "Gateway design and runtime reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "The original application ID owns the exact balance delta.";
        attribute designFocus : String = "p_gate";
        attribute visualThemes : String = "sketchbook,blueprint,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose settlementAnchorBoundary::p_decision;
        expose settlementAnchorBoundary::p_anchor;
        expose settlementAnchorBoundary::p_gate;
        expose settlementAnchorBoundary::p_readback;
        expose settlementAnchorBoundary::commit;
        expose settlementAnchorBoundary::applyExact;
        expose settlementAnchorBoundary::recover;
        render asInterconnectionDiagram;
    }

    part def gatePersistence_consume :> ReaderNode {
        attribute displayName : String = "Gate consume log";
        attribute responsibility : String = "Exact original obligation";
        attribute glyph : String = "claim";
    }
    part def gatePersistence_anchor :> ReaderNode {
        attribute displayName : String = "Independent anchor";
        attribute responsibility : String = "Confirm durable prefix";
        attribute glyph : String = "ledger";
    }
    part def gatePersistence_account :> ReaderNode {
        attribute displayName : String = "Account effect";
        attribute responsibility : String = "Use the committed consume";
        attribute glyph : String = "budget";
    }
    part def gatePersistence_unknownReply :> ReaderNode {
        attribute displayName : String = "Unknown reply";
        attribute responsibility : String = "Hold and recover";
        attribute glyph : String = "unknown";
    }
    part gatePersistenceBoundary {
        part p_consume : gatePersistence_consume;
        part p_anchor : gatePersistence_anchor;
        part p_account : gatePersistence_account;
        part p_unknownReply : gatePersistence_unknownReply;
        connection commit connect p_consume.outgoing to p_anchor.incoming;
        connection qualify connect p_anchor.outgoing to p_account.incoming;
        connection readOriginal connect p_unknownReply.outgoing to p_anchor.incoming;
    }
    view gatePersistence {
        attribute mappedFile : String = "docs/architecture/diagrams/26-gate-consumption-persistence.d2";
        attribute displayTitle : String = "Anchor the original consume";
        attribute displaySubtitle : String = "A missing acknowledgment cannot release unknown budget.";
        attribute displayEyebrow : String = "WEAVER / SCOPED READER VIEW";
        attribute readerQuestion : String = "What proves the gate permission was consumed durably?";
        attribute designAudience : String = "Gateway design and runtime reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "A missing acknowledgment cannot release unknown budget.";
        attribute designFocus : String = "p_anchor";
        attribute visualThemes : String = "sketchbook,field-notes,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose gatePersistenceBoundary::p_consume;
        expose gatePersistenceBoundary::p_anchor;
        expose gatePersistenceBoundary::p_account;
        expose gatePersistenceBoundary::p_unknownReply;
        expose gatePersistenceBoundary::commit;
        expose gatePersistenceBoundary::qualify;
        expose gatePersistenceBoundary::readOriginal;
        render asInterconnectionDiagram;
    }

    part def anchorBroker_prefix :> ReaderNode {
        attribute displayName : String = "Anchored commit";
        attribute responsibility : String = "Exact original decision";
        attribute glyph : String = "ledger";
    }
    part def anchorBroker_owner :> ReaderNode {
        attribute displayName : String = "Current broker owner";
        attribute responsibility : String = "Recheck fence and head";
        attribute glyph : String = "authentication";
    }
    part def anchorBroker_broker :> ReaderNode {
        attribute displayName : String = "Final consume";
        attribute responsibility : String = "Join current prefix";
        attribute glyph : String = "authorization";
    }
    part def anchorBroker_writer :> ReaderNode {
        attribute displayName : String = "Bound writer";
        attribute responsibility : String = "Original external effect";
        attribute glyph : String = "writer";
    }
    part def anchorBroker_unknownReply :> ReaderNode {
        attribute displayName : String = "Lost reply";
        attribute responsibility : String = "Resolve original result";
        attribute glyph : String = "recovery";
    }
    part anchorBrokerBoundary {
        part p_prefix : anchorBroker_prefix;
        part p_owner : anchorBroker_owner;
        part p_broker : anchorBroker_broker;
        part p_writer : anchorBroker_writer;
        part p_unknownReply : anchorBroker_unknownReply;
        connection joinCommit connect p_prefix.outgoing to p_broker.incoming;
        connection checkFence connect p_owner.outgoing to p_broker.incoming;
        connection mediate connect p_broker.outgoing to p_writer.incoming;
        connection recover connect p_unknownReply.outgoing to p_prefix.incoming;
    }
    view anchorBroker {
        attribute mappedFile : String = "docs/architecture/diagrams/27-anchor-commit-broker-fencing.d2";
        attribute displayTitle : String = "Fence the broker at the anchored commit";
        attribute displaySubtitle : String = "Only the current writer can consume the exact committed decision.";
        attribute displayEyebrow : String = "WEAVER / SCOPED READER VIEW";
        attribute readerQuestion : String = "How do a leader change and stale permit affect final use?";
        attribute designAudience : String = "Gateway design and runtime reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "Only the current writer can consume the exact committed decision.";
        attribute designFocus : String = "p_broker";
        attribute visualThemes : String = "sketchbook,ember,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose anchorBrokerBoundary::p_prefix;
        expose anchorBrokerBoundary::p_owner;
        expose anchorBrokerBoundary::p_broker;
        expose anchorBrokerBoundary::p_writer;
        expose anchorBrokerBoundary::p_unknownReply;
        expose anchorBrokerBoundary::joinCommit;
        expose anchorBrokerBoundary::checkFence;
        expose anchorBrokerBoundary::mediate;
        expose anchorBrokerBoundary::recover;
        render asInterconnectionDiagram;
    }

    part def configPrefix_old :> ReaderNode {
        attribute displayName : String = "Old configuration";
        attribute responsibility : String = "Committed original prefix";
        attribute glyph : String = "history";
    }
    part def configPrefix_joint :> ReaderNode {
        attribute displayName : String = "Joint quorum";
        attribute responsibility : String = "Certify prefix inheritance";
        attribute glyph : String = "ledger";
    }
    part def configPrefix_next :> ReaderNode {
        attribute displayName : String = "New configuration";
        attribute responsibility : String = "Install inherited floor";
        attribute glyph : String = "publication";
    }
    part def configPrefix_broker :> ReaderNode {
        attribute displayName : String = "Broker fence";
        attribute responsibility : String = "Use current head and owner";
        attribute glyph : String = "authorization";
    }
    part configPrefixBoundary {
        part p_old : configPrefix_old;
        part p_joint : configPrefix_joint;
        part p_next : configPrefix_next;
        part p_broker : configPrefix_broker;
        connection inherit connect p_old.outgoing to p_joint.incoming;
        connection commit connect p_joint.outgoing to p_next.incoming;
        connection fence connect p_next.outgoing to p_broker.incoming;
    }
    view configPrefix {
        attribute mappedFile : String = "docs/architecture/diagrams/28-anchor-configuration-prefix.d2";
        attribute displayTitle : String = "Reconfigure without losing the prefix";
        attribute displaySubtitle : String = "Late old acknowledgments cannot authorize an independent branch.";
        attribute displayEyebrow : String = "WEAVER / SCOPED READER VIEW";
        attribute readerQuestion : String = "How does a new quorum inherit a committed prefix?";
        attribute designAudience : String = "Gateway design and runtime reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "Late old acknowledgments cannot authorize an independent branch.";
        attribute designFocus : String = "p_joint";
        attribute visualThemes : String = "sketchbook,blueprint,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose configPrefixBoundary::p_old;
        expose configPrefixBoundary::p_joint;
        expose configPrefixBoundary::p_next;
        expose configPrefixBoundary::p_broker;
        expose configPrefixBoundary::inherit;
        expose configPrefixBoundary::commit;
        expose configPrefixBoundary::fence;
        render asInterconnectionDiagram;
    }

    part def quorumPromises_promise :> ReaderNode {
        attribute displayName : String = "Protected promise";
        attribute responsibility : String = "Persist before confirmation";
        attribute glyph : String = "ledger";
    }
    part def quorumPromises_snapshot :> ReaderNode {
        attribute displayName : String = "Restored member";
        attribute responsibility : String = "Recover original prefix";
        attribute glyph : String = "recovery";
    }
    part def quorumPromises_quorum :> ReaderNode {
        attribute displayName : String = "Current quorum";
        attribute responsibility : String = "Reject conflicting history";
        attribute glyph : String = "authentication";
    }
    part def quorumPromises_broker :> ReaderNode {
        attribute displayName : String = "Current broker fence";
        attribute responsibility : String = "Guard one original consume";
        attribute glyph : String = "authorization";
    }
    part quorumPromisesBoundary {
        part p_promise : quorumPromises_promise;
        part p_snapshot : quorumPromises_snapshot;
        part p_quorum : quorumPromises_quorum;
        part p_broker : quorumPromises_broker;
        connection restore connect p_promise.outgoing to p_snapshot.incoming;
        connection verifyEvidence connect p_snapshot.outgoing to p_quorum.incoming;
        connection comparePrefix connect p_promise.outgoing to p_quorum.incoming;
        connection qualify connect p_quorum.outgoing to p_broker.incoming;
    }
    view quorumPromises {
        attribute mappedFile : String = "docs/architecture/diagrams/29-quorum-durable-promises.d2";
        attribute displayTitle : String = "Recover durable promises before voting";
        attribute displaySubtitle : String = "A returning signer must honor its protected promise and current configuration.";
        attribute displayEyebrow : String = "WEAVER / SCOPED READER VIEW";
        attribute readerQuestion : String = "What prevents a restored member from signing a conflicting prefix?";
        attribute designAudience : String = "Gateway design and runtime reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "A returning signer must honor its protected promise and current configuration.";
        attribute designFocus : String = "p_promise";
        attribute visualThemes : String = "sketchbook,field-notes,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose quorumPromisesBoundary::p_promise;
        expose quorumPromisesBoundary::p_snapshot;
        expose quorumPromisesBoundary::p_quorum;
        expose quorumPromisesBoundary::p_broker;
        expose quorumPromisesBoundary::restore;
        expose quorumPromisesBoundary::verifyEvidence;
        expose quorumPromisesBoundary::comparePrefix;
        expose quorumPromisesBoundary::qualify;
        render asInterconnectionDiagram;
    }

    part def sharedExposure_domain :> ReaderNode {
        attribute displayName : String = "Shared execution domain";
        attribute responsibility : String = "Original claim and history";
        attribute glyph : String = "claim";
    }
    part def sharedExposure_hold :> ReaderNode {
        attribute displayName : String = "Budget exposure";
        attribute responsibility : String = "Reserve before the effect";
        attribute glyph : String = "budget";
    }
    part def sharedExposure_observed :> ReaderNode {
        attribute displayName : String = "Terminal evidence";
        attribute responsibility : String = "Bind original outcome";
        attribute glyph : String = "history";
    }
    part def sharedExposure_settle :> ReaderNode {
        attribute displayName : String = "Qualified settlement";
        attribute responsibility : String = "Apply exact result once";
        attribute glyph : String = "ledger";
    }
    part def sharedExposure_unknownResult :> ReaderNode {
        attribute displayName : String = "Unknown result";
        attribute responsibility : String = "Retain the original hold";
        attribute glyph : String = "unknown";
    }
    part sharedExposureBoundary {
        part p_domain : sharedExposure_domain;
        part p_hold : sharedExposure_hold;
        part p_observed : sharedExposure_observed;
        part p_settle : sharedExposure_settle;
        part p_unknownResult : sharedExposure_unknownResult;
        connection reserve connect p_domain.outgoing to p_hold.incoming;
        connection joinOriginal connect p_hold.outgoing to p_settle.incoming;
        connection verifyEvidence connect p_observed.outgoing to p_settle.incoming;
        connection retain connect p_hold.outgoing to p_unknownResult.incoming;
    }
    view sharedExposure {
        attribute mappedFile : String = "docs/architecture/diagrams/39-shared-execution-exposure.d2";
        attribute displayTitle : String = "Hold unknown exposure across recovery";
        attribute displaySubtitle : String = "Reconciliation follows the original shared domain and effect.";
        attribute displayEyebrow : String = "WEAVER / SCOPED READER VIEW";
        attribute readerQuestion : String = "When can shared execution exposure be released?";
        attribute designAudience : String = "Gateway design and runtime reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "Reconciliation follows the original shared domain and effect.";
        attribute designFocus : String = "p_settle";
        attribute visualThemes : String = "sketchbook,ocean,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose sharedExposureBoundary::p_domain;
        expose sharedExposureBoundary::p_hold;
        expose sharedExposureBoundary::p_observed;
        expose sharedExposureBoundary::p_settle;
        expose sharedExposureBoundary::p_unknownResult;
        expose sharedExposureBoundary::reserve;
        expose sharedExposureBoundary::joinOriginal;
        expose sharedExposureBoundary::verifyEvidence;
        expose sharedExposureBoundary::retain;
        render asInterconnectionDiagram;
    }
}
