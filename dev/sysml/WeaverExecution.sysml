package WeaverExecution {
    doc /* Runtime allocation and safety requirements for the first executable profile. */

    requirement def OriginalTaskBinding {
        doc /* Preserve family, declared node, profile, endpoint and exact wire body commitment. */
    }
    requirement def SharedBudget {
        doc /* Original node holds sum to no more than the original family budget. */
    }
    requirement def ConsumeBeforeSend {
        doc /* Persist irreversible unknown consumption before any possible external bytes. */
    }
    requirement def CurrentFinalGuard {
        doc /* Serialize the final policy/history revision and fence check with actual send. */
    }
    requirement def UnknownRetainsHold {
        doc /* Crashes, lost replies and partial writes cannot prove no execution or refund capacity. */
    }
    requirement def NoImplicitRetry {
        doc /* One logical node has one consumed send opportunity; redirects and SDK retries are disabled. */
    }
    requirement def DevelopmentPolicy {
        doc /* ASP Rust is a deny-mode Cargo test dependency and is absent from the runtime graph. */
    }

    item def CanonicalProposal;
    item def DurableOutcome;
    item def ConsumedPermit;
    item def CanonicalWireRequest;
    port def ProposalPort {
        out item proposal : CanonicalProposal;
    }
    port def OutcomePort {
        out item observation : DurableOutcome;
    }
    port def ConsumedPort {
        out item permit : ConsumedPermit;
    }
    port def WirePort {
        out item request : CanonicalWireRequest;
    }
    part def SchemeSemanticPublisher {
        doc /* Existing POO composition owns semantic profiles and task assignments. Native admission integration is a separate delivery gate. */
    }
    part def GoControlAdapter {
        doc /* Refine routine node and routing preferences; emit data with no send capability. */
        port proposals : ProposalPort;
        port observations : ~OutcomePort;
    }
    part def RustPolicy {
        doc /* Evaluate Cedar against actual operation and authoritative deciding state; reject evaluation errors. */
    }
    part def RustLedger {
        doc /* One deciding store owns immutable tasks, reservations, logical keys, current revision and fence. */
        port proposals : ~ProposalPort;
        port observations : OutcomePort;
        port consumed : ConsumedPort;
    }
    part def RustFinalBroker {
        doc /* Use the consuming ledger handle; serialize the final guard through the bounded transport call. */
        port consumed : ~ConsumedPort;
        port wire : WirePort;
    }
    part def HttpsExecutor {
        doc /* Exact committed target and body, no inherited proxy, redirect or automatic retry. */
        port wire : ~WirePort;
    }
    part def TelemetryService {
        doc /* Default service in the target architecture; implementation and exporter delivery remain pending. Local bounded signals observe source/authority/effects. Export needs explicit configuration and Policy. Telemetry cannot acknowledge an authority commit, authorize a send or release unknown budget. */
    }
    action def Propose;
    action def Enqueue;
    action def Consume;
    action def GuardAndSend;
    action def RecoverOutcome {
        doc /* Go observes the Rust-owned durable result under the frozen
           publication identity and digest before submitting an absent decision.
           A known result is read-only recovery. Unknown or rejected results do
           not activate ingress. A historical receipt never replaces current
           Rust Policy, fence, original claim, history or budget checks. */
    }

    part gateway {
        part semanticPublisher : SchemeSemanticPublisher;
        part controlAdapter : GoControlAdapter;
        part policy : RustPolicy;
        part ledger : RustLedger;
        part broker : RustFinalBroker;
        part executor : HttpsExecutor;
        part telemetry : TelemetryService;
        connect controlAdapter.proposals to ledger.proposals;
        connect ledger.observations to controlAdapter.observations;
        connect ledger.consumed to broker.consumed;
        connect broker.wire to executor.wire;
    }
}
