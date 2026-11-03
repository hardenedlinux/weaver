-- SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
--
-- SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

import LlmResultProjection
namespace Weaver.LlmJoinEnqueue

-- This concrete lens covers the existing initialized source's execution channels.
structure SourceSignals where
  rootOffers : Nat → Nat
  childCalls : Nat → Nat
  dispatches : List Weaver.LlmRouting.Dispatch

def concreteSignals (s : Weaver.LlmCanonicalRegistry.State) : SourceSignals :=
  ⟨fun root => (s.base.base.base.publication.execution.roots.base.messages root).sends,
   s.base.base.base.publication.execution.children.calls,
   s.base.base.base.publication.execution.children.routes.dispatches⟩

def AdmissionOnly (R : Weaver.LlmMultiKeyRegistry.Request → S → S → Prop)
    (signals : S → E) (r : Weaver.LlmMultiKeyRegistry.Request) (a b : S) : Prop :=
  R r a b ∧ signals a = signals b

structure Operation where
  key : Nat
  request : Weaver.LlmMultiKeyRegistry.Request
  scope : Weaver.LogicalRangeRecovery.Scope
  profile : Nat
  deriving DecidableEq
structure Slot where
  root : Nat
  claim : Nat
  lo : Nat
  hi : Nat
  deriving DecidableEq

def slot (op : Operation) : Slot := ⟨op.scope.root,op.scope.claim,op.scope.lo,op.scope.hi⟩
structure Permit (S : Type) where
  operation : Operation
  position : Nat
  image : Weaver.LlmResultProjection.Image S
  epoch : Nat
  policy : Nat
  queueRevision : Nat
structure State (S : Type) where
  base : Weaver.LlmResultProjection.State S
  policy : Nat := 0
  queueRevision : Nat := 0
  issued : List (Permit S) := []
  queued : Nat → Option Operation := fun _ => none
  admissions : List (Permit S) := []
  claimed : Slot → Option Operation := fun _ => none

structure Owner (S : Type) where
  operationValid : Operation → Weaver.LlmResultProjection.State S → Prop
  finalPolicyValid : Operation → Weaver.LlmResultProjection.State S → Nat → Prop
  durableAdmission : Permit S → Prop

def initial (seed : S) : State S := ⟨Weaver.LlmResultProjection.initial seed,0,0,[],fun _ => none,[],fun _ => none⟩
def permit (s : State S) (op : Operation) : Permit S :=
  ⟨op,s.base.log.length,Weaver.LlmResultProjection.image s.base.base,s.base.base.fence,s.policy,s.queueRevision⟩
def Gate (s : State S) (p : Permit S) : Prop :=
  p ∈ s.issued ∧ Weaver.LlmResultProjection.Joined s.base ∧
  s.base.qualified = true ∧ s.base.active = true ∧
  p.position = s.base.log.length ∧ p.image = Weaver.LlmResultProjection.image s.base.base ∧
  p.epoch = s.base.base.fence ∧ p.policy = s.policy ∧ p.queueRevision = s.queueRevision

inductive Step (R : Weaver.LlmMultiKeyRegistry.Request → S → S → Prop)
    (signals : S → E) (A : Weaver.LlmMultiKeyRegistry.Entry → Prop) (limit : Nat)
    (Q : Weaver.LlmMultiKeyRegistry.State S → Prop) (V : Weaver.LlmResultProjection.State S → Prop)
    (owner : Owner S) (seed : S) : State S → State S → Prop where
  | background (s next) (actual : Weaver.LlmResultProjection.Step (AdmissionOnly R signals) A limit Q V seed s.base next) :
      Step R signals A limit Q V owner seed s {s with base := next}
  | resolve (s op) (joined : Weaver.LlmResultProjection.Joined s.base)
      (qualified : s.base.qualified = true) (active : s.base.active = true)
      (original : ∃ result ∈ s.base.log, result.request = op.request)
      (bound : owner.operationValid op s.base) :
      Step R signals A limit Q V owner seed s {s with issued := s.issued ++ [permit s op]}
  | policyChange (s) : Step R signals A limit Q V owner seed s {s with policy := s.policy+1}
  | enqueue (s p worker) (gate : Gate s p) (current : worker = s.base.base.fence)
      (original : ∃ result ∈ s.base.log, result.request = p.operation.request)
      (bound : owner.operationValid p.operation s.base)
      (policy : owner.finalPolicyValid p.operation s.base s.policy)
      (fresh : s.queued p.operation.key = none) (slotFresh : s.claimed (slot p.operation) = none) (durable : owner.durableAdmission p) :
      Step R signals A limit Q V owner seed s {s with queued := Weaver.LlmMultiKeyRegistry.put s.queued p.operation.key (some p.operation), admissions := s.admissions ++ [p], queueRevision := s.queueRevision+1, claimed := Weaver.LlmMultiKeyRegistry.put s.claimed (slot p.operation) (some p.operation)}
  | observe (s) : Step R signals A limit Q V owner seed s s

