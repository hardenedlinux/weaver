-- SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
--
-- SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

import Std

namespace Weaver.ProviderSemanticProgress

/-- The complete host projection, including Cedar entities/context/schema,
    publication/review/pending state, OAuth ancestry/witness, original claim,
    shared and three-level holds, history, profile, actual target and fence.
    None of these coordinates is a range preparation/release cursor. -/
structure Image where
  policy : Nat
  oauth : Nat
  claim : Nat
  quota : Nat
  history : Nat
  profile : Nat
  target : Nat
  fence : Nat
  deriving DecidableEq

structure Frame where
  owner : Nat
  first : Nat
  width : Nat
  digest : Nat
  deriving DecidableEq

structure Row where
  binding : Frame
  released : Bool

structure Store where
  image : Image
  next : Nat
  rows : Nat → Option Row

def append (s : Store) (key : Nat) (frame : Frame) : Store :=
  { s with next := frame.first + frame.width, rows := fun k => if k = key then some ⟨frame, false⟩ else s.rows k }

def release (s : Store) (key : Nat) (row : Row) : Store :=
  { s with rows := fun k => if k = key then some { row with released := true } else s.rows k }

/-- Equality is sufficient for any Cedar predicate on the full actual image;
    no monotonicity of the Policy, history or budget predicate is assumed. -/
theorem authorization_preserved (allow : Image → Frame → Prop)
    (before after : Store) (frame : Frame) (same : after.image = before.image) :
    allow after.image frame ↔ allow before.image frame := by rw [same]

theorem append_preserves_authorization (s : Store) (key : Nat) (frame old : Frame)
    (allow : Image → Frame → Prop) :
    allow (append s key frame).image old ↔ allow s.image old := Iff.rfl

theorem release_preserves_authorization (s : Store) (key : Nat) (row : Row)
    (frame : Frame) (allow : Image → Frame → Prop) :
    allow (release s key row).image frame ↔ allow s.image frame := Iff.rfl

theorem fresh_append_preserves_old_row (s : Store) (key old : Nat) (frame : Frame)
    (different : old ≠ key) : (append s key frame).rows old = s.rows old := by
  simp [append, different]

theorem release_preserves_other_row (s : Store) (key old : Nat) (row : Row)
    (different : old ≠ key) : (release s key row).rows old = s.rows old := by
  simp [release, different]

theorem release_keeps_exact_binding (s : Store) (key : Nat) (row : Row) :
    (release s key row).rows key = some ⟨row.binding, true⟩ := by simp [release]

inductive Progress : Store → Store → Prop
  | prepare (s : Store) (key : Nat) (frame : Frame)
      (fresh : s.rows key = none) (next : frame.first = s.next) (width : 0 < frame.width) :
      Progress s (append s key frame)
  | mark (s : Store) (key : Nat) (row : Row)
      (exact : s.rows key = some row) (unreleased : row.released = false) :
      Progress s (release s key row)

theorem progress_preserves_image {before after : Store} (step : Progress before after) :
    after.image = before.image := by cases step <;> rfl

inductive Steps : Store → Store → Prop
  | refl (s : Store) : Steps s s
  | tail {a b c : Store} : Steps a b → Progress b c → Steps a c

/-- Arbitrarily many finite interleavings, including other families sharing
    the same quota/history roots, preserve the same certificate projection. -/
theorem finite_progress_preserves_image {before after : Store}
    (steps : Steps before after) : after.image = before.image := by
  induction steps with
  | refl => rfl
  | tail _ step ih => exact (progress_preserves_image step).trans ih

/-- A new key is fresh and a released row cannot satisfy unknown-to-released
    CAS again. Consequently no permitted progress step can replace an earlier
    acknowledged frame's owner, interval, digest or released evidence. -/
theorem progress_preserves_released_binding {before after : Store}
    (step : Progress before after) (oldKey : Nat) (frame : Frame)
    (present : before.rows oldKey = some ⟨frame, true⟩) :
    after.rows oldKey = some ⟨frame, true⟩ := by
  cases step with
  | prepare key new fresh _next _width =>
    have different : oldKey ≠ key := by
      intro same
      subst oldKey
      rw [fresh] at present
      contradiction
    simpa [append, different] using present
  | mark key row exactRow unreleased =>
    have different : oldKey ≠ key := by
      intro same
      subst oldKey
      have sameRow : row = ⟨frame, true⟩ := Option.some.inj (exactRow.symm.trans present)
      subst row
      cases unreleased
    simpa [release, different] using present

theorem finite_progress_preserves_released_binding {before after : Store}
    (steps : Steps before after) (oldKey : Nat) (frame : Frame)
    (present : before.rows oldKey = some ⟨frame, true⟩) :
    after.rows oldKey = some ⟨frame, true⟩ := by
  induction steps with
  | refl => exact present
  | tail _ step ih => exact progress_preserves_released_binding step oldKey frame ih

/-- Any original-reservation projection is unchanged, including unknown holds;
    progress cannot become a settlement decision or mint new quota. -/
theorem finite_progress_keeps_unknown_hold {before after : Store}
    (held : Image → Nat) (steps : Steps before after) :
    held after.image = held before.image :=
  congrArg held (finite_progress_preserves_image steps)

structure Gate where
  owner : Nat
  cut : Nat
  cursor : Nat
  held : Nat
  pending : Bool
  failed : Bool
  expired : Bool

def Eligible (g : Gate) (owner cut first : Nat) : Prop :=
  g.owner = owner ∧ g.cut = cut ∧ g.cursor = first ∧
  g.pending = false ∧ g.failed = false ∧ g.expired = false

theorem semantic_pending_still_blocks (g : Gate) (owner cut first : Nat)
    (pending : g.pending = true) : ¬ Eligible g owner cut first := by
  intro h; exact Bool.noConfusion (pending.symm.trans h.2.2.2.1)

theorem ambiguous_progress_still_seals (g : Gate) (owner cut first : Nat) :
    ¬ Eligible { g with failed := true } owner cut first := by
  intro h; exact Bool.noConfusion h.2.2.2.2.1

theorem changed_owner_still_fences (g : Gate) (cut first : Nat) :
    ¬ Eligible { g with owner := g.owner + 1 } g.owner cut first := by
  intro h; have impossible := h.1; simp at impossible

#print axioms finite_progress_preserves_image
#print axioms authorization_preserved
#print axioms ambiguous_progress_still_seals
end Weaver.ProviderSemanticProgress

#print axioms Weaver.ProviderSemanticProgress.finite_progress_preserves_released_binding
#print axioms Weaver.ProviderSemanticProgress.finite_progress_keeps_unknown_hold
