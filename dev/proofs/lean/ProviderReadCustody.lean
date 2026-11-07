-- SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
--
-- SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

import Std

namespace Weaver.ProviderReadCustody

/-- Resources denote semantic coordinates, including exact retained exposure;
    native SQL snapshot isolation alone is not a shared-budget protocol. -/
structure Access where
  reads : Nat → Prop
  writes : Nat → Prop

def Compatible (a b : Access) : Prop :=
  ∀ key, (a.writes key → ¬ b.reads key) ∧ (b.writes key → ¬ a.reads key) ∧ ¬ (a.writes key ∧ b.writes key)

def update (before values : Nat → Nat) (writes : Nat → Prop) [DecidablePred writes] : Nat → Nat :=
  fun key => if writes key then values key else before key

theorem compatible_write_preserves_read (a b : Access) [DecidablePred a.writes]
    (safe : Compatible a b) (before values : Nat → Nat) :
    ∀ key, b.reads key → update before values a.writes key = before key := by
  intro key read
  have unchanged : ¬ a.writes key := fun write => (safe key).1 write read
  simp [update, unchanged]

def ReadsOnly (allow : (Nat → Nat) → Prop) (reads : Nat → Prop) : Prop :=
  ∀ before after, (∀ key, reads key → after key = before key) → (allow after ↔ allow before)

theorem arbitrary_policy_preserved (a b : Access) [DecidablePred a.writes]
    (safe : Compatible a b) (allow : (Nat → Nat) → Prop) (depends : ReadsOnly allow b.reads)
    (before values : Nat → Nat) (qualified : allow before) :
    allow (update before values a.writes) := by
  exact (depends before _ (compatible_write_preserves_read a b safe before values)).2 qualified

/-- Any finite interleaving of declared compatible writes preserves the read
    projection. No fixed worker, family or range cardinality is assumed. -/
inductive Steps (reader : Access) : (Nat → Nat) → (Nat → Nat) → Prop where
  | refl (image) : Steps reader image image
  | next {before after} (writer : Access) [DecidablePred writer.writes]
      (values : Nat → Nat) (safe : Compatible writer reader)
      (previous : Steps reader before after) :
      Steps reader before (update after values writer.writes)

theorem finite_interleaving_preserves_reads (steps : Steps reader before after) :
    ∀ key, reader.reads key → after key = before key := by
  induction steps with
  | refl => intro key _; rfl
  | next writer values safe _ ih =>
    intro key read
    exact (compatible_write_preserves_read writer reader safe _ values key read).trans (ih key read)

theorem finite_interleaving_preserves_policy (steps : Steps reader before after)
    (depends : ReadsOnly allow reader.reads) (qualified : allow before) : allow after :=
  (depends before after (finite_interleaving_preserves_reads steps)).2 qualified

theorem shared_writer_conflicts (a b : Access) (key : Nat)
    (write : a.writes key) (read : b.reads key) : ¬ Compatible a b := by
  intro safe; exact (safe key).1 write read

theorem overlapping_writes_conflict (a b : Access) (key : Nat)
    (left : a.writes key) (right : b.writes key) : ¬ Compatible a b := by
  intro safe; exact (safe key).2.2 ⟨left, right⟩

def Eligible (candidate : Access) (older active : List Access) : Prop :=
  (∀ entry ∈ older, Compatible entry candidate) ∧ (∀ entry ∈ active, Compatible entry candidate)

theorem older_conflicting_writer_blocks (candidate writer : Access) (older active : List Access)
    (queued : writer ∈ older) (conflict : ¬ Compatible writer candidate) :
    ¬ Eligible candidate older active := fun eligible => conflict (eligible.1 writer queued)

theorem active_conflict_blocks (candidate writer : Access) (older active : List Access)
    (leased : writer ∈ active) (conflict : ¬ Compatible writer candidate) :
    ¬ Eligible candidate older active := fun eligible => conflict (eligible.2 writer leased)

/-- Exact binding identifies the original frame, canonical read domains and plan.
    Native confirmation and this current scope are independent requirements. -/
structure Qualification where
  binding : Nat
  sharedRevision : Nat
  originRevision : Nat
  owner : Nat

structure Transfer where
  committed : Bool
  issued : Qualification
  actual : Qualification
  revoked : Bool
  used : Bool

def Ready (t : Transfer) : Prop := t.committed = true ∧ t.issued = t.actual ∧
  t.revoked = false ∧ t.used = false

theorem unknown_commit_blocks (t : Transfer) (unknown : t.committed = false) : ¬ Ready t := by
  intro ready; exact Bool.noConfusion (unknown.symm.trans ready.1)

theorem changed_binding_blocks (t : Transfer) (changed : t.issued.binding ≠ t.actual.binding) :
    ¬ Ready t := fun ready => changed (congrArg Qualification.binding ready.2.1)

theorem changed_shared_cut_blocks (t : Transfer) (changed : t.issued.sharedRevision ≠ t.actual.sharedRevision) :
    ¬ Ready t := fun ready => changed (congrArg Qualification.sharedRevision ready.2.1)

theorem changed_origin_cut_blocks (t : Transfer) (changed : t.issued.originRevision ≠ t.actual.originRevision) :
    ¬ Ready t := fun ready => changed (congrArg Qualification.originRevision ready.2.1)

theorem changed_owner_blocks (t : Transfer) (changed : t.issued.owner ≠ t.actual.owner) :
    ¬ Ready t := fun ready => changed (congrArg Qualification.owner ready.2.1)

#print axioms compatible_write_preserves_read
#print axioms arbitrary_policy_preserved
#print axioms finite_interleaving_preserves_reads
#print axioms finite_interleaving_preserves_policy
#print axioms overlapping_writes_conflict
#print axioms shared_writer_conflicts
#print axioms older_conflicting_writer_blocks
#print axioms active_conflict_blocks
#print axioms unknown_commit_blocks
#print axioms changed_binding_blocks
#print axioms changed_shared_cut_blocks
#print axioms changed_origin_cut_blocks
#print axioms changed_owner_blocks
end Weaver.ProviderReadCustody