inductive Run (R : Weaver.LlmMultiKeyRegistry.Request → S → S → Prop)
    (signals : S → E) (A : Weaver.LlmMultiKeyRegistry.Entry → Prop) (limit : Nat)
    (Q : Weaver.LlmMultiKeyRegistry.State S → Prop) (V : Weaver.LlmResultProjection.State S → Prop)
    (owner : Owner S) (seed : S) : State S → State S → Prop where
  | refl (s) : Run R signals A limit Q V owner seed s s
  | next (prior : Run R signals A limit Q V owner seed s t) (event : Step R signals A limit Q V owner seed t u) : Run R signals A limit Q V owner seed s u

theorem result_projection (run : Run R signals A limit Q V owner seed s t) :
    Weaver.LlmResultProjection.Run (AdmissionOnly R signals) A limit Q V seed s.base t.base := by
  induction run with
  | refl => exact .refl _
  | next _ event ih =>
    cases event with
    | background _ actual => exact .next ih actual
    | resolve => exact ih
    | policyChange => exact ih
    | enqueue => exact ih
    | observe => exact ih

theorem admission_source_has_no_send (run : Run R signals A limit Q V owner seed s t) :
    signals s.base.base.source = signals t.base.base.source := by
  have sourcePath := Weaver.LlmMultiKeyRegistry.source_projection (Weaver.LlmResultProjection.authority_projection (result_projection run))
  exact Weaver.LlmMultiKeyRegistry.composition sourcePath
    (fun value => signals s.base.base.source = signals value) rfl
    (fun _ _ _ event ih => ih.trans event.2)

theorem queue_step_immutable (event : Step R signals A limit Q V owner seed s t)
    (known : s.queued key = some op) : t.queued key = some op := by
  cases event <;> simp_all [Weaver.LlmMultiKeyRegistry.put]
  intro same; subst key; simp_all

theorem original_operation_never_replaced (run : Run R signals A limit Q V owner seed s t)
    (known : s.queued key = some op) : t.queued key = some op := by
  induction run with
  | refl => exact known
  | next _ event ih => exact queue_step_immutable event ih

theorem old_prefix_blocks_enqueue (old : p.position ≠ s.base.log.length) : ¬ Gate s p := by
  intro gate; exact old gate.2.2.2.2.1

theorem old_owner_blocks_enqueue (old : p.epoch ≠ s.base.base.fence) : ¬ Gate s p := by
  intro gate; exact old gate.2.2.2.2.2.2.1

theorem old_policy_blocks_enqueue (old : p.policy ≠ s.policy) : ¬ Gate s p := by
  intro gate; exact old gate.2.2.2.2.2.2.2.1

theorem old_queue_revision_blocks_enqueue (old : p.queueRevision ≠ s.queueRevision) : ¬ Gate s p := by
  intro gate; exact old gate.2.2.2.2.2.2.2.2

theorem incomplete_join_blocks_enqueue (incomplete : ¬ Weaver.LlmResultProjection.Joined s.base) : ¬ Gate s p := by
  intro gate; exact incomplete gate.2.1

theorem enqueue_has_no_source_effect (s : State S) (p : Permit S) :
    ({s with queued := Weaver.LlmMultiKeyRegistry.put s.queued p.operation.key (some p.operation), admissions := s.admissions ++ [p], queueRevision := s.queueRevision+1, claimed := Weaver.LlmMultiKeyRegistry.put s.claimed (slot p.operation) (some p.operation)} : State S).base = s.base := rfl

theorem original_unknown_exposure_retained (run : Run R signals A limit Q V owner seed s t) : s.base.base.charged ≤ t.base.base.charged :=
  Weaver.LlmResultProjection.unknown_exposure_retained (result_projection run)

theorem original_spent_retained (run : Run R signals A limit Q V owner seed s t) (spent : s.base.base.spent nonce = true) : t.base.base.spent nonce = true :=
  Weaver.LlmResultProjection.original_spent_retained (result_projection run) spent

-- Queue acceptance projects into the existing broker model without invoking it.
-- This is an abstraction of the already committed source consumption, not a
-- second native nonce consumption. Native authentication stays in Owner above.
def brokerReady : Weaver.BrokerConsumptionQueue.State := {spent := true,intent := true,accepted := true}
def brokerProjection (s : State S) (key : Nat) : Weaver.BrokerConsumptionQueue.State :=
  match s.queued key with
  | none => Weaver.BrokerConsumptionQueue.initial
  | some _ => brokerReady

