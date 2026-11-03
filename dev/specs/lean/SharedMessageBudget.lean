-- SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
--
-- SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

import LogicalMessageAuthority

/-!
Two distinct canonical semantic intents, arbitrary raw aliases, one fixed shared
budget/history domain. Alias enrollment uses an immutable owner-admitted intent
and payload projection. Nonces, issuer instances and streams are not inputs to
that projection. This does not prove the authenticity of those owner facts.
-/
namespace Weaver.SharedMessageBudget
open Weaver.LogicalMessageAuthority

structure Domain where
  intent : Nat → Bool
  payload : Bool → Nat
  cost : Bool → Nat
  capacity : Nat

structure Ledger where
  messages : Bool → State := fun _ => initial
  aliases : Nat → Option Bool := fun _ => none
  revision : Nat := 0
  candidates : Nat → Nat := fun _ => 0
  restricted : Bool := false
  forbiddenOffers : Nat := 0

def empty : Ledger := {}
def replace (s : Ledger) (k : Bool) (m : State) : Ledger :=
  { s with messages := fun j => if j = k then m else s.messages j }
def allocated (d : Domain) (s : Ledger) (k : Bool) : Nat :=
  if (s.messages k).reserved then d.cost k else 0
def booked (d : Domain) (s : Ledger) : Nat := allocated d s false + allocated d s true
def heldTotal (d : Domain) (s : Ledger) : Nat :=
  held (s.messages false) * d.cost false + held (s.messages true) * d.cost true
def chargedTotal (d : Domain) (s : Ledger) : Nat :=
  charge (s.messages false) * d.cost false + charge (s.messages true) * d.cost true

/-- Existing per-message transitions that cannot allocate or offer. -/
inductive Passive : State → State → Prop where
  | issue (s t) (h : s.reserved = true) : Passive s { s with issued := update s.issued t true }
  | capture (s w) : Passive s { s with candidate := update s.candidate w s.revision }
  | consume (s w t) (hi : s.issued t = true) (hv : s.candidate w = s.revision)
      (hu : s.consumes t = 0) : Passive s
      { s with consumes := update s.consumes t (s.consumes t + 1), revision := s.revision + 1 }
  | claim (s t) (hr : s.reserved = true) (hc : s.consumes t = 1) (hu : s.claimed = false) :
      Passive s { s with claims := s.claims + 1, claimed := true, claimToken := t, claimStream := s.stream }
  | rotate (s) : Passive s { s with authority := s.authority + 1 }
  | reconnect (s) : Passive s { s with stream := s.stream + 1 }
  | observe (s t) (hc : s.claimed = true) (hb : t = s.claimToken) : Passive s { s with observed := true }
  | retire (s t) (hc : s.claimed = true) (hb : t = s.claimToken) : Passive s { s with retired := true }
  | finalUsage (s t) (hc : s.claimed = true) (hb : t = s.claimToken) : Passive s { s with finalCost := true }
  | settle (s) (ho : s.observed = true) (hr : s.retired = true)
      (hf : s.finalCost = true) (hb : s.reserved = true) : Passive s { s with charged := true }

