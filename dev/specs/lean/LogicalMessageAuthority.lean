-- SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
--
-- SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

import Std

/-!
One owner-resolved logical message. Issuance identity is scoped by the caller;
new issuers and transport incarnations do not create another logical message.
This is an abstract transition proof, not a refinement proof of deployed code.
-/
namespace Weaver.LogicalMessageAuthority

structure State where
  reserved : Bool := false
  history : Bool := false
  issued : Nat → Bool := fun _ => false
  consumes : Nat → Nat := fun _ => 0
  revision : Nat := 0
  candidate : Nat → Nat := fun _ => 0
  claims : Nat := 0
  claimed : Bool := false
  claimToken : Nat := 0
  claimStream : Nat := 0
  stream : Nat := 0
  authority : Nat := 0
  sends : Nat := 0
  observed : Bool := false
  retired : Bool := false
  finalCost : Bool := false
  charged : Bool := false

def initial : State := {}

def update (f : Nat → α) (key : Nat) (value : α) : Nat → α :=
  fun x => if x = key then value else f x

/-- Guards are trusted owner/storage contracts, not claims about existing APIs.
`offer` counts an irreversible offer to transport, not remote delivery. -/
inductive Step : State → State → Prop where
  | register (s) : Step s { s with reserved := true, history := true }
  | issue (s t) (reserved : s.reserved = true) :
      Step s { s with issued := update s.issued t true }
  | capture (s worker) :
      Step s { s with candidate := update s.candidate worker s.revision }
  | consume (s worker t) (issued : s.issued t = true)
      (current : s.candidate worker = s.revision) (unspent : s.consumes t = 0) :
      Step s { s with consumes := update s.consumes t (s.consumes t + 1), revision := s.revision + 1 }
  | claim (s t) (reserved : s.reserved = true)
      (consumed : s.consumes t = 1) (unclaimed : s.claimed = false) :
      Step s { s with claims := s.claims + 1, claimed := true, claimToken := t, claimStream := s.stream }
  | offer (s) (claimed : s.claimed = true) (current : s.claimStream = s.stream)
      (first : s.sends = 0) (live : s.retired = false) : Step s { s with sends := s.sends + 1 }
  | rotate (s) : Step s { s with authority := s.authority + 1 }
  | reconnect (s) : Step s { s with stream := s.stream + 1 }
  | observe (s t) (claimed : s.claimed = true) (bound : t = s.claimToken) :
      Step s { s with observed := true }
  | retire (s t) (claimed : s.claimed = true) (bound : t = s.claimToken) :
      Step s { s with retired := true }
  | finalUsage (s t) (claimed : s.claimed = true) (bound : t = s.claimToken) :
      Step s { s with finalCost := true }
  | settle (s) (observed : s.observed = true) (retired : s.retired = true)
      (finalCost : s.finalCost = true) (reserved : s.reserved = true) :
      Step s { s with charged := true }

inductive Reachable : State → Prop where
  | init : Reachable initial
  | next : Reachable s → Step s s' → Reachable s'

def Safe (s : State) : Prop :=
  (∀ t, s.consumes t ≤ 1) ∧
  (s.claimed = true → s.reserved = true) ∧
  s.sends ≤ (if s.claimed then 1 else 0) ∧
  (s.reserved = true → s.history = true) ∧
  (s.charged = true → s.observed = true ∧ s.retired = true ∧
    s.finalCost = true ∧ s.reserved = true) ∧
  s.claims ≤ 1 ∧ (s.claimed = true ↔ s.claims = 1)

theorem initial_safe : Safe initial := by
  simp [Safe, initial]

theorem step_preserves_safe (h : Safe s) (step : Step s s') : Safe s' := by
  rcases h with ⟨nonce, claim, sends, history, charge, claims, claimCount⟩
  cases step <;> simp_all [Safe, update] <;> try omega
  intro t
  split <;> simp_all

theorem reachable_safe (h : Reachable s) : Safe s := by
  induction h with
  | init => exact initial_safe
  | next _ step ih => exact step_preserves_safe ih step

theorem issuance_consumed_at_most_once (h : Reachable s) (t : Nat) :
    s.consumes t ≤ 1 := (reachable_safe h).1 t

theorem logical_message_offered_at_most_once (h : Reachable s) : s.sends ≤ 1 := by
  have hs := (reachable_safe h).2.2.1
  split at hs <;> omega

theorem history_survives_reserved_work (h : Reachable s) (hr : s.reserved = true) :
    s.history = true := (reachable_safe h).2.2.2.1 hr

theorem logical_message_claimed_at_most_once (h : Reachable s) : s.claims ≤ 1 :=
  (reachable_safe h).2.2.2.2.2.1

/-- Evidence arrives separately; an outcome alone cannot discharge a hold. -/
theorem settlement_requires_retirement_and_final_usage (h : Reachable s)
    (hc : s.charged = true) : s.retired = true ∧ s.finalCost = true := by
  have hh := (reachable_safe h).2.2.2.2.1 hc
  exact ⟨hh.2.1, hh.2.2.1⟩

/-- A surviving claim is never rebound to the new transport incarnation. -/
theorem reconnect_preserves_claim_origin (s : State) :
    ({ s with stream := s.stream + 1 } : State).claimStream = s.claimStream := rfl

theorem old_stream_cannot_offer (s : State) (bound : s.claimStream = s.stream) :
    s.claimStream ≠ s.stream + 1 := by omega

theorem late_observation_preserves_execution (s : State) :
    ({ s with observed := true } : State).sends = s.sends ∧
    ({ s with observed := true } : State).claimed = s.claimed ∧
    ({ s with observed := true } : State).charged = s.charged := by simp

/-- Unknown consumption changes the revision even when no effect is observed. -/
theorem consume_invalidates_captured_revision (s : State) (w t : Nat)
    (captured : s.candidate w = s.revision) :
    ({ s with consumes := update s.consumes t (s.consumes t + 1), revision := s.revision + 1 } : State).candidate w ≠
    ({ s with consumes := update s.consumes t (s.consumes t + 1), revision := s.revision + 1 } : State).revision := by
  simp only
  omega

theorem claim_origin_is_sticky (step : Step s s') (hc : s.claimed = true) :
    s'.claimed = true ∧ s'.claimToken = s.claimToken ∧ s'.claimStream = s.claimStream := by
  cases step <;> simp_all

theorem history_is_monotone (step : Step s s') (hh : s.history = true) :
    s'.history = true := by
  cases step <;> simp_all

theorem retirement_is_monotone (step : Step s s') (hr : s.retired = true) :
    s'.retired = true := by
  cases step <;> simp_all

/-- The unit hold is an abstract upper bound, not a provider pricing theorem. -/
def held (s : State) : Nat := if s.reserved && !s.charged then 1 else 0
def charge (s : State) : Nat := if s.charged then 1 else 0

theorem budget_partition (h : Reachable s) :
    held s + charge s = (if s.reserved then 1 else 0) := by
  have hc := (reachable_safe h).2.2.2.2.1
  cases hr : s.reserved <;> cases hp : s.charged <;> simp_all [held, charge]

theorem unknown_retains_hold (s : State) (hr : s.reserved = true)
    (hc : s.charged = false) : held s = 1 := by simp [held, hr, hc]

#print axioms reachable_safe
#print axioms logical_message_offered_at_most_once
#print axioms claim_origin_is_sticky
#print axioms budget_partition
#print axioms consume_invalidates_captured_revision
end Weaver.LogicalMessageAuthority
