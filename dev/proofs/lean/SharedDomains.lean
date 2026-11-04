-- SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
--
-- SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

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
/-- The quota transaction adds the same immutable reservation to three scopes.
The host supplies authentic scope identities and an atomic deciding snapshot. -/
theorem joint_quota_reserve_bounds
    (key user tenant amount keyCap userCap tenantCap : Nat)
    (k : key + amount ≤ keyCap) (u : user + amount ≤ userCap)
    (t : tenant + amount ≤ tenantCap) :
    (key + amount ≤ keyCap ∧ user + amount ≤ userCap ∧ tenant + amount ≤ tenantCap) :=
  ⟨k, u, t⟩

theorem another_key_cannot_reuse_unknown_user_capacity
    {booked amount limit : Nat} (exhausted : booked + amount = limit)
    (positive : 0 < amount) : ¬ booked + amount + amount ≤ limit := by omega

#print axioms joint_quota_reserve_bounds
#print axioms another_key_cannot_reuse_unknown_user_capacity

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

namespace Weaver.RequestRouting

structure Selection where
  plan : Nat
  rate : Nat
  deriving DecidableEq

def recover (bound : Option Selection) (proposal : Selection) : Option Selection :=
  bound.or (some proposal)

theorem concurrent_proposal_keeps_plan_and_rate (original alternate : Selection) :
    recover (some original) alternate = some original := rfl

theorem stale_quote_cannot_authorize (original proposed : Selection)
    (stale : proposed.rate ≠ original.rate) : proposed ≠ original := by
  intro h
  exact stale (congrArg Selection.rate h)

#print axioms concurrent_proposal_keeps_plan_and_rate
#print axioms stale_quote_cannot_authorize
end Weaver.RequestRouting

namespace Weaver.CatalogPublication

def reserve (head offered : Nat) (prior : Option Nat) : Option Nat :=
  prior.or (if head = offered then some offered else none)

theorem stale_offer_cannot_create (head offered : Nat) (stale : head ≠ offered) :
    reserve head offered none = none := by
  simp [reserve, stale]

theorem new_head_preserves_old_reservation (newHead offered retained : Nat) :
    reserve newHead offered (some retained) = some retained := rfl

#print axioms stale_offer_cannot_create
#print axioms new_head_preserves_old_reservation
end Weaver.CatalogPublication

namespace Weaver.RetainedTariff

def settle (retained offered charge ceiling : Nat) (terminal applied : Bool) : Nat :=
  if terminal && !applied && retained == offered && charge ≤ ceiling then ceiling - charge else 0

theorem stale_formula_releases_nothing (original offered charge ceiling : Nat)
    (different : original ≠ offered) :
    settle original offered charge ceiling true false = 0 := by
  simp [settle, different]

theorem unknown_or_duplicate_releases_nothing (original offered charge ceiling : Nat) :
    settle original offered charge ceiling false false = 0 ∧
    settle original offered charge ceiling true true = 0 := by
  simp [settle]

#print axioms stale_formula_releases_nothing
#print axioms unknown_or_duplicate_releases_nothing
end Weaver.RetainedTariff

namespace Weaver.TerminalUsage

def release (terminal observed matched applied : Bool) (remainder : Nat) :=
  if terminal && observed && matched && !applied then remainder else 0

theorem late_observation_cannot_release (observed matched : Bool) (remainder : Nat) :
    release false observed matched false remainder = 0 := rfl

theorem issuer_replay_cannot_release_twice (terminal observed matched : Bool)
    (remainder : Nat) : release terminal observed matched true remainder = 0 := by
  simp [release]

#print axioms late_observation_cannot_release
#print axioms issuer_replay_cannot_release_twice
end Weaver.TerminalUsage

namespace Weaver.MeterCredential

def permits (current presented tenant requested issuer claimed : Nat) : Prop :=
  current = presented ∧ tenant = requested ∧ issuer = claimed

theorem retired_epoch_cannot_settle (current retired tenant requested issuer claimed : Nat)
    (revoked : current ≠ retired) : ¬ permits current retired tenant requested issuer claimed :=
  fun evidence => revoked evidence.1

theorem other_tenant_cannot_read (epoch tenant other issuer : Nat)
    (different : tenant ≠ other) : ¬ permits epoch epoch tenant other issuer issuer :=
  fun evidence => different evidence.2.1

#print axioms retired_epoch_cannot_settle
#print axioms other_tenant_cannot_read
end Weaver.MeterCredential

namespace Weaver.ProviderImport

def maySend (matchesReview published cedar unspent : Bool) : Bool :=
  matchesReview && published && cedar && unspent

theorem import_cannot_replace_cedar (matchesReview published unspent : Bool) :
    maySend matchesReview published false unspent = false := by
  simp [maySend]

theorem imported_route_cannot_replay_consumed_send (matchesReview published cedar : Bool) :
    maySend matchesReview published cedar false = false := by
  simp [maySend]

#print axioms import_cannot_replace_cedar
#print axioms imported_route_cannot_replay_consumed_send
end Weaver.ProviderImport
