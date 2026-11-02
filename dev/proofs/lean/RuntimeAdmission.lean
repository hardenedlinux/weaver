namespace Weaver.RuntimeAdmission

/- The native CAS/Turso durability, authentic source task and actual transport
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

namespace Persistence
/- MRR Data supplies the physical driver. Atomic native image visibility, FULL
durability and faithful canonical-key decoding are implementation premises.
Reuse the admission State/Step/Safe laws; do not introduce another budget model. -/
structure Pending where
  before : State
  after : State
structure Image where
  committed : State
  pending : Option Pending := none

def SafeImage (budget : Nat) (image : Image) : Prop := Safe budget image.committed

inductive StorageStep (budget : Nat) : Image → Image → Prop where
  | prepare (image next) (idle : image.pending = none)
      (domain : Step budget image.committed next)
      (noExternalSend : next.calls = image.committed.calls) : StorageStep budget image
      {image with pending := some ⟨image.committed,next⟩}
  | commit (image write) (pending : image.pending = some write)
      (sameParent : write.before = image.committed)
      (domain : Step budget write.before write.after)
      (noExternalSend : write.after.calls = write.before.calls) : StorageStep budget image
      ⟨write.after,none⟩
  | abortOrCrash (image) : StorageStep budget image {image with pending := none}
  | replyLoss (image) : StorageStep budget image image
  | finalUse (image next) (idle : image.pending = none)
      (guarded : Step budget image.committed next) : StorageStep budget image ⟨next,none⟩

theorem storage_step_retains_admission_safety (safe : SafeImage budget before)
    (step : StorageStep budget before after) : SafeImage budget after := by
  cases step with
  | prepare next idle domain noSend => exact safe
  | commit write pending bound domain noSend =>
      apply safe_step (s := write.before) _ domain
      simpa [SafeImage,bound] using safe
  | abortOrCrash => exact safe
  | replyLoss => exact safe
  | finalUse next idle guarded => exact safe_step safe guarded

theorem stale_parent_cannot_commit (image : Image) (write : Pending)
    (changed : write.before ≠ image.committed) :
    ¬ (image.pending = some write ∧ write.before = image.committed ∧
       Step budget write.before write.after) := fun admission => changed admission.2.1

theorem crash_retains_original_committed_exposure (image : Image) :
    ({image with pending := none} : Image).committed.held = image.committed.held ∧
    ({image with pending := none} : Image).committed.spent = image.committed.spent := ⟨rfl,rfl⟩

theorem commit_itself_does_not_send (write : Pending)
    (metadataOnly : write.after.calls = write.before.calls) :
    (Image.mk write.after none).committed.calls = write.before.calls := metadataOnly

def CanConsume (image : Image) : Prop := image.pending = none ∧ image.committed.spent = false

theorem committed_consume_survives_reply_loss_and_restart (image : Image)
    (spent : image.committed.spent = true) :
    ¬ CanConsume {image with pending := none} := by
  intro admissible
  simp [CanConsume,spent] at admissible

#print axioms storage_step_retains_admission_safety
#print axioms stale_parent_cannot_commit
#print axioms crash_retains_original_committed_exposure
#print axioms commit_itself_does_not_send
#print axioms committed_consume_survives_reply_loss_and_restart
end Persistence

namespace MVCC
/- Native premises: one process owns one Database. Global mutations acquire
exclusive custody. Admission and final use retain shared custody and the same
original claim/budget/history-family mutex through commit/abort. Admission never
sends. A final native observation conflict cannot undo physical bytes or replay
consumption. Filesystem custody, actual locks and IO refinement are not proved. -/
def replaceDomain (domains : Nat → State) (key : Nat) (next : State) : Nat → State :=
  fun observed => if observed = key then next else domains observed

theorem disjoint_domain_commits_commute (domains : Nat → State)
    (left right : Nat) (a b : State) (separate : left ≠ right) :
    replaceDomain (replaceDomain domains left a) right b =
    replaceDomain (replaceDomain domains right b) left a := by
  funext observed
  by_cases l : observed = left
  · subst observed
    simp [replaceDomain,separate]
  · by_cases r : observed = right
    · subst observed
      simp [replaceDomain,Ne.symm separate]
    · simp [replaceDomain,l,r]

theorem family_step_preserves_all_budgets (domains : Nat → State)
    (budgets : Nat → Nat) (key : Nat) (next : State)
    (before : ∀ domain, Safe (budgets domain) (domains domain))
    (transition : Step (budgets key) (domains key) next) :
    ∀ domain, Safe (budgets domain) (replaceDomain domains key next domain) := by
  intro domain
  by_cases equal : domain = key
  · subst domain
    simpa [replaceDomain] using safe_step (before key) transition
  · simpa [replaceDomain,equal] using before domain

inductive CustodyStep : Bool → Nat → Nat → Prop where
  | publish (unowned : owned = false) : CustodyStep owned fence (fence+1)
  | unchanged : CustodyStep owned fence fence

