// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package WeaverResearchReaderViews {
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
    part def semanticSlice_task :> ReaderNode {
        attribute displayName : String = "Original task";
        attribute responsibility : String = "Select profile and context";
        attribute glyph : String = "claim";
    }
    part def semanticSlice_knowledge :> ReaderNode {
        attribute displayName : String = "Knowledge slice";
        attribute responsibility : String = "Bind ordered inputs";
        attribute glyph : String = "catalog";
    }
    part def semanticSlice_proposal :> ReaderNode {
        attribute displayName : String = "Go proposal";
        attribute responsibility : String = "Carry the selected binding";
        attribute glyph : String = "routing";
    }
    part def semanticSlice_useGate :> ReaderNode {
        attribute displayName : String = "Current Rust gate";
        attribute responsibility : String = "Join budget and Policy";
        attribute glyph : String = "authorization";
    }
    part def semanticSlice_release :> ReaderNode {
        attribute displayName : String = "Bound release";
        attribute responsibility : String = "Preserve response scope";
        attribute glyph : String = "stream";
    }
    part semanticSliceBoundary {
        part p_task : semanticSlice_task;
        part p_knowledge : semanticSlice_knowledge;
        part p_proposal : semanticSlice_proposal;
        part p_useGate : semanticSlice_useGate;
        part p_release : semanticSlice_release;
        connection select connect p_task.outgoing to p_knowledge.incoming;
        connection bindOriginal connect p_task.outgoing to p_proposal.incoming;
        connection carryContext connect p_knowledge.outgoing to p_proposal.incoming;
        connection currentUse connect p_proposal.outgoing to p_useGate.incoming;
        connection mediate connect p_useGate.outgoing to p_release.incoming;
    }
    view semanticSlice {
        attribute mappedFile : String = "docs/50-59-research-program/51-qualified-semantic-slice/51.06-semantic-gateway-slice.d2";
        attribute displayTitle : String = "Use one original governed execution";
        attribute displaySubtitle : String = "The selected semantic slice keeps its task, profile and knowledge scope.";
        attribute displayEyebrow : String = "WEAVER / SCOPED READER VIEW";
        attribute readerQuestion : String = "How does one task stay bound through retrieval, inference and release?";
        attribute designAudience : String = "Gateway design and runtime reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "The selected semantic slice keeps its task, profile and knowledge scope.";
        attribute designFocus : String = "p_useGate";
        attribute visualThemes : String = "sketchbook,ocean,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose semanticSliceBoundary::p_task;
        expose semanticSliceBoundary::p_knowledge;
        expose semanticSliceBoundary::p_proposal;
        expose semanticSliceBoundary::p_useGate;
        expose semanticSliceBoundary::p_release;
        expose semanticSliceBoundary::select;
        expose semanticSliceBoundary::bindOriginal;
        expose semanticSliceBoundary::carryContext;
        expose semanticSliceBoundary::currentUse;
        expose semanticSliceBoundary::mediate;
        render asInterconnectionDiagram;
    }

    part def profileBinding_task :> ReaderNode {
        attribute displayName : String = "Canonical task";
        attribute responsibility : String = "Original key and payload";
        attribute glyph : String = "claim";
    }
    part def profileBinding_profile :> ReaderNode {
        attribute displayName : String = "Selected profile node";
        attribute responsibility : String = "Retain required parents";
        attribute glyph : String = "policy";
    }
    part def profileBinding_commitRecord :> ReaderNode {
        attribute displayName : String = "Committed binding";
        attribute responsibility : String = "Budget, history and route";
        attribute glyph : String = "ledger";
    }
    part def profileBinding_gate :> ReaderNode {
        attribute displayName : String = "Actual use";
        attribute responsibility : String = "Rejoin the exact binding";
        attribute glyph : String = "authorization";
    }
    part profileBindingBoundary {
        part p_task : profileBinding_task;
        part p_profile : profileBinding_profile;
        part p_commitRecord : profileBinding_commitRecord;
        part p_gate : profileBinding_gate;
        connection original connect p_task.outgoing to p_commitRecord.incoming;
        connection selectNode connect p_profile.outgoing to p_commitRecord.incoming;
        connection verifyCurrent connect p_commitRecord.outgoing to p_gate.incoming;
    }
    view profileBinding {
        attribute mappedFile : String = "docs/50-59-research-program/52-committed-profile-binding/52.04-committed-profile.d2";
        attribute displayTitle : String = "Bind the original selected node";
        attribute displaySubtitle : String = "Recovery reads the committed profile binding.";
        attribute displayEyebrow : String = "WEAVER / SCOPED READER VIEW";
        attribute readerQuestion : String = "Can a provider use a different profile node after commit?";
        attribute designAudience : String = "Gateway design and runtime reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "Recovery reads the committed profile binding.";
        attribute designFocus : String = "p_gate";
        attribute visualThemes : String = "sketchbook,blueprint,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose profileBindingBoundary::p_task;
        expose profileBindingBoundary::p_profile;
        expose profileBindingBoundary::p_commitRecord;
        expose profileBindingBoundary::p_gate;
        expose profileBindingBoundary::original;
        expose profileBindingBoundary::selectNode;
        expose profileBindingBoundary::verifyCurrent;
        render asInterconnectionDiagram;
    }

    part def gerbilLifecycle_source :> ReaderNode {
        attribute displayName : String = "Owned Scheme modules";
        attribute responsibility : String = "Build the exact closure";
        attribute glyph : String = "routine";
    }
    part def gerbilLifecycle_image :> ReaderNode {
        attribute displayName : String = "Verifier image";
        attribute responsibility : String = "Load the captured modules";
        attribute glyph : String = "catalog";
    }
    part def gerbilLifecycle_checkRun :> ReaderNode {
        attribute displayName : String = "Checks returned";
        attribute responsibility : String = "Record result and phase";
        attribute glyph : String = "policy";
    }
    part def gerbilLifecycle_exit :> ReaderNode {
        attribute displayName : String = "Natural process exit";
        attribute responsibility : String = "Observe cleanup";
        attribute glyph : String = "telemetry";
    }
    part def gerbilLifecycle_receipt :> ReaderNode {
        attribute displayName : String = "Qualification receipt";
        attribute responsibility : String = "Evidence for the owner";
        attribute glyph : String = "history";
    }
    part gerbilLifecycleBoundary {
        part p_source : gerbilLifecycle_source;
        part p_image : gerbilLifecycle_image;
        part p_checkRun : gerbilLifecycle_checkRun;
        part p_exit : gerbilLifecycle_exit;
        part p_receipt : gerbilLifecycle_receipt;
        connection build connect p_source.outgoing to p_image.incoming;
        connection execute connect p_image.outgoing to p_checkRun.incoming;
        connection observeExit connect p_checkRun.outgoing to p_exit.incoming;
        connection record connect p_exit.outgoing to p_receipt.incoming;
    }
    view gerbilLifecycle {
        attribute mappedFile : String = "docs/50-59-research-program/53-gerbil-exit/53.04-gerbil-lifecycle.d2";
        attribute displayTitle : String = "Observe the owned verifier lifecycle";
        attribute displaySubtitle : String = "A returned check and a clean natural exit are separate evidence.";
        attribute displayEyebrow : String = "WEAVER / SCOPED READER VIEW";
        attribute readerQuestion : String = "What does a successful native verification run establish?";
        attribute designAudience : String = "Gateway design and runtime reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "A returned check and a clean natural exit are separate evidence.";
        attribute designFocus : String = "p_receipt";
        attribute visualThemes : String = "sketchbook,field-notes,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose gerbilLifecycleBoundary::p_source;
        expose gerbilLifecycleBoundary::p_image;
        expose gerbilLifecycleBoundary::p_checkRun;
        expose gerbilLifecycleBoundary::p_exit;
        expose gerbilLifecycleBoundary::p_receipt;
        expose gerbilLifecycleBoundary::build;
        expose gerbilLifecycleBoundary::execute;
        expose gerbilLifecycleBoundary::observeExit;
        expose gerbilLifecycleBoundary::record;
        render asInterconnectionDiagram;
    }

    part def gxiLifecycle_discover :> ReaderNode {
        attribute displayName : String = "Module discovery";
        attribute responsibility : String = "Resolve the closure";
        attribute glyph : String = "catalog";
    }
    part def gxiLifecycle_loadPhase :> ReaderNode {
        attribute displayName : String = "Load modules";
        attribute responsibility : String = "Prepare the interpreter";
        attribute glyph : String = "routine";
    }
    part def gxiLifecycle_evaluate :> ReaderNode {
        attribute displayName : String = "Evaluate checks";
        attribute responsibility : String = "Capture the return";
        attribute glyph : String = "policy";
    }
    part def gxiLifecycle_observeRun :> ReaderNode {
        attribute displayName : String = "Observe natural exit";
        attribute responsibility : String = "Separate cleanup timing";
        attribute glyph : String = "telemetry";
    }
    part gxiLifecycleBoundary {
        part p_discover : gxiLifecycle_discover;
        part p_loadPhase : gxiLifecycle_loadPhase;
        part p_evaluate : gxiLifecycle_evaluate;
        part p_observeRun : gxiLifecycle_observeRun;
        connection discover connect p_discover.outgoing to p_loadPhase.incoming;
        connection loaded connect p_loadPhase.outgoing to p_evaluate.incoming;
        connection returned connect p_evaluate.outgoing to p_observeRun.incoming;
    }
    view gxiLifecycle {
        attribute mappedFile : String = "docs/50-59-research-program/54-dynamic-gxi-exit/54.04-dynamic-lifecycle.d2";
        attribute displayTitle : String = "Separate load, evaluation and exit";
        attribute displaySubtitle : String = "A completed check does not measure module discovery or cleanup.";
        attribute displayEyebrow : String = "WEAVER / SCOPED READER VIEW";
        attribute readerQuestion : String = "Which phase owns a dynamic interpreter delay?";
        attribute designAudience : String = "Gateway design and runtime reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "A completed check does not measure module discovery or cleanup.";
        attribute designFocus : String = "p_observeRun";
        attribute visualThemes : String = "sketchbook,blueprint,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose gxiLifecycleBoundary::p_discover;
        expose gxiLifecycleBoundary::p_loadPhase;
        expose gxiLifecycleBoundary::p_evaluate;
        expose gxiLifecycleBoundary::p_observeRun;
        expose gxiLifecycleBoundary::discover;
        expose gxiLifecycleBoundary::loaded;
        expose gxiLifecycleBoundary::returned;
        render asInterconnectionDiagram;
    }

    part def rpcCore_config :> ReaderNode {
        attribute displayName : String = "Governed config";
        attribute responsibility : String = "Typed Scheme or data";
        attribute glyph : String = "routine";
    }
    part def rpcCore_control :> ReaderNode {
        attribute displayName : String = "Rust source RPC";
        attribute responsibility : String = "Carry the bound proposal";
        attribute glyph : String = "routing";
        attribute illustration : String = "route-choice";
    }
    part def rpcCore_admit :> ReaderNode {
        attribute displayName : String = "Rust admission";
        attribute responsibility : String = "Check Cedar and claim";
        attribute glyph : String = "authorization";
        attribute illustration : String = "permission-check";
    }
    part def rpcCore_provider :> ReaderNode {
        attribute displayName : String = "Provider I/O";
        attribute responsibility : String = "Send the exact request";
        attribute glyph : String = "provider";
        attribute illustration : String = "model-provider";
    }
    part def rpcCore_release :> ReaderNode {
        attribute displayName : String = "Guarded stream";
        attribute responsibility : String = "Release under current Policy";
        attribute glyph : String = "stream";
    }
    part def rpcCore_metrics :> ReaderNode {
        attribute displayName : String = "Telemetry";
        attribute responsibility : String = "Observe bounded events";
        attribute glyph : String = "telemetry";
    }
    part rpcCoreBoundary {
        part p_config : rpcCore_config;
        part p_control : rpcCore_control;
        part p_admit : rpcCore_admit;
        part p_provider : rpcCore_provider;
        part p_release : rpcCore_release;
        part p_metrics : rpcCore_metrics;
        connection configure connect p_config.outgoing to p_control.incoming;
        connection propose connect p_control.outgoing to p_admit.incoming;
        connection mediate connect p_admit.outgoing to p_provider.incoming;
        connection stream connect p_provider.outgoing to p_release.incoming;
        connection observe connect p_admit.outgoing to p_metrics.incoming;
    }
    view rpcCore {
        attribute mappedFile : String = "docs/50-59-research-program/59-provider-rpc/59.03-provider-rpc-core.d2";
        attribute displayTitle : String = "Separate control RPC from provider I/O";
        attribute displaySubtitle : String = "Rust owns final admission and response release.";
        attribute displayEyebrow : String = "WEAVER / SCOPED READER VIEW";
        attribute readerQuestion : String = "How does the gRPC proposal become a bounded provider effect?";
        attribute designAudience : String = "Gateway design and runtime reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "Rust owns final admission and response release.";
        attribute designFocus : String = "p_admit";
        attribute visualThemes : String = "sketchbook,ocean,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        attribute visualNotation : String = "objects";
        attribute visualBands : String = "[[\"p_config\",\"p_control\",\"p_admit\"],[\"p_provider\",\"p_release\",\"p_metrics\"]]";
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose rpcCoreBoundary::p_config;
        expose rpcCoreBoundary::p_control;
        expose rpcCoreBoundary::p_admit;
        expose rpcCoreBoundary::p_provider;
        expose rpcCoreBoundary::p_release;
        expose rpcCoreBoundary::p_metrics;
        expose rpcCoreBoundary::configure;
        expose rpcCoreBoundary::propose;
        expose rpcCoreBoundary::mediate;
        expose rpcCoreBoundary::stream;
        expose rpcCoreBoundary::observe;
        render asInterconnectionDiagram;
    }

    part def floorTransport_goControl :> ReaderNode {
        attribute displayName : String = "Go proposal";
        attribute responsibility : String = "Authenticated gRPC";
        attribute glyph : String = "routing";
    }
    part def floorTransport_floor :> ReaderNode {
        attribute displayName : String = "Current floor";
        attribute responsibility : String = "Original authority state";
        attribute glyph : String = "ledger";
    }
    part def floorTransport_owner :> ReaderNode {
        attribute displayName : String = "Transport custody";
        attribute responsibility : String = "Fence old writers";
        attribute glyph : String = "authentication";
    }
    part def floorTransport_gate :> ReaderNode {
        attribute displayName : String = "Final admission";
        attribute responsibility : String = "Join fence and floor";
        attribute glyph : String = "authorization";
    }
    part def floorTransport_send :> ReaderNode {
        attribute displayName : String = "Bound HTTPS";
        attribute responsibility : String = "Actual request bytes";
        attribute glyph : String = "writer";
    }
    part floorTransportBoundary {
        part p_goControl : floorTransport_goControl;
        part p_floor : floorTransport_floor;
        part p_owner : floorTransport_owner;
        part p_gate : floorTransport_gate;
        part p_send : floorTransport_send;
        connection submit connect p_goControl.outgoing to p_gate.incoming;
        connection currentState connect p_floor.outgoing to p_gate.incoming;
        connection checkOwner connect p_owner.outgoing to p_gate.incoming;
        connection mediate connect p_gate.outgoing to p_send.incoming;
    }
    view floorTransport {
        attribute mappedFile : String = "docs/50-59-research-program/59-provider-rpc/59.43-floor-transport-owner.d2";
        attribute displayTitle : String = "Use the same current transport owner";
        attribute displaySubtitle : String = "Go can propose a send. The current Rust owner mediates it.";
        attribute displayEyebrow : String = "WEAVER / SCOPED READER VIEW";
        attribute readerQuestion : String = "Where do floor publication and final send serialize?";
        attribute designAudience : String = "Gateway design and runtime reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "Go can propose a send. The current Rust owner mediates it.";
        attribute designFocus : String = "p_gate";
        attribute visualThemes : String = "sketchbook,ember,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose floorTransportBoundary::p_goControl;
        expose floorTransportBoundary::p_floor;
        expose floorTransportBoundary::p_owner;
        expose floorTransportBoundary::p_gate;
        expose floorTransportBoundary::p_send;
        expose floorTransportBoundary::submit;
        expose floorTransportBoundary::currentState;
        expose floorTransportBoundary::checkOwner;
        expose floorTransportBoundary::mediate;
        render asInterconnectionDiagram;
    }

    part def parentReplay_parents :> ReaderNode {
        attribute displayName : String = "Required parents";
        attribute responsibility : String = "Preserve original scope";
        attribute glyph : String = "claim";
    }
    part def parentReplay_selection :> ReaderNode {
        attribute displayName : String = "Selected profile";
        attribute responsibility : String = "Add its constraints";
        attribute glyph : String = "routine";
    }
    part def parentReplay_review :> ReaderNode {
        attribute displayName : String = "Replay evidence";
        attribute responsibility : String = "Bind exact reviewed input";
        attribute glyph : String = "history";
    }
    part def parentReplay_contract :> ReaderNode {
        attribute displayName : String = "Combined contract";
        attribute responsibility : String = "Conjoin both constraints";
        attribute glyph : String = "policy";
    }
    part def parentReplay_actual :> ReaderNode {
        attribute displayName : String = "Rust final use";
        attribute responsibility : String = "Join contract and fence";
        attribute glyph : String = "authorization";
    }
    part parentReplayBoundary {
        part p_parents : parentReplay_parents;
        part p_selection : parentReplay_selection;
        part p_review : parentReplay_review;
        part p_contract : parentReplay_contract;
        part p_actual : parentReplay_actual;
        connection retain connect p_parents.outgoing to p_contract.incoming;
        connection conjoin connect p_selection.outgoing to p_contract.incoming;
        connection bindEvidence connect p_review.outgoing to p_actual.incoming;
        connection recheck connect p_contract.outgoing to p_actual.incoming;
    }
    view parentReplay {
        attribute mappedFile : String = "docs/50-59-research-program/59-provider-rpc/59.50-parent-contract-and-replay.d2";
        attribute displayTitle : String = "Conjoin required parent and selected rules";
        attribute displaySubtitle : String = "Replay confirms the original evidence. Current state still controls effects.";
        attribute displayEyebrow : String = "WEAVER / SCOPED READER VIEW";
        attribute readerQuestion : String = "Which contracts survive a new profile selection?";
        attribute designAudience : String = "Gateway design and runtime reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "Replay confirms the original evidence. Current state still controls effects.";
        attribute designFocus : String = "p_actual";
        attribute visualThemes : String = "sketchbook,field-notes,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose parentReplayBoundary::p_parents;
        expose parentReplayBoundary::p_selection;
        expose parentReplayBoundary::p_review;
        expose parentReplayBoundary::p_contract;
        expose parentReplayBoundary::p_actual;
        expose parentReplayBoundary::retain;
        expose parentReplayBoundary::conjoin;
        expose parentReplayBoundary::bindEvidence;
        expose parentReplayBoundary::recheck;
        render asInterconnectionDiagram;
    }

    part def runtimeAssets_promote :> ReaderNode {
        attribute displayName : String = "Promoted assets";
        attribute responsibility : String = "Owned production bytes";
        attribute glyph : String = "publication";
    }
    part def runtimeAssets_candidate :> ReaderNode {
        attribute displayName : String = "Typed candidate";
        attribute responsibility : String = "Original operation binding";
        attribute glyph : String = "message";
    }
    part def runtimeAssets_journal :> ReaderNode {
        attribute displayName : String = "Authority journal";
        attribute responsibility : String = "Read current head";
        attribute glyph : String = "ledger";
    }
    part def runtimeAssets_cas :> ReaderNode {
        attribute displayName : String = "Final publication CAS";
        attribute responsibility : String = "Compare source and fence";
        attribute glyph : String = "authorization";
    }
    part def runtimeAssets_pending :> ReaderNode {
        attribute displayName : String = "Unknown outcome";
        attribute responsibility : String = "Recover original intent";
        attribute glyph : String = "recovery";
    }
    part runtimeAssetsBoundary {
        part p_promote : runtimeAssets_promote;
        part p_candidate : runtimeAssets_candidate;
        part p_journal : runtimeAssets_journal;
        part p_cas : runtimeAssets_cas;
        part p_pending : runtimeAssets_pending;
        connection load connect p_promote.outgoing to p_candidate.incoming;
        connection submit connect p_candidate.outgoing to p_cas.incoming;
        connection compare connect p_journal.outgoing to p_cas.incoming;
        connection resolve connect p_cas.outgoing to p_pending.incoming;
    }
    view runtimeAssets {
        attribute mappedFile : String = "docs/50-59-research-program/59-provider-rpc/59.56-runtime-assets-and-authority-floor.d2";
        attribute displayTitle : String = "Admit assets against the current authority floor";
        attribute displaySubtitle : String = "Runtime bytes carry a candidate. The journal owns the deciding state.";
        attribute displayEyebrow : String = "WEAVER / SCOPED READER VIEW";
        attribute readerQuestion : String = "Can a promoted asset become execution authority on its own?";
        attribute designAudience : String = "Gateway design and runtime reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "Runtime bytes carry a candidate. The journal owns the deciding state.";
        attribute designFocus : String = "p_cas";
        attribute visualThemes : String = "sketchbook,blueprint,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose runtimeAssetsBoundary::p_promote;
        expose runtimeAssetsBoundary::p_candidate;
        expose runtimeAssetsBoundary::p_journal;
        expose runtimeAssetsBoundary::p_cas;
        expose runtimeAssetsBoundary::p_pending;
        expose runtimeAssetsBoundary::load;
        expose runtimeAssetsBoundary::submit;
        expose runtimeAssetsBoundary::compare;
        expose runtimeAssetsBoundary::resolve;
        render asInterconnectionDiagram;
    }

    part def embeddedTooling_caller :> ReaderNode {
        attribute displayName : String = "Typed Rust caller";
        attribute responsibility : String = "Exact foreign operation";
        attribute glyph : String = "message";
    }
    part def embeddedTooling_image :> ReaderNode {
        attribute displayName : String = "Linked Scheme image";
        attribute responsibility : String = "Match the captured closure";
        attribute glyph : String = "catalog";
    }
    part def embeddedTooling_owner :> ReaderNode {
        attribute displayName : String = "VM owner";
        attribute responsibility : String = "Check runtime custody";
        attribute glyph : String = "authorization";
    }
    part def embeddedTooling_scheme :> ReaderNode {
        attribute displayName : String = "Scheme operation";
        attribute responsibility : String = "Use existing semantics";
        attribute glyph : String = "routine";
    }
    part def embeddedTooling_observe :> ReaderNode {
        attribute displayName : String = "Completion evidence";
        attribute responsibility : String = "Report return or refusal";
        attribute glyph : String = "telemetry";
    }
    part embeddedToolingBoundary {
        part p_caller : embeddedTooling_caller;
        part p_image : embeddedTooling_image;
        part p_owner : embeddedTooling_owner;
        part p_scheme : embeddedTooling_scheme;
        part p_observe : embeddedTooling_observe;
        connection invoke connect p_caller.outgoing to p_owner.incoming;
        connection bindImage connect p_image.outgoing to p_owner.incoming;
        connection enter connect p_owner.outgoing to p_scheme.incoming;
        connection record connect p_scheme.outgoing to p_observe.incoming;
    }
    view embeddedTooling {
        attribute mappedFile : String = "docs/50-59-research-program/59-provider-rpc/59.76-embedded-tooling-and-darwin-io.d2";
        attribute displayTitle : String = "Follow a typed call to the owned Scheme VM";
        attribute displaySubtitle : String = "The linked image and runtime owner qualify the call and its cleanup.";
        attribute displayEyebrow : String = "WEAVER / SCOPED READER VIEW";
        attribute readerQuestion : String = "Who owns the Scheme runtime and its completion?";
        attribute designAudience : String = "Gateway design and runtime reviewers";
        attribute designMedium : String = "GitHub at 830 CSS pixels";
        attribute designMessage : String = "The linked image and runtime owner qualify the call and its cleanup.";
        attribute designFocus : String = "p_owner";
        attribute visualThemes : String = "sketchbook,field-notes,compact,reading";
        attribute visualOptions : String = "{\"elk.algorithm\":\"layered\",\"elk.direction\":\"DOWN\",\"elk.edgeRouting\":\"ORTHOGONAL\",\"elk.spacing.nodeNode\":\"16\",\"elk.layered.spacing.nodeNodeBetweenLayers\":\"27\"}";
        attribute visualWidth : Integer = 980;
        requirement originalAuthority : WeaverExecution::ConsumeBeforeSend;
        expose embeddedToolingBoundary::p_caller;
        expose embeddedToolingBoundary::p_image;
        expose embeddedToolingBoundary::p_owner;
        expose embeddedToolingBoundary::p_scheme;
        expose embeddedToolingBoundary::p_observe;
        expose embeddedToolingBoundary::invoke;
        expose embeddedToolingBoundary::bindImage;
        expose embeddedToolingBoundary::enter;
        expose embeddedToolingBoundary::record;
        render asInterconnectionDiagram;
    }
}
