-- SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
--
-- SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

import Std

namespace Weaver.ProviderAdmissionTurn

/-- A queue entry has no native claim/reservation, outcome acknowledgment or
    published semantic intent. Source Policy/OAuth intents use the early barrier. -/
structure State (Image : Type) where
  actual : Image
  queued : List Nat
  granted : Bool
  closed : Bool
  hardPending : Bool
  known : Bool
  failed : Bool

def enqueue (s : State I) (id : Nat) : State I := {s with queued := s.queued ++ [id]}

def CanOffer (s : State I) (qualified : I) : Prop :=
  s.known = true ∧ s.failed = false ∧ s.closed = false ∧
  s.hardPending = false ∧ qualified = s.actual

theorem queue_preserves_actual (s : State I) (id : Nat) :
    (enqueue s id).actual = s.actual := rfl

theorem queue_preserves_arbitrary_requirement (s : State I) (id : Nat) (required : I → Prop) :
    required (enqueue s id).actual ↔ required s.actual := Iff.rfl

theorem queue_preserves_final_offer (s : State I) (id : Nat) (qualified : I) :
    CanOffer (enqueue s id) qualified ↔ CanOffer s qualified := Iff.rfl

/-- The selected writer may not start a native mutation before closure. -/
def MayMutate (s : State I) : Prop := s.granted = true ∧ s.closed = true

theorem open_writer_cannot_mutate (s : State I) (isOpen : s.closed = false) :
    ¬ MayMutate s := by
  intro guard
  exact Bool.noConfusion (isOpen.symm.trans guard.2)

theorem accepted_hard_intent_blocks (s : State I) (qualified : I)
    (pending : s.hardPending = true) : ¬ CanOffer s qualified := by
  intro offered
  exact Bool.noConfusion (pending.symm.trans offered.2.2.2.1)

theorem unknown_outcome_blocks (s : State I) (qualified : I) (unknown : s.known = false) :
    ¬ CanOffer s qualified := by
  intro offered
  exact Bool.noConfusion (unknown.symm.trans offered.1)

theorem changed_image_blocks (s : State I) (qualified : I) (changed : qualified ≠ s.actual) :
    ¬ CanOffer s qualified := fun offered => changed offered.2.2.2.2

/-- Conditional barrier accounting, not an OS/transport latency theorem. The
    native service bound and fair scheduling remain measured host premises. -/
theorem selection_removes_queue_from_closed_interval (queue service : Nat) :
    service ≤ queue + service := Nat.le_add_left service queue

def enqueueAll (s : State I) (ids : List Nat) : State I :=
  ids.foldl enqueue s

theorem finite_queue_preserves_final_offer (ids : List Nat) (s : State I) (qualified : I) :
    CanOffer (enqueueAll s ids) qualified ↔ CanOffer s qualified := by
  induction ids generalizing s with
  | nil => rfl
  | cons id rest ih =>
    simpa only [enqueueAll, List.foldl_cons] using
      (ih (enqueue s id)).trans (queue_preserves_final_offer s id qualified)

/-- Serving without a bootstrap-only source channel requires known activation.
    Runtime catalogue selection retains source custody. Closing a socket is not
    publication success or proof that any unfinished source command rolled back.
    Failure cleanup may close its socket without activating ingress. -/
structure SourceChannel (Image : Type) where
  actual : Image
  activated : Bool
  known : Bool
  runtimeSource : Bool
  sourceOpen : Bool

def MayServeWithoutSource (s : SourceChannel I) : Prop :=
  s.activated = true ∧ s.known = true ∧ s.runtimeSource = false

def closeSource (s : SourceChannel I) : SourceChannel I := {s with sourceOpen := false}

theorem runtime_catalog_requires_source (s : SourceChannel I) (runtime : s.runtimeSource = true) :
    ¬ MayServeWithoutSource s := by
  intro allowed
  exact Bool.noConfusion (runtime.symm.trans allowed.2.2)

theorem unknown_activation_blocks_source_handoff (s : SourceChannel I) (unknown : s.known = false) :
    ¬ MayServeWithoutSource s := by
  intro allowed
  exact Bool.noConfusion (unknown.symm.trans allowed.2.1)

theorem bootstrap_source_close_preserves_actual (s : SourceChannel I)
    (_knownActivation : MayServeWithoutSource s) (required : I → Prop) :
    required (closeSource s).actual ↔ required s.actual := Iff.rfl

#print axioms runtime_catalog_requires_source
#print axioms unknown_activation_blocks_source_handoff
#print axioms bootstrap_source_close_preserves_actual

#print axioms queue_preserves_actual
#print axioms queue_preserves_arbitrary_requirement
#print axioms queue_preserves_final_offer
#print axioms open_writer_cannot_mutate
#print axioms accepted_hard_intent_blocks
#print axioms unknown_outcome_blocks
#print axioms changed_image_blocks
#print axioms selection_removes_queue_from_closed_interval
#print axioms finite_queue_preserves_final_offer
end Weaver.ProviderAdmissionTurn