theorem ready_broker_initialized (length : Nat) :
    Weaver.BrokerConsumptionQueue.Run Weaver.LogicalRangeRecovery.abstractOwner length Weaver.BrokerConsumptionQueue.initial brokerReady := by
  exact .next (.next (.next (.refl _) (.consume _ rfl)) (.persistIntent _ rfl)) (.accept _ rfl rfl)

theorem queue_broker_initialized (s : State S) (key length : Nat) :
    Weaver.BrokerConsumptionQueue.Run Weaver.LogicalRangeRecovery.abstractOwner length Weaver.BrokerConsumptionQueue.initial (brokerProjection s key) := by
  cases h : s.queued key with
  | none => simp [brokerProjection,h]; exact .refl _
  | some op => simpa [brokerProjection,h] using ready_broker_initialized length

theorem enqueue_has_zero_transport_calls (s : State S) (key offset : Nat) : (brokerProjection s key).calls offset = 0 := by
  cases h : s.queued key <;> simp [brokerProjection,h,brokerReady,Weaver.BrokerConsumptionQueue.initial]

theorem actual_broker_suffix_once (s : State S) (key offset length : Nat)
    (suffix : Weaver.BrokerConsumptionQueue.Run Weaver.LogicalRangeRecovery.abstractOwner length (brokerProjection s key) next) : next.calls offset ≤ 1 := by
  have initializedBroker := queue_broker_initialized s key length
  have combined : Weaver.BrokerConsumptionQueue.Run Weaver.LogicalRangeRecovery.abstractOwner length Weaver.BrokerConsumptionQueue.initial next := by
    induction suffix with
    | refl => exact initializedBroker
    | next _ event ih => exact .next ih event
  exact Weaver.BrokerConsumptionQueue.initialized_at_most_one_invocation combined offset

theorem actual_broker_unknown_stays_held (s : State S) (key length : Nat)
    (suffix : Weaver.BrokerConsumptionQueue.Run Weaver.LogicalRangeRecovery.abstractOwner length (brokerProjection s key) next)
    (unknown : next.unknown = true) : Weaver.BrokerConsumptionQueue.Held next := by
  have initializedBroker := queue_broker_initialized s key length
  have combined : Weaver.BrokerConsumptionQueue.Run Weaver.LogicalRangeRecovery.abstractOwner length Weaver.BrokerConsumptionQueue.initial next := by
    clear unknown
    induction suffix with
    | refl => exact initializedBroker
    | next _ event ih => exact .next ih event
  exact Weaver.BrokerConsumptionQueue.unknown_retains_original_hold combined unknown

theorem slot_step_immutable (event : Step R signals A limit Q V owner seed s t)
    (known : s.claimed identity = some op) : t.claimed identity = some op := by
  cases event <;> simp_all [Weaver.LlmMultiKeyRegistry.put]
  intro same; subst identity; simp_all

theorem original_slot_never_replaced (run : Run R signals A limit Q V owner seed s t)
    (known : s.claimed identity = some op) : t.claimed identity = some op := by
  induction run with
  | refl => exact known
  | next _ event ih => exact slot_step_immutable event ih

theorem occupied_slot_blocks_retry (run : Run R signals A limit Q V owner seed s t)
    (known : s.claimed (slot op) = some original) : t.claimed (slot op) ≠ none := by
  have still := original_slot_never_replaced run known
  simp [still]

theorem new_admission_has_current_gate (event : Step R signals A limit Q V owner seed s t)
    (stored : receipt ∈ t.admissions) (absent : receipt ∉ s.admissions) :
    Gate s receipt ∧ owner.finalPolicyValid receipt.operation s.base s.policy ∧ owner.operationValid receipt.operation s.base := by
  cases event with
  | enqueue p worker gate current original bound policy fresh slotFresh durable =>
    have same : receipt = p := by simpa [absent] using stored
    subst receipt
    exact ⟨gate,policy,bound⟩
  | _ => exact False.elim (absent stored)

#print axioms result_projection
#print axioms admission_source_has_no_send
#print axioms original_operation_never_replaced
#print axioms old_prefix_blocks_enqueue
#print axioms old_owner_blocks_enqueue
#print axioms old_policy_blocks_enqueue
#print axioms old_queue_revision_blocks_enqueue
#print axioms incomplete_join_blocks_enqueue
#print axioms enqueue_has_no_source_effect
#print axioms original_unknown_exposure_retained
#print axioms original_spent_retained
#print axioms ready_broker_initialized
#print axioms queue_broker_initialized
#print axioms enqueue_has_zero_transport_calls
#print axioms actual_broker_suffix_once
#print axioms actual_broker_unknown_stays_held
#print axioms original_slot_never_replaced
#print axioms occupied_slot_blocks_retry
#print axioms new_admission_has_current_gate
end Weaver.LlmJoinEnqueue