theorem passive_is_local_step (h : Passive s s') : Step s s' := by
  cases h <;> (first
    | apply Step.issue
    | apply Step.capture
    | apply Step.consume
    | apply Step.claim
    | apply Step.rotate
    | apply Step.reconnect
    | apply Step.observe
    | apply Step.retire
    | apply Step.finalUsage
    | apply Step.settle) <;> assumption

theorem passive_preserves_reservation (h : Passive s s') : s'.reserved = s.reserved := by
  cases h <;> rfl

/-- Enrollment, allocation and final offer share the authoritative revision.
All other local state updates conservatively advance it as well. -/
inductive Transition (d : Domain) : Ledger → Ledger → Prop where
  | enroll (s a p) (binding : p = d.payload (d.intent a))
      (compatible : s.aliases a = none ∨ s.aliases a = some (d.intent a)) :
      Transition d s { s with aliases := update s.aliases a (some (d.intent a)), revision := s.revision + 1 }
  | capture (s w) : Transition d s { s with candidates := update s.candidates w s.revision }
  | reserve (s a w) (resolved : s.aliases a = some (d.intent a))
      (current : s.candidates w = s.revision)
      (fresh : (s.messages (d.intent a)).reserved = false)
      (capacity : booked d s + d.cost (d.intent a) ≤ d.capacity) :
      Transition d s { replace s (d.intent a)
        { s.messages (d.intent a) with reserved := true, history := true } with revision := s.revision + 1 }
  | messageStep (s a m) (resolved : s.aliases a = some (d.intent a))
      (step : Passive (s.messages (d.intent a)) m) :
      Transition d s { replace s (d.intent a) m with revision := s.revision + 1 }
  | offer (s a w) (resolved : s.aliases a = some (d.intent a))
      (current : s.candidates w = s.revision) (history : s.restricted = false)
      (claimed : (s.messages (d.intent a)).claimed = true)
      (stream : (s.messages (d.intent a)).claimStream = (s.messages (d.intent a)).stream)
      (first : (s.messages (d.intent a)).sends = 0)
      (live : (s.messages (d.intent a)).retired = false) :
      Transition d s { replace s (d.intent a)
        { s.messages (d.intent a) with sends := (s.messages (d.intent a)).sends + 1 } with
          revision := s.revision + 1,
          forbiddenOffers := s.forbiddenOffers + (if s.restricted then 1 else 0) }
  | restrict (s) : Transition d s { s with restricted := true, revision := s.revision + 1 }

inductive Reachable (d : Domain) : Ledger → Prop where
  | init : Reachable d empty
  | next : Reachable d s → Transition d s s' → Reachable d s'

structure Invariant (d : Domain) (s : Ledger) : Prop where
  messages : ∀ k, Safe (s.messages k)
  aliases : ∀ a k, s.aliases a = some k → k = d.intent a
  capacity : booked d s ≤ d.capacity
  history : s.forbiddenOffers = 0

theorem replace_safe (s : Ledger) (k : Bool) (m : State)
    (hs : ∀ j, Safe (s.messages j)) (hm : Safe m) :
    ∀ j, Safe ((replace s k m).messages j) := by
  intro j
  by_cases hj : j = k
  · simpa [replace, hj] using hm
  · simpa [replace, hj] using hs j

theorem replace_booked (d : Domain) (s : Ledger) (k : Bool) (m : State)
    (hr : m.reserved = (s.messages k).reserved) : booked d (replace s k m) = booked d s := by
  cases k <;> simp_all [booked, allocated, replace]

theorem reserve_booked (d : Domain) (s : Ledger) (k : Bool)
    (hf : (s.messages k).reserved = false) :
    booked d (replace s k { s.messages k with reserved := true, history := true }) =
      booked d s + d.cost k := by
  cases k <;> simp_all [booked, allocated, replace] <;> omega

theorem initial_invariant (d : Domain) : Invariant d empty := by
  constructor
  · intro k; exact initial_safe
  · simp [empty]
  · simp [booked, allocated, empty, initial]
  · rfl

theorem transition_preserves (h : Invariant d s) (step : Transition d s s') : Invariant d s' := by
  cases step with
  | enroll a p binding compatible =>
    constructor
    · exact h.messages
    · intro b k hb; simp only [update] at hb
      split at hb
      · simp_all
      · exact h.aliases b k hb
    · exact h.capacity
    · exact h.history
  | capture => exact ⟨h.messages, h.aliases, h.capacity, h.history⟩
  | reserve a w resolved current fresh capacity =>
    constructor
    · exact replace_safe _ _ _ h.messages (step_preserves_safe (h.messages _) (Step.register _))
    · exact h.aliases
    · change booked d (replace s (d.intent a)
        { s.messages (d.intent a) with reserved := true, history := true }) ≤ d.capacity
      rw [reserve_booked d s (d.intent a) fresh]
      exact capacity
    · exact h.history
  | messageStep a m resolved step =>
    constructor
    · exact replace_safe _ _ _ h.messages (step_preserves_safe (h.messages _) (passive_is_local_step step))
    · exact h.aliases
    · change booked d (replace s (d.intent a) m) ≤ d.capacity
      rw [replace_booked d s (d.intent a) m (passive_preserves_reservation step)]
      exact h.capacity
    · exact h.history
  | offer a w resolved current history claimed stream first live =>
    constructor
    · exact replace_safe _ _ _ h.messages
        (step_preserves_safe (h.messages _) (Step.offer _ claimed stream first live))
    · exact h.aliases
    · change booked d (replace s (d.intent a)
        { s.messages (d.intent a) with sends := (s.messages (d.intent a)).sends + 1 }) ≤ d.capacity
      rw [replace_booked d s (d.intent a)
        { s.messages (d.intent a) with sends := (s.messages (d.intent a)).sends + 1 } rfl]
      exact h.capacity
    · simpa [history] using h.history
  | restrict => exact ⟨h.messages, h.aliases, h.capacity, h.history⟩

theorem reachable_invariant (h : Reachable d s) : Invariant d s := by
  induction h with
  | init => exact initial_invariant d
  | next _ step ih => exact transition_preserves ih step

theorem shared_budget_bound (h : Reachable d s) : booked d s ≤ d.capacity :=
  (reachable_invariant h).capacity

theorem alias_cannot_choose_another_intent (h : Reachable d s)
    (resolved : s.aliases a = some k) : k = d.intent a :=
  (reachable_invariant h).aliases a k resolved

theorem aliases_share_claim_budget_and_history (h : Reachable d s)
    (ha : s.aliases a = some ka) (hb : s.aliases b = some kb)
    (sameIntent : d.intent a = d.intent b) :
    ka = kb ∧ s.messages ka = s.messages kb ∧ allocated d s ka = allocated d s kb := by
  have ea := alias_cannot_choose_another_intent h ha
  have eb := alias_cannot_choose_another_intent h hb
  have : ka = kb := ea.trans (sameIntent.trans eb.symm)
  exact ⟨this, congrArg s.messages this, congrArg (allocated d s) this⟩

theorem per_intent_claim_and_offer_bound (h : Reachable d s) (k : Bool) :
    (s.messages k).claims ≤ 1 ∧ (s.messages k).sends ≤ 1 := by
  have hs := (reachable_invariant h).messages k
  refine ⟨hs.2.2.2.2.2.1, ?_⟩
  have hh := hs.2.2.1
  split at hh <;> omega

theorem shared_budget_partition (h : Reachable d s) :
    heldTotal d s + chargedTotal d s = booked d s := by
  have hs := (reachable_invariant h).messages
  have h0 := (hs false).2.2.2.2.1
  have h1 := (hs true).2.2.2.2.1
  cases hr0 : (s.messages false).reserved <;> cases hc0 : (s.messages false).charged <;>
    cases hr1 : (s.messages true).reserved <;> cases hc1 : (s.messages true).charged <;>
    simp_all [heldTotal, chargedTotal, booked, allocated, held, charge] <;> omega

theorem shared_free_held_charged_conservation (h : Reachable d s) :
    (d.capacity - booked d s) + heldTotal d s + chargedTotal d s = d.capacity := by
  have hp := shared_budget_partition h
  have hb := shared_budget_bound h
  omega

theorem restrictive_history_is_sticky (step : Transition d s s') (hr : s.restricted = true) :
    s'.restricted = true := by cases step <;> simp_all [replace]

theorem no_restricted_offer (h : Reachable d s) : s.forbiddenOffers = 0 :=
  (reachable_invariant h).history

/-- Every global update is either a previous local transition or a stutter
for each canonical key. This reuses the checked single-message owner laws. -/
theorem local_step_or_stutter (step : Transition d s s') (k : Bool) :
    Step (s.messages k) (s'.messages k) ∨ s'.messages k = s.messages k := by
  cases step with
  | enroll => exact Or.inr rfl
  | capture => exact Or.inr rfl
  | restrict => exact Or.inr rfl
  | reserve a w resolved current fresh capacity =>
    by_cases hk : k = d.intent a
    · subst k; exact Or.inl (by simpa [replace] using Step.register (s.messages (d.intent a)))
    · exact Or.inr (by simp [replace, hk])
  | messageStep a m resolved step =>
    by_cases hk : k = d.intent a
    · subst k; exact Or.inl (by simpa [replace] using passive_is_local_step step)
    · exact Or.inr (by simp [replace, hk])
  | offer a w resolved current history claimed stream first live =>
    by_cases hk : k = d.intent a
    · subst k; exact Or.inl (by simpa [replace] using Step.offer _ claimed stream first live)
    · exact Or.inr (by simp [replace, hk])

theorem original_claim_survives_all_global_steps (step : Transition d s s')
    (hc : (s.messages k).claimed = true) :
    (s'.messages k).claimed = true ∧
    (s'.messages k).claimToken = (s.messages k).claimToken ∧
    (s'.messages k).claimStream = (s.messages k).claimStream := by
  rcases local_step_or_stutter step k with hl | he
  · exact claim_origin_is_sticky hl hc
  · simp_all

theorem local_history_survives_all_global_steps (step : Transition d s s')
    (hh : (s.messages k).history = true) : (s'.messages k).history = true := by
  rcases local_step_or_stutter step k with hl | he
  · exact history_is_monotone hl hh
  · simp_all

theorem alias_enrollment_does_not_allocate_or_reset (s : Ledger) (a : Nat) (k : Bool) :
    ({ s with aliases := update s.aliases a (some k), revision := s.revision + 1 } : Ledger).messages =
      s.messages ∧
    ({ s with aliases := update s.aliases a (some k), revision := s.revision + 1 } : Ledger).restricted =
      s.restricted := ⟨rfl, rfl⟩

theorem allocation_invalidates_other_worker (s : Ledger) (k : Bool) (w : Nat)
    (old : s.candidates w = s.revision) :
    ({ replace s k { s.messages k with reserved := true, history := true } with
        revision := s.revision + 1 } : Ledger).candidates w ≠
    ({ replace s k { s.messages k with reserved := true, history := true } with
        revision := s.revision + 1 } : Ledger).revision := by
  simp only [replace]
  omega

theorem unrelated_message_is_unchanged (s : Ledger) (k j : Bool) (m : State)
    (different : j ≠ k) : (replace s k m).messages j = s.messages j := by
  simp [replace, different]

/-- New issuance, reconnect and late evidence cannot change booked capacity. -/
theorem passive_update_does_not_replenish (d : Domain) (s : Ledger) (k : Bool)
    (step : Passive (s.messages k) m) : booked d (replace s k m) = booked d s :=
  replace_booked d s k m (passive_preserves_reservation step)

#print axioms reachable_invariant
#print axioms aliases_share_claim_budget_and_history
#print axioms shared_free_held_charged_conservation
#print axioms original_claim_survives_all_global_steps
#print axioms passive_update_does_not_replenish
end Weaver.SharedMessageBudget
