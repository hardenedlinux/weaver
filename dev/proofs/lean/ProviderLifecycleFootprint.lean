-- SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
--
-- SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

import Std

namespace Weaver.ProviderLifecycleFootprint

/-- The concrete host must retain every shared dependency, including the exact
    cross-family reservation projection. This is not a monotone-Policy model. -/
structure Shared where
  policy : Nat
  oauth : Nat
  held : Nat
  history : Nat
  quota : Nat
  roots : Nat
  deriving DecidableEq

structure Local where
  target : Nat
  state : Nat
  dispatched : Nat
  usage : Nat
  deriving DecidableEq

structure Store (Family : Type) where
  shared : Shared
  retained : Family → Nat
  localState : Family → Local
  originalHold : Family → Nat

structure View (Family : Type) where
  shared : Shared
  retained : Family → Nat
  own : Local
  originalHold : Family → Nat

def view (s : Store Family) (observer : Family) : View Family :=
  ⟨s.shared, s.retained, s.localState observer, s.originalHold⟩

def transition [DecidableEq Family] (s : Store Family) (writer : Family) (next : Local) : Store Family :=
  {s with localState := fun f => if f = writer then next else s.localState f}

theorem different_origin_preserves_complete_view [DecidableEq Family]
    (s : Store Family) (writer observer : Family) (next : Local) (distinct : observer ≠ writer) :
    view (transition s writer next) observer = view s observer := by
  simp [view, transition, distinct]

theorem arbitrary_cedar_predicate_preserved [DecidableEq Family]
    (s : Store Family) (writer observer : Family) (next : Local) (distinct : observer ≠ writer)
    (allow : View Family → Prop) :
    allow (view (transition s writer next) observer) ↔ allow (view s observer) := by
  rw [different_origin_preserves_complete_view s writer observer next distinct]

theorem local_transition_keeps_every_original_hold [DecidableEq Family]
    (s : Store Family) (writer observer : Family) (next : Local) :
    (transition s writer next).originalHold observer = s.originalHold observer := rfl

/-- Scope equality remains required for final use. This lemma only justifies
    the write footprint; native read/scheduling custody remains the full set. -/
structure Cut (Family : Type) where
  whole : Nat
  shared : Nat
  origins : Family → Nat

def advanceOrigin [DecidableEq Family] (c : Cut Family) (writer : Family) : Cut Family :=
  {c with whole := c.whole + 1, origins := fun f => if f = writer then c.origins f + 1 else c.origins f}

def stamp (c : Cut Family) (observer : Family) : Nat × Nat := (c.shared, c.origins observer)

theorem origin_commit_keeps_peer_stamp [DecidableEq Family]
    (c : Cut Family) (writer observer : Family) (distinct : observer ≠ writer) :
    stamp (advanceOrigin c writer) observer = stamp c observer := by
  simp [stamp, advanceOrigin, distinct]

theorem origin_commit_retires_own_stamp [DecidableEq Family] (c : Cut Family) (writer : Family) :
    stamp (advanceOrigin c writer) writer ≠ stamp c writer := by
  simp [stamp, advanceOrigin]

/-- A whole-store observer includes every origin's local state. Its aggregate
    revision is separate from the shared revision used by domain readers. -/
theorem origin_commit_retires_whole_reader [DecidableEq Family] (c : Cut Family) (writer : Family) :
    (advanceOrigin c writer).whole ≠ c.whole := by simp [advanceOrigin]

/-- A new reservation changes a shared coordinate; origin-only publication
    cannot preserve arbitrary Cedar predicates on that view. -/
theorem shared_admission_requires_shared_invalidation (s : Store Family) (observer : Family) :
    (view {s with shared := {s.shared with held := s.shared.held + 1}} observer).shared.held ≠
      (view s observer).shared.held := by simp [view]

#print axioms different_origin_preserves_complete_view
#print axioms arbitrary_cedar_predicate_preserved
#print axioms local_transition_keeps_every_original_hold
#print axioms origin_commit_keeps_peer_stamp
#print axioms origin_commit_retires_whole_reader
#print axioms origin_commit_retires_own_stamp
#print axioms shared_admission_requires_shared_invalidation
end Weaver.ProviderLifecycleFootprint
