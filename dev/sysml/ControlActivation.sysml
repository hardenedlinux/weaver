package ControlActivation {
    private import ScalarValues::*;
    requirement def SpecificSourceContracts {
        doc /* Each Scheme scope uses an evidence-bearing YuanxuContract whose value-contract delegates shape and normalization to concrete native Record and Function descriptors. Wire records are sealed, counters and credits are exact bounded integers, and Go and Rust independently validate the same artifact. Contract validity is required before registration and grants no execution authority. */
    }
    requirement def NativeGovernorHandoff {
        doc /* Scheme projects native governor open-patterns after denylist, conflict and max-actionable clipping. Selected nodes, original task nodes and plan nodes must form the same duplicate-free set. A typed inert Governance assessment must match the exact task/plan/publication source serialized with recursively sorted object keys while preserving array order and exact integers, Profile identity/revision/owner, threat-model identity and complete assessed threats. Native blocking threats cannot be erased by a ready flag. False Policy preflight or Governance results reject. Assessment is a trusted compilation fact, never a portable execution permit. Candidate actionable-patterns are not a qualified handoff or a monetary reservation. */
    }
    requirement def PolicyCAbiIsInert {
        doc /* Synchronous Gambit C FFI borrows bounded immutable UTF-8 data for Rust typed Cedar validation. No returned status, buffer, callback or source artifact is an execution capability. Rust final publication and execution repeat authoritative checks. */
    }
    requirement def ControlActivationAcknowledgment {
        doc /* Go exposes operation ingress only after original-task registration and an exact committed publication acknowledgment. Unknown outcomes cannot activate or trigger automatic rebase. Exact recovery may observe a historical decision without making it current authority. */
    }
    requirement def ControlStreamRecoveryBinding {
        doc /* Go compiles proposals against the frozen original task and forwards one Rust execution stream over mutual TLS gRPC. Source methods are absent from operation ingress. Shared budgets, original claims and unknown holds survive partial output, revocation, SDK retries and both process restarts. Previously authorized queue entries may drain after revocation. */
    }
    part def SchemeAuthor {
        attribute nativeOpenSelection : Boolean;
        attribute inertPolicyValidation : Boolean;
    }
    part def GoControl {
        attribute acknowledgedPublication : Boolean;
        attribute active : Boolean;
    }
    part def RustAuthority {
        attribute currentRevision : Integer;
        attribute consumed : Boolean;
        attribute heldBudget : Integer;
    }
}
