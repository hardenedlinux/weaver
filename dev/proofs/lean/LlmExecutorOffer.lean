-- SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
--
-- SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

import LlmJoinEnqueue
namespace Weaver.LlmExecutorOffer

structure Ticket (S : Type) where
  view : Weaver.LlmJoinEnqueue.Permit S
  rangeEpoch : Nat
  rangeRevision : Nat
  rangePermit : Weaver.LogicalRangeRecovery.Permit
structure State (S : Type) where
  base : Weaver.LlmJoinEnqueue.State S
  lane : Weaver.LogicalRangeRecovery.State := Weaver.LogicalRangeRecovery.initial
  laneOwner : Nat := 0
  dequeued : Bool := false
  tickets : List (Ticket S) := []
  burn : Option (Ticket S) := none
  submitted : Bool := false
  offers : List (Ticket S) := []
  executionQualified : Bool := true
structure Owner (S : Type) where
  operationValid : Weaver.LlmJoinEnqueue.Operation → Weaver.LlmJoinEnqueue.State S → Prop
  burnPolicyValid : Weaver.LlmJoinEnqueue.Operation → State S → Prop
  offerPolicyValid : Weaver.LlmJoinEnqueue.Operation → State S → Prop
  burnDurable : Ticket S → Prop
  submitDurable : Ticket S → Prop
  executionRecoveryValid : State S → Prop
  backgroundValid : State S → Weaver.LlmJoinEnqueue.State S → Prop

def initial (seed : S) : State S := ⟨Weaver.LlmJoinEnqueue.initial seed,Weaver.LogicalRangeRecovery.initial,0,false,[],none,false,[],true⟩
def Registered (op : Weaver.LlmJoinEnqueue.Operation) (s : State S) : Prop :=
  s.base.queued op.key = some op ∧ s.base.claimed (Weaver.LlmJoinEnqueue.slot op) = some op

def ticket (op : Weaver.LlmJoinEnqueue.Operation) (s : State S) (p : Weaver.LogicalRangeRecovery.Permit) : Ticket S :=
  ⟨Weaver.LlmJoinEnqueue.permit s.base op,s.lane.epoch,s.lane.revision,p⟩
def Gate (op : Weaver.LlmJoinEnqueue.Operation) (s : State S) (t : Ticket S) (worker : Nat) : Prop :=
  Registered op s ∧ s.dequeued = true ∧ t ∈ s.tickets ∧
  t.view = Weaver.LlmJoinEnqueue.permit s.base op ∧
  s.base.base.qualified = true ∧ s.base.base.active = true ∧
  Weaver.LlmResultProjection.Joined s.base.base ∧
  worker = s.base.base.base.fence ∧ s.laneOwner = s.base.base.base.fence ∧
  t.rangeEpoch = s.lane.epoch ∧ t.rangeRevision = s.lane.revision ∧
  s.lane.permit = some t.rangePermit ∧ s.executionQualified = true

