-- SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
--
-- SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

import SharedMessageBudget

/-! Arbitrary finite message support with persistent canonical budget/history
identities and replaceable execution domains. No source or transport refinement
is asserted. Owner authentication and linearizable persistence are premises. -/
namespace Weaver.FiniteDomainMigration
open Weaver.LogicalMessageAuthority
open Weaver.SharedMessageBudget (Passive passive_is_local_step passive_preserves_reservation)

def sumKeys : List Nat → (Nat → Nat) → Nat
  | [], _ => 0
  | k :: ks, f => f k + sumKeys ks f

theorem sum_congr (ks : List Nat) (f g : Nat → Nat)
    (same : ∀ k ∈ ks, f k = g k) : sumKeys ks f = sumKeys ks g := by
  induction ks with
  | nil => rfl
  | cons a as ih =>
    simp only [sumKeys]
    rw [same a (by simp), ih (fun k hk => same k (by simp [hk]))]

theorem sum_add (ks : List Nat) (f g : Nat → Nat) :
    sumKeys ks (fun k => f k + g k) = sumKeys ks f + sumKeys ks g := by
  induction ks with
  | nil => rfl
  | cons a as ih => simp only [sumKeys, ih]; omega

theorem sum_update_absent (ks : List Nat) (f : Nat → Nat) (k v : Nat)
    (absent : k ∉ ks) : sumKeys ks (update f k v) = sumKeys ks f := by
  apply sum_congr
  intro j hj
  have ne : j ≠ k := by intro eq; subst j; exact absent hj
  simp [update, ne]

theorem sum_update_fresh (ks : List Nat) (f : Nat → Nat) (k v : Nat)
    (unique : ks.Nodup) (member : k ∈ ks) (fresh : f k = 0) :
    sumKeys ks (update f k v) = sumKeys ks f + v := by
  induction ks with
  | nil => simp at member
  | cons a as ih =>
    have hn := List.nodup_cons.mp unique
    by_cases eq : a = k
    · subst a
      have ht := sum_update_absent as f k v hn.1
      change update f k v k + sumKeys as (update f k v) = (f k + sumKeys as f) + v
      rw [show update f k v k = v by simp [update], ht, fresh]
      omega
    · have mem : k ∈ as := by simpa [eq, Ne.symm eq] using member
      have ht := ih hn.2 mem
      simpa [sumKeys, update, eq, Nat.add_assoc] using congrArg (fun x => f a + x) ht

structure Config where
  keys : List Nat
  unique : keys.Nodup
  intent : Nat → Nat
  payload : Nat → Nat
  root : Nat → Nat
  endpointRoot : Nat → Nat
  budget : Nat → Nat
  history : Nat → Nat
  cost : Nat → Nat
  capacity : Nat → Nat

structure Ticket where
  worker : Nat
  generation : Nat
  root : Nat
  fence : Nat
  revision : Nat
  migration : Bool
  deriving DecidableEq

structure Ledger where
  messages : Nat → State := fun _ => initial
  aliases : Nat → Option Nat := fun _ => none
  endpoints : Nat → Option Nat := fun _ => none
  created : Nat → Bool := fun _ => false
  active : Nat → Bool := fun _ => false
  fences : Nat → Nat := fun _ => 0
  restricted : Nat → Bool := fun _ => false
  live : Nat → Bool := fun _ => false
  generations : Nat → Nat := fun _ => 0
  tickets : Nat → Option Ticket := fun _ => none
  claimOwner : Nat → Option (Nat × Nat × Nat) := fun _ => none
  revision : Nat := 0
  forbiddenOffers : Nat := 0

def empty : Ledger := {}
def replace (s : Ledger) (k : Nat) (m : State) : Ledger :=
  { s with messages := update s.messages k m }
def allocation (c : Config) (s : Ledger) (b k : Nat) : Nat :=
  if c.budget (c.root k) = b ∧ (s.messages k).reserved = true then c.cost k else 0
def booked (c : Config) (s : Ledger) (b : Nat) : Nat := sumKeys c.keys (allocation c s b)
def heldCost (c : Config) (s : Ledger) (b k : Nat) : Nat :=
  if c.budget (c.root k) = b then held (s.messages k) * c.cost k else 0
