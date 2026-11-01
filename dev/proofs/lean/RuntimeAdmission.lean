namespace Weaver.RuntimeAdmission

/- The native CAS/SQLite durability, authentic source task and actual transport
   are refinement premises. These are transition invariants, not compiled-code proofs. -/
structure State where
  spent : Bool := false
  calls : Nat := 0
  held : Nat := 0
  revision : Nat := 0
  fence : Nat := 1

def Safe (budget : Nat) (s : State) : Prop :=
  s.calls ≤ 1 ∧ s.held ≤ budget ∧ (s.spent = true → 0 < s.held) ∧
  (0 < s.calls → s.spent = true)

inductive Step (budget : Nat) : State → State → Prop where
  | reserve (s n) (fresh : s.held = 0) (unused : s.spent = false)
      (positive : 0 < n) (bound : n ≤ budget) : Step budget s {s with held := n}
  | consume (s) (fresh : s.spent = false) (reserved : 0 < s.held) :
      Step budget s {s with spent := true}
  | send (s) (spent : s.spent = true) (fresh : s.calls = 0)
      (boundRevision : observedRevision = s.revision) (boundFence : observedFence = s.fence) :
      Step budget s {s with calls := 1}
  | publish (s) : Step budget s {s with revision := s.revision+1, fence := s.fence+1}
  | crashOrLostReply (s) : Step budget s s

theorem safe_step (h : Safe budget s) (step : Step budget s t) : Safe budget t := by
  rcases h with ⟨calls, held, reserved, spent⟩
  cases step with
  | reserve before n fresh unused positive bound =>
      exact ⟨calls,bound,by simp_all,by simp_all⟩
  | consume before fresh positive => exact ⟨calls,held,by simp_all,by simp_all⟩
  | send before wasSpent fresh revision fence => exact ⟨by simp,held,reserved,by simp_all⟩
  | publish => exact ⟨calls,held,reserved,spent⟩
  | crashOrLostReply => exact ⟨calls,held,reserved,spent⟩

theorem stale_fence_cannot_match (oldFence currentFence : Nat)
    (stale : oldFence < currentFence) : oldFence ≠ currentFence := Nat.ne_of_lt stale

theorem unknown_retains_original_hold (s : State) :
    ({s with revision := s.revision+1, fence := s.fence+1} : State).held = s.held := rfl

theorem original_cost_is_covered (originalCost reservation budget : Nat)
    (sourceBound : originalCost ≤ reservation) (capacity : reservation ≤ budget) :
    originalCost ≤ budget := Nat.le_trans sourceBound capacity

#print axioms safe_step
#print axioms stale_fence_cannot_match
#print axioms unknown_retains_original_hold
#print axioms original_cost_is_covered

/- The retained list must cover every original row; original amounts are authentic.
   The storage refinement must establish these premises under the deciding CAS. -/
structure Reservation where
  original : Nat
  projected : Nat

def originalTotal : List Reservation → Nat
  | [] => 0
  | r :: rest => r.original + originalTotal rest

def projectedTotal : List Reservation → Nat
  | [] => 0
  | r :: rest => r.projected + projectedTotal rest

theorem pointwise_binding_preserves_total (rows : List Reservation)
    (bound : ∀ r ∈ rows, r.projected = r.original) :
    projectedTotal rows = originalTotal rows := by
  induction rows with
  | nil => rfl
  | cons r rest ih =>
    have head := bound r (by simp)
    have tail : ∀ item ∈ rest, item.projected = item.original := by
      intro item member
      exact bound item (by simp [member])
    simp only [projectedTotal, originalTotal, head, ih tail]

theorem admission_covers_original_exposure (rows : List Reservation) (held next budget : Nat)
    (bound : ∀ r ∈ rows, r.projected = r.original)
    (aggregate : held = projectedTotal rows) (capacity : held + next ≤ budget) :
    originalTotal rows + next ≤ budget := by
  rw [aggregate, pointwise_binding_preserves_total rows bound] at capacity
  exact capacity

theorem aggregate_equality_alone_is_insufficient :
    (1 + 6 ≤ (10 : Nat)) ∧ ¬ (6 + 6 ≤ (10 : Nat)) := by decide

#print axioms pointwise_binding_preserves_total
#print axioms admission_covers_original_exposure
#print axioms aggregate_equality_alone_is_insufficient
end Weaver.RuntimeAdmission
