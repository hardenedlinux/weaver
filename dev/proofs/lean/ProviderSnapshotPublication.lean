-- SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
--
-- SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

import Std

namespace Weaver.ProviderSnapshotPublication

structure Range where
  first : Nat
  width : Nat
  digest : Nat
  deriving DecidableEq

structure Snapshot where
  owner : Nat
  cut : Nat
  plan : Nat
  scope : Nat
  manifest : List Range
  committed : Bool

structure Gate where
  owner : Nat
  cut : Nat
  plan : Nat
  scope : Nat
  cursor : Nat
  closed : Bool
  failed : Bool
  held : Nat
  readers : Nat

def Ready (s : Snapshot) (g : Gate) (r : Range) (acknowledged unexpired : Prop) : Prop :=
  s.committed = true ∧ s.owner = g.owner ∧ s.cut = g.cut ∧
  s.plan = g.plan ∧ s.scope = g.scope ∧ g.closed = false ∧ g.failed = false ∧
  acknowledged ∧ unexpired ∧ r ∈ s.manifest ∧ r.first = g.cursor ∧ 0 < r.width

/-- Active read-only qualification is not part of the semantic closure set.
    The concrete host still serializes its captured view and publication with
    semantic writers; an unknown native outcome seals the ordinary gate. -/
def beginRead (g : Gate) : Gate := {g with readers := g.readers + 1}

theorem readonly_validation_preserves_ready_peer (s : Snapshot) (g : Gate) (r : Range)
    (acknowledged unexpired : Prop) :
    Ready s (beginRead g) r acknowledged unexpired ↔ Ready s g r acknowledged unexpired := Iff.rfl

/-- Schedule renewal only for unsatisfied demand at an open authority cut.
    A later close can still race scheduling; final use retains its own gate. -/
def NeedsRenewal (s : Snapshot) (g : Gate) (demand : Prop) : Prop :=
  demand ∧ g.closed = false ∧ g.failed = false ∧ s.cut ≠ g.cut

theorem pending_close_defers_renewal (s : Snapshot) (g : Gate) (demand : Prop) :
    ¬ NeedsRenewal s {g with closed := true} demand := by
  simp [NeedsRenewal]

/-- `permit` represents the complete deciding SPEC/Cedar/claim/hold/history
    predicate. A known native outcome publishes exactly one full manifest cut.
    Final use still serializes with semantic closure; an Arc load is not use. -/
theorem final_use_joins_snapshot (s : Snapshot) (g : Gate) (r : Range)
    (acknowledged unexpired : Prop) (permit : Nat → Range → Prop)
    (qualified : ∀ row ∈ s.manifest, permit s.cut row)
    (ready : Ready s g r acknowledged unexpired) : permit g.cut r := by
  rw [← ready.2.2.1]
  exact qualified r ready.2.2.2.2.2.2.2.2.2.1

theorem uncommitted_snapshot_cannot_offer (s : Snapshot) (g : Gate) (r : Range)
    (acknowledged unexpired : Prop) (uncommitted : s.committed = false) :
    ¬ Ready s g r acknowledged unexpired := by
  intro h; exact Bool.noConfusion (uncommitted.symm.trans h.1)

theorem semantic_close_blocks_old_snapshot (s : Snapshot) (g : Gate) (r : Range)
    (acknowledged unexpired : Prop) :
    ¬ Ready s {g with closed := true} r acknowledged unexpired := by
  intro h; exact Bool.noConfusion h.2.2.2.2.2.1

theorem changed_cut_blocks_old_snapshot (s : Snapshot) (g : Gate) (r : Range)
    (acknowledged unexpired : Prop) (changed : s.cut ≠ g.cut) :
    ¬ Ready s g r acknowledged unexpired := fun h => changed h.2.2.1

theorem changed_owner_blocks_old_snapshot (s : Snapshot) (g : Gate) (r : Range)
    (acknowledged unexpired : Prop) (changed : s.owner ≠ g.owner) :
    ¬ Ready s g r acknowledged unexpired := fun h => changed h.2.1

def offer (g : Gate) (r : Range) : Gate := {g with cursor := r.first + r.width}

theorem offer_cannot_repeat_interval (s : Snapshot) (g : Gate) (r : Range)
    (acknowledged unexpired : Prop) (ready : Ready s g r acknowledged unexpired) :
    ¬ Ready s (offer g r) r acknowledged unexpired := by
  intro again
  have positive := ready.2.2.2.2.2.2.2.2.2.2.2
  have same := again.2.2.2.2.2.2.2.2.2.2.1
  change r.first = r.first + r.width at same
  have zero : r.width = 0 := Nat.add_left_cancel (show r.first + r.width = r.first + 0 by simpa using same.symm)
  exact Nat.ne_of_gt positive zero

/-- Native commit changes evidence, not the receiver cursor or external IO. -/
def publish (s : Snapshot) : Snapshot := {s with committed := true}

theorem publish_preserves_exact_manifest (s : Snapshot) :
    (publish s).manifest = s.manifest ∧ (publish s).owner = s.owner ∧
    (publish s).plan = s.plan ∧ (publish s).scope = s.scope := ⟨rfl,rfl,rfl,rfl⟩

theorem offer_keeps_original_unknown_hold (g : Gate) (r : Range) :
    (offer g r).held = g.held := rfl

#print axioms pending_close_defers_renewal
#print axioms final_use_joins_snapshot
#print axioms offer_cannot_repeat_interval
end Weaver.ProviderSnapshotPublication