inductive Step (op : Weaver.LlmJoinEnqueue.Operation) (rangeOwner : Weaver.LogicalRangeRecovery.Owner)
    (R : Weaver.LlmMultiKeyRegistry.Request → S → S → Prop) (signals : S → E)
    (A : Weaver.LlmMultiKeyRegistry.Entry → Prop) (limit : Nat)
    (Q : Weaver.LlmMultiKeyRegistry.State S → Prop) (V : Weaver.LlmResultProjection.State S → Prop)
    (queueOwner : Weaver.LlmJoinEnqueue.Owner S) (owner : Owner S) (seed : S) : State S → State S → Prop where
  | background (s next) (actual : Weaver.LlmJoinEnqueue.Step R signals A limit Q V queueOwner seed s.base next)
      (executionSafe : owner.backgroundValid s next) :
      Step op rangeOwner R signals A limit Q V queueOwner owner seed s {s with base := next, executionQualified := if next.base.base.fence = s.base.base.base.fence then s.executionQualified else false}
  | recoverExecution (s) (closed : s.executionQualified = false)
      (sourceQualified : s.base.base.qualified = true) (evidence : owner.executionRecoveryValid s) :
      Step op rangeOwner R signals A limit Q V queueOwner owner seed s {s with executionQualified := true}
  | dequeue (s worker) (registered : Registered op s) (fresh : s.dequeued = false)
      (workerCurrent : worker = s.base.base.base.fence) (qualified : s.base.base.qualified = true)
      (bound : owner.operationValid op s.base) :
      Step op rangeOwner R signals A limit Q V queueOwner owner seed s {s with dequeued := true}
  | alignOwner (s worker) (registered : Registered op s) (workerCurrent : worker = s.base.base.base.fence)
      (qualified : s.base.base.qualified = true) (execution : s.executionQualified = true) (changed : s.laneOwner ≠ s.base.base.base.fence) :
      Step op rangeOwner R signals A limit Q V queueOwner owner seed s {s with laneOwner := s.base.base.base.fence, lane := {s.lane with epoch := s.lane.epoch+1, revision := s.lane.revision+1, fenced := true, permit := none, observed := none}}
  | laneProgress (s next) (registered : Registered op s)
      (actual : Weaver.LogicalRangeRecovery.Step op.scope rangeOwner s.lane next)
      (noOffer : next.calls = s.lane.calls) :
      Step op rangeOwner R signals A limit Q V queueOwner owner seed s {s with lane := next}
  | observe (s p worker) (registered : Registered op s) (dequeued : s.dequeued = true)
      (workerCurrent : worker = s.base.base.base.fence) (laneCurrent : s.laneOwner = s.base.base.base.fence)
      (qualified : s.base.base.qualified = true) (active : s.base.base.active = true)
      (joined : Weaver.LlmResultProjection.Joined s.base.base) (execution : s.executionQualified = true) (held : s.lane.permit = some p)
      (bound : owner.operationValid op s.base) :
      Step op rangeOwner R signals A limit Q V queueOwner owner seed s {s with tickets := s.tickets ++ [ticket op s p]}
  | burn (s t worker) (gate : Gate op s t worker) (bound : owner.operationValid op s.base)
      (policy : owner.burnPolicyValid op s) (fresh : s.burn = none) (unused : s.lane.calls = 0)
      (durable : owner.burnDurable t) :
      Step op rangeOwner R signals A limit Q V queueOwner owner seed s {s with burn := some t}
  | offer (s t next worker) (gate : Gate op s t worker) (bound : owner.operationValid op s.base)
      (policy : owner.offerPolicyValid op s) (burned : s.burn = some t)
      (fresh : s.submitted = false)
      (actual : Weaver.LogicalRangeRecovery.Step op.scope rangeOwner s.lane next)
      (invoked : next.calls = s.lane.calls+1) (durable : owner.submitDurable t) :
      Step op rangeOwner R signals A limit Q V queueOwner owner seed s {s with lane := next, submitted := true, offers := s.offers ++ [t]}

inductive Run (op : Weaver.LlmJoinEnqueue.Operation) (rangeOwner : Weaver.LogicalRangeRecovery.Owner)
    (R : Weaver.LlmMultiKeyRegistry.Request → S → S → Prop) (signals : S → E)
    (A : Weaver.LlmMultiKeyRegistry.Entry → Prop) (limit : Nat)
    (Q : Weaver.LlmMultiKeyRegistry.State S → Prop) (V : Weaver.LlmResultProjection.State S → Prop)
    (queueOwner : Weaver.LlmJoinEnqueue.Owner S) (owner : Owner S) (seed : S) : State S → State S → Prop where
  | refl (s) : Run op rangeOwner R signals A limit Q V queueOwner owner seed s s
  | next (prior : Run op rangeOwner R signals A limit Q V queueOwner owner seed s t)
      (event : Step op rangeOwner R signals A limit Q V queueOwner owner seed t u) :
      Run op rangeOwner R signals A limit Q V queueOwner owner seed s u

