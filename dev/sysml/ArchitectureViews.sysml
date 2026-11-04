// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package WeaverViews {
    private import ScalarValues::*;
    private import Views::*;
    private import StandardViewDefinitions::*;

    view architecture {
        requirement specContract : WeaverZeroTrust::ZeroTrustContractRefinement;
        requirement executionContract : WeaverExecution::ConsumeBeforeSend;
        attribute mappedFile : String = "docs/architecture/diagrams/00a-readme-overview.d2";
        attribute displayTitle : String = "Governed work. One execution boundary.";
        attribute displaySubtitle : String = "Scheme defines meaning. Go coordinates. Rust controls actual effects.";
        attribute readerQuestion : String = "Who owns each part of an agent request?";
        attribute displayEyebrow : String = "WEAVER / AGENT GATEWAY";
        expose WeaverExecution::gateway::semanticPublisher;
        expose WeaverExecution::gateway::controlAdapter;
        expose WeaverExecution::gateway::policy;
        expose WeaverExecution::gateway::ledger;
        expose WeaverExecution::gateway::broker;
        expose WeaverExecution::gateway::executor;
        expose WeaverExecution::gateway::provider;
        expose WeaverExecution::gateway::telemetry;
        expose WeaverExecution::gateway::derivedEvidence;
        expose WeaverExecution::gateway::semanticPublisher_sourceCandidates_to_controlAdapter_sourceCandidates;
        expose WeaverExecution::gateway::controlAdapter_sourceCommands_to_ledger_sourceCommands;
        expose WeaverExecution::gateway::ledger_sourceOutcomes_to_controlAdapter_sourceOutcomes;
        expose WeaverExecution::gateway::controlAdapter_semanticObservations_to_semanticPublisher_sourceObservations;
        expose WeaverExecution::gateway::ledger_effectOutcomes_to_controlAdapter_effectObservations;
        expose WeaverExecution::gateway::controlAdapter_semanticEffectObservations_to_semanticPublisher_effectObservations;
        expose WeaverExecution::gateway::derivedEvidence_candidates_to_semanticPublisher_derivedFacts;
        expose WeaverExecution::gateway::controlAdapter_proposals_to_ledger_proposals;
        expose WeaverExecution::gateway::ledger_policyEvaluation_to_policy_evaluation;
        expose WeaverExecution::gateway::ledger_observations_to_controlAdapter_observations;
        expose WeaverExecution::gateway::ledger_consumed_to_broker_consumed;
        expose WeaverExecution::gateway::broker_wire_to_executor_wire;
        expose WeaverExecution::gateway::executor_provider_to_provider_request;
        render asInterconnectionDiagram;
    }

    view contractRefinement {
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
        expose WeaverZeroTrust::refinement::core_requirements_to_usage_core;
        expose WeaverZeroTrust::refinement::usage_requirements_to_application_usage;
        expose WeaverZeroTrust::refinement::parents_requirements_to_application_parents;
        expose WeaverZeroTrust::refinement::application_requirements_to_enforcement_requirements;
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
        expose WeaverExecution::gateway::semanticPublisher_sourceCandidates_to_controlAdapter_sourceCandidates;
        expose WeaverExecution::gateway::controlAdapter_sourceCommands_to_ledger_sourceCommands;
        expose WeaverExecution::gateway::ledger_policyEvaluation_to_policy_evaluation;
        expose WeaverExecution::gateway::ledger_consumed_to_broker_consumed;
        expose WeaverExecution::gateway::broker_wire_to_executor_wire;
        render asInterconnectionDiagram;
    }

    view storage {
        attribute layoutColumns:Integer=1;
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
        requirement progress : StreamingExecution::DurableRangeProgressJoin;
        requirement finalUse : StreamingExecution::RangeFinalGuard;
        attribute mappedFile : String = "docs/50-59-research-program/58-streaming-execution/58.05-range-progress-recovery.d2";
        attribute displayTitle : String = "Recovery cannot unspend a range.";
        attribute displaySubtitle : String = "Durable consumption constrains message progress, custody and final bytes.";
        attribute readerQuestion : String = "What prevents a stale queued message from reopening a spent prefix?";
        attribute displayEyebrow : String = "WEAVER / STREAM RECOVERY";
        expose StreamingExecution::streamingPath::adapter;
        expose StreamingExecution::streamingPath::server;
        expose StreamingExecution::streamingPath::ledger;
        expose StreamingExecution::streamingPath::guard;
        expose StreamingExecution::streamingPath::transport;
        expose StreamingExecution::streamingPath::retained;
        expose StreamingExecution::streamingPath::propose;
        expose StreamingExecution::streamingPath::admit;
        expose StreamingExecution::streamingPath::consume;
        expose StreamingExecution::streamingPath::writeRange;
        expose StreamingExecution::streamingPath::observe;
        expose StreamingExecution::streamingPath::retain;
        render asInterconnectionDiagram;
    }

    view gateway {
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
