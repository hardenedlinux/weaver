-- SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
--
-- SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

namespace Weaver.SharedDomains

/- Authentic origin registration, native atomic commit, current source custody,
   root resolution before snapshot and effect mediation are refinement premises.
   These theorems do not prove the Rust/SQL implementation or prevent coherent
   rollback of every durable copy without an independent recovery floor. -/

def mergeRoots (source target : Nat) (roots : Nat → Nat) (family : Nat) : Nat :=
  if roots family = source then target else roots family

theorem union_cannot_split_any_shared_pair (roots : Nat → Nat)
    (source target left right : Nat) (shared : roots left = roots right) :
    mergeRoots source target roots left = mergeRoots source target roots right := by
  simp only [mergeRoots, shared]

theorem old_domain_alias_cannot_reopen (roots : Nat → Nat) (source target family : Nat)
    (member : roots family = source) : mergeRoots source target roots family = target := by
  simp [mergeRoots, member]

def total : List Nat → Nat
  | [] => 0
  | x :: xs => x + total xs

theorem union_retains_every_hold (left right : List Nat) :
    total (left ++ right) = total left + total right := by
  induction left with
  | nil => simp [total]
  | cons x xs ih => simp [total, ih, Nat.add_assoc]

structure Domain where
  claims : List Nat
  history : List Nat
  cap : Nat
  epoch : Nat

def Safe (d : Domain) := total d.claims ≤ d.cap

def union (a b : Domain) : Domain :=
  ⟨a.claims ++ b.claims, a.history ++ b.history, min a.cap b.cap,
    max a.epoch b.epoch + 1⟩

theorem admitted_union_conserves_capacity (a b : Domain)
    (admitted : total a.claims + total b.claims ≤ min a.cap b.cap) :
    Safe (union a b) ∧ total (union a b).claims = total a.claims + total b.claims := by
  constructor
  · simpa [Safe, union, union_retains_every_hold] using admitted
  · exact union_retains_every_hold _ _

theorem union_retains_history (a b : Domain) (entry : Nat)
    (original : entry ∈ a.history ∨ entry ∈ b.history) :
    entry ∈ (union a b).history := by
  simpa [union, List.mem_append] using original

theorem new_nonce_cannot_replace_original (canonical : Nat → Nat)
    (alias original : Nat) (binding : canonical alias = original)
    (claim : Nat → List Nat) : claim (canonical alias) = claim original := by
  rw [binding]

theorem union_fences_both_old_permits (a b : Domain) :
    (union a b).epoch ≠ a.epoch ∧ (union a b).epoch ≠ b.epoch := by
  have ha := Nat.le_max_left a.epoch b.epoch
  have hb := Nat.le_max_right a.epoch b.epoch
  simp only [union]
  omega

inductive Recovery : Domain → Domain → Prop where
  | replyLoss (d) : Recovery d d
  | restart (d) : Recovery d d
  | lateObservation (d) : Recovery d d

theorem observation_and_restart_never_refund (step : Recovery before after) :
    after.claims = before.claims ∧ after.history = before.history := by
  cases step <;> exact ⟨rfl,rfl⟩

/- Exact identity recovery: a lost reply observes the original receipt rather
   than recomputing a decision against a newer parent. -/
def recordDecision (receipts : Nat → Option Domain) (operation : Nat)
    (decision : Domain) : Nat → Option Domain :=
  match receipts operation with
  | some _ => receipts
  | none => fun key => if key = operation then some decision else receipts key

theorem committed_receipt_survives_head_change (receipts : Nat → Option Domain)
    (operation : Nat) (original next : Domain) (committed : receipts operation = some original) :
    recordDecision receipts operation next operation = some original := by
  simp [recordDecision,committed]

#print axioms union_cannot_split_any_shared_pair
#print axioms old_domain_alias_cannot_reopen
#print axioms union_retains_every_hold
#print axioms admitted_union_conserves_capacity
#print axioms union_retains_history
#print axioms new_nonce_cannot_replace_original
#print axioms union_fences_both_old_permits
#print axioms observation_and_restart_never_refund
#print axioms committed_receipt_survives_head_change
end Weaver.SharedDomains

namespace Weaver.TaskOrigin
structure Assignment where
  family : Nat
  origin : Nat
  claim : Nat
  budget : Nat
  history : Nat
  deriving DecidableEq
def register (registry : Nat → Option Assignment) (key : Nat) (value : Assignment) :=
  match registry key with
  | some _ => registry
  | none => fun other => if other = key then some value else registry other
theorem assigned_task_cannot_rebind (registry : Nat → Option Assignment)
    (key : Nat) (original replacement : Assignment) (bound : registry key = some original) :
    register registry key replacement key = some original := by
  simp [register,bound]
theorem source_epoch_does_not_change_task_scope (registry : Nat → Option Assignment)
    (key oldEpoch newEpoch : Nat) (original replacement : Assignment)
    (bound : registry key = some original) (_handoff : oldEpoch < newEpoch) :
    register registry key replacement key = some original := assigned_task_cannot_rebind _ _ _ _ bound
theorem stale_source_command_cannot_commit (expected current : Nat)
    (changed : expected < current) : ¬ expected = current := by omega

def sealBirth (original proposed : Option Nat) :=
  match original with
  | some _ => original
  | none => proposed

def birthAllows (committed : Nat → Prop) (birth : Option Nat) : Prop :=
  match birth with
  | none => True
  | some key => committed key

theorem first_birth_seal_cannot_broaden (committed : Nat → Prop)
    (original proposed : Option Nat)
    (allowed : birthAllows committed (sealBirth original proposed)) :
    birthAllows committed original := by
  cases original with
  | none => trivial
  | some key => exact allowed

theorem sealed_birth_cannot_be_replaced (original : Nat) (proposed : Option Nat) :
    sealBirth (some original) proposed = some original := rfl
/- Native receipt replay is observational and the entire assignment/consumption
   prefix must survive restart. Authentic stable key assignment remains a host
   premise; these results do not detect an issuer inventing every new label. -/
#print axioms assigned_task_cannot_rebind
#print axioms source_epoch_does_not_change_task_scope
#print axioms stale_source_command_cannot_commit
#print axioms first_birth_seal_cannot_broaden
#print axioms sealed_birth_cannot_be_replaced
end Weaver.TaskOrigin
