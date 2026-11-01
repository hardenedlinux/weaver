package WeaverViews {
    private import Views::*;
    private import StandardViewDefinitions::*;

    view architecture {
        expose WeaverExecution::gateway;
        render asInterconnectionDiagram;
    }

    view zeroTrust {
        doc /* Security perspective of the same Gateway, with no parallel
           authority topology. D2 emphasizes OriginalTaskBinding, SharedBudget,
           ConsumeBeforeSend, CurrentFinalGuard and UnknownRetainsHold. */
        expose WeaverExecution::gateway;
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
        expose WeaverProject::AssuranceResponsibilities::**;
        render asInterconnectionDiagram;
    }
}