theorem queue_projection (run : Run op rangeOwner R signals A limit Q V queueOwner owner seed s t) :
    Weaver.LlmJoinEnqueue.Run R signals A limit Q V queueOwner seed s.base t.base := by
  induction run with
  | refl => exact .refl _
  | next _ event ih =>
    cases event with
    | background _ actual _ => exact .next ih actual
    | _ => exact ih

theorem range_projection (run : Run op rangeOwner R signals A limit Q V queueOwner owner seed s t) :
    Weaver.LogicalRangeRecovery.Run op.scope rangeOwner s.lane t.lane := by
  induction run with
  | refl => exact .refl _
  | next _ event ih =>
    cases event with
    | alignOwner => exact .next ih (.fence _)
    | laneProgress _ _ actual _ => exact .next ih actual
    | offer _ _ _ _ _ _ _ _ actual _ _ => exact .next ih actual
    | _ => exact ih

theorem offer_at_most_once (run : Run op rangeOwner R signals A limit Q V queueOwner owner seed (initial seed) s) : s.lane.calls ≤ 1 :=
  (Weaver.LogicalRangeRecovery.initialized_safe (range_projection run)).1

theorem burn_step_retained (event : Step op rangeOwner R signals A limit Q V queueOwner owner seed s t)
    (known : s.burn = some original) : t.burn = some original := by
  cases event <;> simp_all

theorem original_burn_retained (run : Run op rangeOwner R signals A limit Q V queueOwner owner seed s t)
    (known : s.burn = some original) : t.burn = some original := by
  induction run with
  | refl => exact known
  | next _ event ih => exact burn_step_retained event ih

theorem submitted_step_retained (event : Step op rangeOwner R signals A limit Q V queueOwner owner seed s t)
    (known : s.submitted = true) : t.submitted = true := by
  cases event <;> simp_all

theorem submitted_never_reset (run : Run op rangeOwner R signals A limit Q V queueOwner owner seed s t)
    (known : s.submitted = true) : t.submitted = true := by
  induction run with
  | refl => exact known
  | next _ event ih => exact submitted_step_retained event ih

theorem new_offer_checks_current_policy (event : Step op rangeOwner R signals A limit Q V queueOwner owner seed s t)
    (newTicket : p ∈ t.offers) (absent : p ∉ s.offers) :
    ∃ worker, Gate op s p worker ∧ owner.offerPolicyValid op s ∧ owner.operationValid op s.base := by
  cases event with
  | offer ticket next worker gate bound policy burned fresh actual invoked durable =>
    have same : p = ticket := by simpa [absent] using newTicket
    subst p; exact ⟨worker,gate,policy,bound⟩
  | _ => exact False.elim (absent newTicket)

theorem offer_gate_has_current_view (gate : Gate op s p worker) : p.view = Weaver.LlmJoinEnqueue.permit s.base op := gate.2.2.2.1

theorem old_worker_blocks_offer (old : worker ≠ s.base.base.base.fence) : ¬ Gate op s p worker := by
  intro gate; exact old gate.2.2.2.2.2.2.2.1

theorem unaligned_lane_blocks_offer (old : s.laneOwner ≠ s.base.base.base.fence) : ¬ Gate op s p worker := by
  intro gate; exact old gate.2.2.2.2.2.2.2.2.1

theorem changed_view_blocks_offer (old : p.view ≠ Weaver.LlmJoinEnqueue.permit s.base op) : ¬ Gate op s p worker := by
  intro gate; exact old (offer_gate_has_current_view gate)

theorem partial_or_timeout_has_no_authority (op : Weaver.LlmJoinEnqueue.Operation) (rangeOwner : Weaver.LogicalRangeRecovery.Owner) (s : State S) :
    Weaver.LogicalRangeRecovery.Step op.scope rangeOwner s.lane s.lane := .partialOrTimeout _