def chargedCost (c : Config) (s : Ledger) (b k : Nat) : Nat :=
  if c.budget (c.root k) = b then charge (s.messages k) * c.cost k else 0

def Current (s : Ledger) (t : Ticket) : Prop :=
  t.migration = false ∧ s.live t.worker = true ∧ t.generation = s.generations t.worker ∧
  s.active t.root = true ∧ t.fence = s.fences t.root ∧ t.revision = s.revision

def Bound (c : Config) (s : Ledger) (a endpoint : Nat) (t : Ticket) : Prop :=
  s.aliases a = some (c.intent a) ∧ c.intent a ∈ c.keys ∧
  s.endpoints endpoint = some (c.root (c.intent a)) ∧ t.root = c.root (c.intent a)

structure Invariant (c : Config) (s : Ledger) : Prop where
  messages : ∀ k, Safe (s.messages k)
  aliases : ∀ a k, s.aliases a = some k → k = c.intent a ∧ k ∈ c.keys
  endpoints : ∀ e r, s.endpoints e = some r → r = c.endpointRoot e
  capacity : ∀ b, booked c s b ≤ c.capacity b
  history : s.forbiddenOffers = 0

def TransferCurrent (s : Ledger) (t : Ticket) : Prop :=
  t.migration = true ∧ s.live t.worker = true ∧ t.generation = s.generations t.worker ∧
  s.created t.root = true ∧ s.active t.root = false ∧
  t.fence = s.fences t.root ∧ t.revision = s.revision

def stamp (s : Ledger) (k : Nat) (m : State) (t : Ticket) : Ledger :=
  { replace s k m with
    claimOwner := if (s.messages k).claimed = false ∧ m.claimed = true
      then update s.claimOwner k (some (t.worker, t.generation, t.fence)) else s.claimOwner }

inductive Transition (c : Config) : Ledger → Ledger → Prop where
  | enroll (s a p) (key : c.intent a ∈ c.keys) (payload : p = c.payload (c.intent a))
      (compatible : s.aliases a = none ∨ s.aliases a = some (c.intent a)) :
      Transition c s { s with aliases := update s.aliases a (some (c.intent a)), revision := s.revision + 1 }
  | create (s e r) (identity : c.endpointRoot e = r) (fresh : s.created r = false)
      (endpoint : s.endpoints e = none) :
      Transition c s { s with
        endpoints := update s.endpoints e (some r)
        created := update s.created r true
        active := update s.active r true
        fences := update s.fences r (s.fences r + 1)
        revision := s.revision + 1 }
  | domainAlias (s e r) (identity : c.endpointRoot e = r) (existsRoot : s.created r = true)
      (compatible : s.endpoints e = none ∨ s.endpoints e = some r) :
      Transition c s { s with endpoints := update s.endpoints e (some r), revision := s.revision + 1 }
  | restart (s w) : Transition c s { s with
      live := update s.live w true
      generations := update s.generations w (s.generations w + 1)
      revision := s.revision + 1 }
  | crash (s w) : Transition c s { s with live := update s.live w false, revision := s.revision + 1 }
  | resumeOldWorker (s) : Transition c s s
  | capture (s slot w r mode) (emptySlot : s.tickets slot = none) (live : s.live w = true)
      (existsRoot : s.created r = true) (phase : s.active r = !mode) :
      Transition c s { s with tickets := update s.tickets slot (some ⟨w, s.generations w, r, s.fences r, s.revision, mode⟩) }
  | reserve (s a e slot t) (ticket : s.tickets slot = some t)
      (current : Current s t) (bound : Bound c s a e t)
      (fresh : (s.messages (c.intent a)).reserved = false)
      (capacity : booked c s (c.budget t.root) + c.cost (c.intent a) ≤ c.capacity (c.budget t.root)) :
      Transition c s { replace s (c.intent a)
        { s.messages (c.intent a) with reserved := true, history := true } with revision := s.revision + 1 }
  | messageStep (s a e slot t m) (ticket : s.tickets slot = some t)
      (current : Current s t) (bound : Bound c s a e t)
      (step : Passive (s.messages (c.intent a)) m) :
      Transition c s { stamp s (c.intent a) m t with revision := s.revision + 1 }
  | offer (s a e slot t) (ticket : s.tickets slot = some t)
      (current : Current s t) (bound : Bound c s a e t)
      (owner : s.claimOwner (c.intent a) = some (t.worker, t.generation, t.fence))
      (history : s.restricted (c.history t.root) = false)
      (claimed : (s.messages (c.intent a)).claimed = true)
      (stream : (s.messages (c.intent a)).claimStream = (s.messages (c.intent a)).stream)
      (first : (s.messages (c.intent a)).sends = 0) (live : (s.messages (c.intent a)).retired = false) :
      Transition c s { replace s (c.intent a)
        { s.messages (c.intent a) with sends := (s.messages (c.intent a)).sends + 1 } with
        revision := s.revision + 1,
        forbiddenOffers := s.forbiddenOffers + (if s.restricted (c.history t.root) then 1 else 0) }
  | restrict (s h) : Transition c s { s with restricted := update s.restricted h true, revision := s.revision + 1 }
  | sealRoot (s r) (existsRoot : s.created r = true) : Transition c s
      { s with active := update s.active r false, fences := update s.fences r (s.fences r + 1), revision := s.revision + 1 }
  | activate (s e slot t) (ticket : s.tickets slot = some t) (current : TransferCurrent s t)
      (identity : c.endpointRoot e = t.root)
      (compatible : s.endpoints e = none ∨ s.endpoints e = some t.root) :
      Transition c s { s with
        endpoints := update s.endpoints e (some t.root)
        active := update s.active t.root true
        fences := update s.fences t.root (s.fences t.root + 1)
        revision := s.revision + 1 }