theorem exclusive_final_use_keeps_current_fence
    (transition : CustodyStep true before after) : after = before := by
  cases transition with
  | publish impossible => contradiction
  | unchanged => rfl

theorem native_final_send_preserves_original_hold (state : State)
    (safe : Safe budget state) (spent : state.spent = true) (fresh : state.calls = 0) :
    Safe budget {state with calls := 1} ∧
      ({state with calls := 1} : State).held = state.held :=
  ⟨safe_step safe (Step.send state spent fresh (observedRevision := state.revision)
    (observedFence := state.fence) rfl rfl),rfl⟩

#print axioms disjoint_domain_commits_commute
#print axioms family_step_preserves_all_budgets
#print axioms exclusive_final_use_keeps_current_fence
#print axioms native_final_send_preserves_original_hold

inductive PublicationStep (readers : Nat) : Nat → Nat → Prop where
  | publish (drained : readers = 0) : PublicationStep readers fence (fence+1)
  | unchanged : PublicationStep readers fence fence

theorem shared_final_readers_keep_current_fence (live : 0 < readers)
    (step : PublicationStep readers before after) : after = before := by
  cases step with
  | publish drained => omega
  | unchanged => rfl

theorem two_independent_final_uses_preserve_all_budgets
    (domains : Nat → State) (budgets : Nat → Nat) (left right : Nat)
    (a b : State) (distinct : left ≠ right)
    (safe : ∀ domain, Safe (budgets domain) (domains domain))
    (first : Step (budgets left) (domains left) a)
    (second : Step (budgets right) (domains right) b) :
    ∀ domain, Safe (budgets domain)
      (replaceDomain (replaceDomain domains left a) right b domain) := by
  apply family_step_preserves_all_budgets _ budgets right b
    (family_step_preserves_all_budgets domains budgets left a safe first)
  simpa [replaceDomain,Ne.symm distinct] using second

/- execution.calls records irreversible physical effects, not a SQL acknowledgement
counter. The native refinement must never restore that counter by rolling back a
transaction. Observations do not authorize budget settlement. -/
structure EffectImage where
  execution : State
  recorded : Bool := false

inductive EffectStep (budget : Nat) : EffectImage → EffectImage → Prop where
  | execute (image next) (admitted : Step budget image.execution next) :
      EffectStep budget image {image with execution := next}
  | observation (image) (committed : Bool) :
      EffectStep budget image {image with recorded := committed}

theorem observation_or_conflict_cannot_erase_effect_safety
    (safe : Safe budget before.execution) (step : EffectStep budget before after) :
    Safe budget after.execution := by
  cases step with
  | execute next admitted => exact safe_step safe admitted
  | observation => exact safe

theorem failed_observation_after_send_keeps_spent_hold (image : EffectImage)
    (safe : Safe budget image.execution) (sent : 0 < image.execution.calls) :
    ({image with recorded := false} : EffectImage).execution.spent = true ∧
    0 < ({image with recorded := false} : EffectImage).execution.held ∧
    ({image with recorded := false} : EffectImage).execution.calls ≤ 1 := by
  have spent := safe.2.2.2 sent
  exact ⟨spent,safe.2.2.1 spent,safe.1⟩

#print axioms shared_final_readers_keep_current_fence
#print axioms two_independent_final_uses_preserve_all_budgets
#print axioms observation_or_conflict_cannot_erase_effect_safety
#print axioms failed_observation_after_send_keeps_spent_hold

namespace Telemetry
/- Statistics are a separate projection. The runtime refinement must expose no
   execution/storage callback to the recorder; recovery of effect is the existing
   durable-owner premise, not a consequence of resetting process-local counters. -/
structure Image where
  effect : EffectImage
  counters : Fin 9 → Nat

def observe (image : Image) (signal : Fin 9) : Image :=
  {image with counters := fun k => if k = signal then image.counters k + 1 else image.counters k}

def reset (image : Image) : Image := {image with counters := fun _ => 0}

theorem arbitrary_observations_keep_execution (signals : List (Fin 9)) (image : Image) :
    (signals.foldl observe image).effect.execution = image.effect.execution := by
  induction signals generalizing image with
  | nil => rfl
  | cons head tail ih => exact ih (observe image head)

theorem telemetry_reset_keeps_unknown_hold (image : Image) :
    (reset image).effect.execution.held = image.effect.execution.held ∧
    (reset image).effect.execution.spent = image.effect.execution.spent := ⟨rfl, rfl⟩

theorem observations_preserve_effect_safety (signals : List (Fin 9)) (image : Image)
    (safe : Safe budget image.effect.execution) :
    Safe budget (signals.foldl observe image).effect.execution := by
  rw [arbitrary_observations_keep_execution]
  exact safe

#print axioms arbitrary_observations_keep_execution
#print axioms telemetry_reset_keeps_unknown_hold
#print axioms observations_preserve_effect_safety
end Telemetry
end MVCC
end Weaver.RuntimeAdmission