theorem original_queue_binding_retained (run : Run op rangeOwner R signals A limit Q V queueOwner owner seed s t)
    (known : s.base.queued op.key = some op) : t.base.queued op.key = some op :=
  Weaver.LlmJoinEnqueue.original_operation_never_replaced (queue_projection run) known

theorem original_slot_retained (run : Run op rangeOwner R signals A limit Q V queueOwner owner seed s t)
    (known : s.base.claimed (Weaver.LlmJoinEnqueue.slot op) = some op) :
    t.base.claimed (Weaver.LlmJoinEnqueue.slot op) = some op :=
  Weaver.LlmJoinEnqueue.original_slot_never_replaced (queue_projection run) known

theorem original_exposure_retained (run : Run op rangeOwner R signals A limit Q V queueOwner owner seed s t) :
    s.base.base.base.charged ≤ t.base.base.base.charged :=
  Weaver.LlmJoinEnqueue.original_unknown_exposure_retained (queue_projection run)

theorem dequeue_has_no_invocation (s : State S) : ({s with dequeued := true} : State S).lane.calls = s.lane.calls := rfl

theorem burn_has_no_invocation (s : State S) (p : Ticket S) : ({s with burn := some p} : State S).lane.calls = s.lane.calls := rfl

-- A current logical range path composes with the prior actual broker abstraction.
theorem actual_broker_initialized (run : Run op rangeOwner R signals A limit Q V queueOwner owner seed (initial seed) s)
    (nonempty : op.scope.lo < op.scope.hi) :
    Weaver.BrokerConsumptionQueue.Run Weaver.LogicalRangeRecovery.abstractOwner (Weaver.LogicalRangeRecovery.span op.scope)
      Weaver.BrokerConsumptionQueue.initial (Weaver.LogicalRangeRecovery.project op.scope s.lane) :=
  Weaver.LogicalRangeRecovery.initialized_data_path_refines_queue (range_projection run) nonempty

theorem unknown_retains_broker_hold (run : Run op rangeOwner R signals A limit Q V queueOwner owner seed (initial seed) s)
    (nonempty : op.scope.lo < op.scope.hi) (unknown : s.lane.unknown = true) :
    Weaver.BrokerConsumptionQueue.Held (Weaver.LogicalRangeRecovery.project op.scope s.lane) := by
  apply Weaver.BrokerConsumptionQueue.unknown_retains_original_hold (actual_broker_initialized run nonempty)
  simpa [Weaver.LogicalRangeRecovery.project] using unknown

theorem execution_recovery_preserves_burn (s : State S) :
    ({s with executionQualified := true} : State S).burn = s.burn := rfl

theorem invocation_requires_current_gate (event : Step op rangeOwner R signals A limit Q V queueOwner owner seed s t)
    (changed : t.lane.calls ≠ s.lane.calls) :
    ∃ p worker, Gate op s p worker ∧ owner.offerPolicyValid op s ∧ s.burn = some p ∧ s.submitted = false := by
  cases event with
  | offer p next worker gate bound policy burned fresh actual invoked durable =>
    exact ⟨p,worker,gate,policy,burned,fresh⟩
  | laneProgress next registered actual noOffer => exact False.elim (changed noOffer)
  | _ => exact False.elim (changed rfl)

#print axioms queue_projection
#print axioms range_projection
#print axioms offer_at_most_once
#print axioms original_burn_retained
#print axioms submitted_never_reset
#print axioms new_offer_checks_current_policy
#print axioms offer_gate_has_current_view
#print axioms old_worker_blocks_offer
#print axioms unaligned_lane_blocks_offer
#print axioms changed_view_blocks_offer
#print axioms partial_or_timeout_has_no_authority
#print axioms original_queue_binding_retained
#print axioms original_slot_retained
#print axioms original_exposure_retained
#print axioms dequeue_has_no_invocation
#print axioms burn_has_no_invocation
#print axioms actual_broker_initialized
#print axioms unknown_retains_broker_hold
#print axioms execution_recovery_preserves_burn
#print axioms invocation_requires_current_gate
end Weaver.LlmExecutorOffer
