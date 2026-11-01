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

    view zeroTrust {
        requirement specContract : WeaverZeroTrust::ZeroTrustContractRefinement;
        requirement executionContract : WeaverExecution::ConsumeBeforeSend;
        attribute mappedFile : String = "docs/architecture/diagrams/00d-zero-trust-overview.d2";
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
        attribute mappedFile : String = "docs/architecture/diagrams/00c-readme-assurance.d2";
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
}