inductive Reachable (c : Config) : Ledger → Prop where
  | init : Reachable c empty
  | next : Reachable c s → Transition c s s' → Reachable c s'

theorem sum_zero (ks : List Nat) : sumKeys ks (fun _ => 0) = 0 := by
  induction ks <;> simp_all [sumKeys]

theorem replace_safe (hs : ∀ k, Safe (s.messages k)) (hm : Safe m) :
    ∀ j, Safe ((replace s k m).messages j) := by
  intro j
  by_cases eq : j = k
  · simpa [replace, update, eq] using hm
  · simpa [replace, update, eq] using hs j

theorem replace_booked (c : Config) (s : Ledger) (k b : Nat) (m : State)
    (same : m.reserved = (s.messages k).reserved) : booked c (replace s k m) b = booked c s b := by
  apply sum_congr
  intro j hj
  by_cases eq : j = k
  · subst j; simp [allocation, replace, update, same]
  · simp [allocation, replace, update, eq]

theorem reserve_booked (c : Config) (s : Ledger) (k b : Nat)
    (member : k ∈ c.keys) (fresh : (s.messages k).reserved = false) :
    booked c (replace s k { s.messages k with reserved := true, history := true }) b =
      booked c s b + (if c.budget (c.root k) = b then c.cost k else 0) := by
  have base : allocation c s b k = 0 := by simp [allocation, fresh]
  have hu := sum_update_fresh c.keys (allocation c s b) k
    (if c.budget (c.root k) = b then c.cost k else 0) c.unique member base
  have he : booked c (replace s k { s.messages k with reserved := true, history := true }) b =
      sumKeys c.keys (update (allocation c s b) k (if c.budget (c.root k) = b then c.cost k else 0)) := by
    apply sum_congr
    intro j hj
    by_cases eq : j = k
    · subst j; simp [allocation, replace, update]
    · simp [allocation, replace, update, eq]
  exact he.trans hu

theorem initial_invariant (c : Config) : Invariant c empty := by
  constructor
  · intro k; exact initial_safe
  · simp [empty]
  · simp [empty]
  · intro b
    have zero : allocation c empty b = fun _ => 0 := by funext k; simp [allocation, empty, initial]
    simp [booked, zero, sum_zero]
  · rfl

