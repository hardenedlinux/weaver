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

/- Node/kind coverage is a separate guard from row-local amount equality.
   A stream node can own several messages: this theorem does not establish
   completeness of that message set, nor recovery of a rolled-back claim root. -/
structure ClaimedReservation where
  node : Nat
  kind : Nat
  amount : Reservation

def ClaimCoverage (claims : List (Nat × Nat)) (rows : List ClaimedReservation) : Prop :=
  ∀ claim ∈ claims, ∃ row ∈ rows, row.node = claim.1 ∧ row.kind = claim.2

theorem orphaned_claim_blocks_admission (claims : List (Nat × Nat))
    (rows : List ClaimedReservation) (claim : Nat × Nat)
    (retainedClaim : claim ∈ claims)
    (missing : ∀ row ∈ rows, ¬ (row.node = claim.1 ∧ row.kind = claim.2)) :
    ¬ ClaimCoverage claims rows := by
  intro covered
  obtain ⟨row, member, binding⟩ := covered claim retainedClaim
  exact missing row member binding

theorem deciding_guard_covers_claims_and_budget
    (claims : List (Nat × Nat)) (rows : List ClaimedReservation) (held next budget : Nat)
    (coverage : ClaimCoverage claims rows)
    (binding : ∀ row ∈ rows.map ClaimedReservation.amount, row.projected = row.original)
    (aggregate : held = projectedTotal (rows.map ClaimedReservation.amount))
    (capacity : held + next ≤ budget) :
    ClaimCoverage claims rows ∧ originalTotal (rows.map ClaimedReservation.amount) + next ≤ budget := by
  exact ⟨coverage, admission_covers_original_exposure _ held next budget binding aggregate capacity⟩

theorem empty_projection_with_retained_claim_is_not_free_capacity :
    projectedTotal ([] : List Reservation) = 0 ∧
      ¬ ClaimCoverage [(0, 0)] ([] : List ClaimedReservation) := by
  constructor
  · rfl
  · intro covered
    obtain ⟨row, member, _⟩ := covered (0, 0) (by simp)
    simp at member

#print axioms orphaned_claim_blocks_admission
#print axioms deciding_guard_covers_claims_and_budget
#print axioms empty_projection_with_retained_claim_is_not_free_capacity

/- Exact retained manifests strengthen node/kind coverage. The native refinement
   must establish unique member keys and the bijection using the deciding writer
   transaction. This premise is not derived from a restored outcome projection. -/
structure ReservationCommitment where
  node : Nat
  kind : Nat
  member : Nat
  digest : Nat
  ceiling : Nat
  deriving DecidableEq

def ManifestCovers (root rows : List ReservationCommitment) : Prop := root.Perm rows

def committedTotal : List ReservationCommitment → Nat
  | [] => 0
  | row :: rest => row.ceiling + committedTotal rest

theorem exact_manifest_preserves_total {root rows : List ReservationCommitment}
    (covered : ManifestCovers root rows) : committedTotal root = committedTotal rows := by
  induction covered with
  | nil => rfl
  | cons row covered ih => simp only [committedTotal, ih]
  | swap a b rest => simp [committedTotal, Nat.add_left_comm]
  | trans first second ih₁ ih₂ => exact Eq.trans ih₁ ih₂

theorem missing_manifest_member_blocks_admission {root rows : List ReservationCommitment}
    (entry : ReservationCommitment) (retained : entry ∈ root) (missing : entry ∉ rows) :
    ¬ ManifestCovers root rows := by
  intro covered
  exact missing (covered.mem_iff.mp retained)

theorem exact_manifest_admission_covers_original_exposure
    (root rows : List ReservationCommitment) (held next budget : Nat)
    (covered : ManifestCovers root rows) (aggregate : held = committedTotal rows)
    (capacity : held + next ≤ budget) : committedTotal root + next ≤ budget := by
  rw [aggregate, ← exact_manifest_preserves_total covered] at capacity
  exact capacity

theorem surviving_member_is_not_complete_stream_coverage (first second : ReservationCommitment) :
    first.node = second.node → ¬ ManifestCovers [first, second] [second] := by
  intro sameOwner covered
  have sizes := covered.length_eq
  simp at sizes

/- Composition requires the native post-image to retain the same authentic root
   and its exact projection. A transition proof alone does not establish that. -/
theorem manifest_bound_runtime_step (root rows : List ReservationCommitment)
    (covered : ManifestCovers root rows) (aggregate : t.held = committedTotal rows)
    (safe : Safe budget s) (step : Step budget s t) :
    Safe budget t ∧ committedTotal root ≤ budget := by
  have after := safe_step safe step
  constructor
  · exact after
  · have bound := after.2.1
    rw [aggregate, ← exact_manifest_preserves_total covered] at bound
    exact bound

#print axioms exact_manifest_preserves_total
#print axioms missing_manifest_member_blocks_admission
#print axioms exact_manifest_admission_covers_original_exposure
#print axioms surviving_member_is_not_complete_stream_coverage
#print axioms manifest_bound_runtime_step

end Weaver.RuntimeAdmission