theorem transition_preserves (h : Invariant c s) (step : Transition c s s') : Invariant c s' := by
  cases step with
  | enroll a p key payload compatible =>
    refine ⟨h.messages, ?_, h.endpoints, h.capacity, h.history⟩
    intro b k hb
    simp only [update] at hb
    split at hb
    · simp_all
    · exact h.aliases b k hb
  | create e r identity fresh endpoint =>
    refine ⟨h.messages, h.aliases, ?_, h.capacity, h.history⟩
    intro f q hq
    simp only [update] at hq
    split at hq
    · simp_all
    · exact h.endpoints f q hq
  | domainAlias e r identity existsRoot compatible =>
    refine ⟨h.messages, h.aliases, ?_, h.capacity, h.history⟩
    intro f q hq
    simp only [update] at hq
    split at hq
    · simp_all
    · exact h.endpoints f q hq
  | restart => exact ⟨h.messages, h.aliases, h.endpoints, h.capacity, h.history⟩
  | crash => exact ⟨h.messages, h.aliases, h.endpoints, h.capacity, h.history⟩
  | resumeOldWorker => exact h
  | capture => exact ⟨h.messages, h.aliases, h.endpoints, h.capacity, h.history⟩
  | reserve a e slot t ticket current bound fresh capacity =>
    refine ⟨replace_safe h.messages (step_preserves_safe (h.messages _) (Step.register _)), h.aliases,
      h.endpoints, ?_, h.history⟩
    intro b
    change booked c (replace s (c.intent a) { s.messages (c.intent a) with reserved := true, history := true }) b ≤ _
    rw [reserve_booked c s (c.intent a) b bound.2.1 fresh]
    by_cases eq : c.budget (c.root (c.intent a)) = b
    · have root := bound.2.2.2
      simpa [root, eq] using capacity
    · simp [eq]; exact h.capacity b
  | messageStep a e slot t m ticket current bound step =>
    refine ⟨?_, h.aliases, h.endpoints, ?_, h.history⟩
    · exact replace_safe h.messages (step_preserves_safe (h.messages _) (passive_is_local_step step))
    · intro b
      change booked c (replace s (c.intent a) m) b ≤ _
      rw [replace_booked c s (c.intent a) b m (passive_preserves_reservation step)]
      exact h.capacity b
  | offer a e slot t ticket current bound owner history claimed stream first live =>
    refine ⟨replace_safe h.messages (step_preserves_safe (h.messages _) (Step.offer _ claimed stream first live)),
      h.aliases, h.endpoints, ?_, ?_⟩
    · intro b
      change booked c (replace s (c.intent a) { s.messages (c.intent a) with sends := (s.messages (c.intent a)).sends + 1 }) b ≤ _
      rw [replace_booked c s (c.intent a) b { s.messages (c.intent a) with sends := (s.messages (c.intent a)).sends + 1 } rfl]
      exact h.capacity b
    · simpa [history] using h.history
  | restrict => exact ⟨h.messages, h.aliases, h.endpoints, h.capacity, h.history⟩
  | sealRoot => exact ⟨h.messages, h.aliases, h.endpoints, h.capacity, h.history⟩
  | activate e slot t ticket current identity compatible =>
    refine ⟨h.messages, h.aliases, ?_, h.capacity, h.history⟩
    intro f q hq
    simp only [update] at hq
    split at hq
    · simp_all
    · exact h.endpoints f q hq

theorem reachable_invariant (h : Reachable c s) : Invariant c s := by
  induction h with
  | init => exact initial_invariant c
  | next _ step ih => exact transition_preserves ih step

theorem finite_budget_bound (h : Reachable c s) (b : Nat) : booked c s b ≤ c.capacity b :=
  (reachable_invariant h).capacity b

theorem finite_budget_partition (h : Reachable c s) (b : Nat) :
    sumKeys c.keys (heldCost c s b) + sumKeys c.keys (chargedCost c s b) = booked c s b := by
  rw [← sum_add]
  apply sum_congr
  intro k hk
  have hc := ((reachable_invariant h).messages k).2.2.2.2.1
  by_cases account : c.budget (c.root k) = b
  · cases hr : (s.messages k).reserved <;> cases hp : (s.messages k).charged <;>
      simp_all [heldCost, chargedCost, allocation, held, charge]
  · simp [heldCost, chargedCost, allocation, account]

theorem finite_free_held_charged_conservation (h : Reachable c s) (b : Nat) :
    c.capacity b - booked c s b + sumKeys c.keys (heldCost c s b) +
      sumKeys c.keys (chargedCost c s b) = c.capacity b := by
  have hb := finite_budget_bound h b
  have hp := finite_budget_partition h b
  omega

theorem local_step_or_stutter (step : Transition c s s') (k : Nat) :
    Step (s.messages k) (s'.messages k) ∨ s'.messages k = s.messages k := by
  cases step with
  | reserve a e slot t ticket current bound fresh capacity =>
    by_cases eq : k = c.intent a
    · subst k; exact Or.inl (by simpa [replace, update] using Step.register (s.messages (c.intent a)))
    · exact Or.inr (by simp [replace, update, eq])
  | messageStep a e slot t m ticket current bound step =>
    by_cases eq : k = c.intent a
    · subst k; exact Or.inl (by simpa [stamp, replace, update] using passive_is_local_step step)
    · exact Or.inr (by simp [stamp, replace, update, eq])
  | offer a e slot t ticket current bound owner history claimed stream first live =>
    by_cases eq : k = c.intent a
    · subst k; exact Or.inl (by simpa [replace, update] using Step.offer _ claimed stream first live)
    · exact Or.inr (by simp [replace, update, eq])
  | _ => exact Or.inr rfl

theorem claim_and_history_survive (step : Transition c s s') (hc : (s.messages k).claimed = true)
    (hh : (s.messages k).history = true) :
    (s'.messages k).claimed = true ∧
    (s'.messages k).claimToken = (s.messages k).claimToken ∧
    (s'.messages k).claimStream = (s.messages k).claimStream ∧ (s'.messages k).history = true := by
  rcases local_step_or_stutter step k with hm | he
  · have hp := claim_origin_is_sticky hm hc
    exact ⟨hp.1, hp.2.1, hp.2.2, history_is_monotone hm hh⟩
  · simp_all

theorem claim_executor_stamp_is_sticky (step : Transition c s s')
    (hc : (s.messages k).claimed = true) : s'.claimOwner k = s.claimOwner k := by
  cases step with
  | messageStep a e slot t m ticket current bound step =>
    by_cases eq : k = c.intent a
    · subst k; simp [stamp, hc]
    · simp only [stamp]
      split <;> simp [update, eq]
  | _ => rfl

theorem history_account_is_sticky (step : Transition c s s') (hr : s.restricted b = true) :
    s'.restricted b = true := by
  cases step with
  | restrict h => by_cases eq : b = h <;> simp_all [update]
  | _ => exact hr

theorem aliases_share_canonical_record (h : Reachable c s)
    (ha : s.aliases a = some ka) (hb : s.aliases b = some kb)
    (same : c.intent a = c.intent b) : ka = kb ∧ s.messages ka = s.messages kb := by
  have ea := ((reachable_invariant h).aliases a ka ha).1
  have eb := ((reachable_invariant h).aliases b kb hb).1
  have eq : ka = kb := ea.trans (same.trans eb.symm)
  exact ⟨eq, congrArg s.messages eq⟩

theorem endpoint_identity_is_canonical (h : Reachable c s)
    (he : s.endpoints e = some r) : r = c.endpointRoot e :=
  (reachable_invariant h).endpoints e r he

theorem per_message_affinity (h : Reachable c s) (k : Nat) :
    (s.messages k).claims ≤ 1 ∧ (s.messages k).sends ≤ 1 := by
  have hs := (reachable_invariant h).messages k
  refine ⟨hs.2.2.2.2.2.1, ?_⟩
  have ho := hs.2.2.1
  split at ho <;> omega

theorem restart_rejects_retained_ticket (s : Ledger) (t : Ticket)
    (old : t.generation = s.generations t.worker) :
    ¬ Current { s with generations := update s.generations t.worker (s.generations t.worker + 1), live := update s.live t.worker true, revision := s.revision + 1 } t := by
  intro hc
  have gen := hc.2.2.1
  simp only [update, ↓reduceIte] at gen
  omega

theorem seal_rejects_old_worker (s : Ledger) (t : Ticket) :
    ¬ Current { s with active := update s.active t.root false, fences := update s.fences t.root (s.fences t.root + 1), revision := s.revision + 1 } t := by
  intro hc
  have active := hc.2.2.2.1
  simp [update] at active

theorem shared_update_invalidates_transfer (s : Ledger) (t : Ticket)
    (old : t.revision = s.revision) : ¬ TransferCurrent { s with revision := s.revision + 1 } t := by
  intro ht
  have rev := ht.2.2.2.2.2.2
  simp only at rev
  omega

theorem activation_rejects_transfer_reuse (s : Ledger) (t : Ticket) :
    ¬ TransferCurrent { s with active := update s.active t.root true, fences := update s.fences t.root (s.fences t.root + 1), revision := s.revision + 1 } t := by
  intro ht
  have active := ht.2.2.2.2.1
  simp [update] at active

/-- Operational migration changes domain handles, never canonical accounts. -/
theorem migration_preserves_obligations (s : Ledger) (e : Nat) (t : Ticket) :
    let target : Ledger := { s with endpoints := update s.endpoints e (some t.root), active := update s.active t.root true, fences := update s.fences t.root (s.fences t.root + 1), revision := s.revision + 1 }
    target.messages = s.messages ∧ target.claimOwner = s.claimOwner ∧
      target.restricted = s.restricted ∧ (∀ b, booked c target b = booked c s b) := by
  exact ⟨rfl, rfl, rfl, fun _ => rfl⟩

theorem bound_preserves_budget_and_history (hb : Bound c s a e t) :
    c.budget t.root = c.budget (c.root (c.intent a)) ∧
    c.history t.root = c.history (c.root (c.intent a)) :=
  ⟨congrArg c.budget hb.2.2.2, congrArg c.history hb.2.2.2⟩

theorem issued_ticket_is_immutable (step : Transition c s s')
    (issued : s.tickets slot = some t) : s'.tickets slot = some t := by
  cases step with
  | capture newSlot w r mode emptySlot live existsRoot phase =>
    by_cases eq : slot = newSlot
    · subst slot; simp_all
    · simpa [update, eq] using issued
  | _ => exact issued

theorem advanced_fence_rejects_old_ticket (s : Ledger) (t : Ticket)
    (old : t.fence = s.fences t.root) :
    ¬ Current { s with fences := update s.fences t.root (s.fences t.root + 1) } t := by
  intro hc
  have hf := hc.2.2.2.2.1
  simp only [update, ↓reduceIte] at hf
  omega

theorem changed_executor_cannot_inherit_claim (s : Ledger) (k : Nat) (old new : Nat × Nat × Nat)
    (claimed : s.claimOwner k = some old) (different : old ≠ new) :
    s.claimOwner k ≠ some new := by
  intro eq
  have same : old = new := Option.some.inj (claimed.symm.trans eq)
  exact different same

theorem account_restriction_blocks_offer (hb : Bound c s a e t)
    (restricted : s.restricted (c.history (c.root (c.intent a))) = true) :
    s.restricted (c.history t.root) ≠ false := by
  rw [hb.2.2.2]
  simp [restricted]

theorem created_root_is_sticky (step : Transition c s s') (hc : s.created r = true) :
    s'.created r = true := by
  cases step with
  | create e q identity fresh endpoint => by_cases eq : r = q <;> simp_all [update]
  | _ => exact hc

#print axioms reachable_invariant
#print axioms finite_free_held_charged_conservation
#print axioms claim_executor_stamp_is_sticky
#print axioms restart_rejects_retained_ticket
#print axioms migration_preserves_obligations
#print axioms issued_ticket_is_immutable
#print axioms advanced_fence_rejects_old_ticket
end Weaver.FiniteDomainMigration
