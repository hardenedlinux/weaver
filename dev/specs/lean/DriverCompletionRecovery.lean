-- SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
--
-- SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

import FiniteStreamManifest

/-! Refinement of finite manifests by original driver continuity and canonical
completion records. Authenticated quiescence/isolation events remain physical
refinement premises, not consequences of matching integers or process death. -/
namespace Weaver.DriverCompletionRecovery

structure Request where
  key : Weaver.FiniteStreamManifest.Key
  manifest : Nat
  generation : Nat
  epoch : Nat
  incarnation : Nat
  frontier : Nat
  deriving DecidableEq

structure State where
  base : Weaver.FiniteStreamManifest.State := Weaver.FiniteStreamManifest.initial
  generation : Nat := 0
  online : Bool := true
  tails : Weaver.FiniteStreamManifest.Key → Option Nat := fun _ => none
  pending : Weaver.FiniteStreamManifest.Key → Option Request := fun _ => none
  results : Weaver.FiniteStreamManifest.Key → Option Request := fun _ => none
  isolated : Weaver.FiniteStreamManifest.Key → Bool := fun _ => false

def initial : State := {}

variable {c : Weaver.FiniteDomainMigration.Config} {m : Weaver.FiniteStreamManifest.Manifest c}

def Exact (m : Weaver.FiniteStreamManifest.Manifest c) (s : State) (q : Request)
    (d : Weaver.ComposedGatewayLifecycle.Delegation) : Prop :=
  q.manifest = m.identity q.key.1 ∧ q.generation = s.generation ∧
  s.tails q.key = some q.generation ∧
  (s.base.ranges q.key).admission = some d ∧
  q.epoch = d.epoch ∧ q.incarnation = d.incarnation ∧
  q.frontier = (s.base.ranges q.key).cursor ∧ q.frontier = (m.spec q.key.1 q.key.2).length

inductive Step (c : Weaver.FiniteDomainMigration.Config) (m : Weaver.FiniteStreamManifest.Manifest c) : State → State → Prop where
  -- Actual administrative events only: this filter cannot alter driver slots.
  | administrative (s t) (event : Weaver.FiniteStreamManifest.Step c m s.base t)
      (sameRanges : t.ranges = s.base.ranges) (sameBlocked : t.blocked = s.base.blocked) :
      Step c m s { s with base := t }
  | delegate (s key binding ticket epoch incarnation descriptor)
      (online : s.online = true)
      (gate : Weaver.FiniteStreamManifest.AdmissionGate c m s.base key binding ticket epoch incarnation descriptor) :
      Step c m s { s with
        base := Weaver.FiniteStreamManifest.admitted s.base key binding ticket
        tails := Weaver.FiniteStreamManifest.setAt s.tails key (some s.generation) }
  | write (s key d n) (online : s.online = true)
      (tail : s.tails key = some s.generation) (unfenced : s.isolated key = false)
      (stored : (s.base.ranges key).admission = some d)
      (live : (s.base.ranges key).active = true)
      (positive : 0 < n) (bound : (s.base.ranges key).cursor + n ≤ (m.spec key.1 key.2).length) :
      Step c m s { s with base := { s.base with ranges := Weaver.FiniteStreamManifest.setAt s.base.ranges key (Weaver.FiniteStreamManifest.advanceRange (s.base.ranges key) n (m.spec key.1 key.2).length) } }
  | prepare (s q d) (online : s.online = true) (exact : Exact m s q d)
      (live : (s.base.ranges q.key).active = true)
      (fresh : s.pending q.key = none) :
      Step c m s { s with pending := Weaver.FiniteStreamManifest.setAt s.pending q.key (some q) }
  -- This event denotes authenticated original-driver quiescence, not an SDK report.
  -- Durable result publication and slot release are one abstract owner transaction.
  | finish (s q d) (online : s.online = true) (exact : Exact m s q d)
      (pending : s.pending q.key = some q) (fresh : s.results q.key = none)
      (live : (s.base.ranges q.key).active = true) :
      Step c m s { s with
        base := { s.base with ranges := Weaver.FiniteStreamManifest.setAt s.base.ranges q.key { s.base.ranges q.key with active := false } }
        results := Weaver.FiniteStreamManifest.setAt s.results q.key (some q) }
  | crash (s) : Step c m s { s with generation := s.generation + 1, online := false }
  | recover (s) : Step c m s { s with online := true }
  -- Qualified external writer-fence acknowledgment, not local PID/lease expiry.
  | fence (s key d) (stored : (s.base.ranges key).admission = some d)
      (live : (s.base.ranges key).active = true) : Step c m s { s with isolated := Weaver.FiniteStreamManifest.setAt s.isolated key true }
  | quarantine (s key d) (isolated : s.isolated key = true)
      (stored : (s.base.ranges key).admission = some d) (live : (s.base.ranges key).active = true) :
      Step c m s { s with base := { s.base with
        ranges := Weaver.FiniteStreamManifest.setAt s.base.ranges key (Weaver.FiniteStreamManifest.closeRange (s.base.ranges key) (m.spec key.1 key.2).length)
        blocked := Weaver.LogicalMessageAuthority.update s.base.blocked (m.stream key.1) true } }
  -- Missing status has no positive conclusion. Exact late status is read-only.
  | resolve (s q) (stored : s.results q.key = some q) : Step c m s s
  | resolvePending (s q) (stored : s.pending q.key = some q)
      (unknown : s.results q.key = none) : Step c m s s
  | loseReply (s) : Step c m s s

inductive Reachable (c : Weaver.FiniteDomainMigration.Config) (m : Weaver.FiniteStreamManifest.Manifest c) : State → Prop where
  | init : Reachable c m initial
  | next : Reachable c m s → Step c m s t → Reachable c m t

theorem projection (event : Step c m s t) : Weaver.FiniteStreamManifest.Step c m s.base t.base := by
  cases event with
  | administrative t event _ _ => exact event
  | delegate key binding ticket epoch incarnation descriptor online gate => exact .delegate _ _ _ _ _ _ _ gate
  | write key d n online tail unfenced stored live positive bound => exact .writePrefix _ _ _ _ d.epoch d.incarnation stored live ⟨rfl,rfl⟩ positive bound
  | finish q d online exact pending fresh live =>
    exact .finishRange _ _ _ q.epoch q.incarnation q.frontier exact.2.2.2.1 live
      ⟨exact.2.2.2.2.1, exact.2.2.2.2.2.1⟩ exact.2.2.2.2.2.2.1 exact.2.2.2.2.2.2.2
  | quarantine key d isolated stored live => exact .uncertain _ _ _ d.epoch d.incarnation stored live ⟨rfl,rfl⟩
  | _ => exact .observation _

theorem reachable_projection (h : Reachable c m s) : Weaver.FiniteStreamManifest.Reachable c m s.base := by
  induction h with
  | init => exact .init
  | next _ event ih => exact .next ih (projection event)

theorem no_duplicate_bytes (h : Reachable c m s) (key b) : (s.base.ranges key).offered b ≤ 1 :=
  Weaver.FiniteStreamManifest.byte_offered_at_most_once (reachable_projection h) key b

theorem shared_escrow (h : Reachable c m s) (b) :
    Weaver.FiniteStreamManifest.accountQuota c m s.base b ≤ Weaver.FiniteDomainMigration.booked c s.base.control.journal.head.payload b ∧
    Weaver.FiniteStreamManifest.accountQuota c m s.base b ≤ c.capacity b := Weaver.FiniteStreamManifest.shared_budget_covered (reachable_projection h) b

theorem retirement_requires_closed_tails (h : Reachable c m s) : Weaver.FiniteStreamManifest.RetirementSafe s.base :=
  Weaver.FiniteStreamManifest.retired_message_has_no_live_tail (reachable_projection h)

theorem result_is_immutable (event : Step c m s t) (prior : s.results key = some q) :
    t.results key = some q := by
  cases event with
  | finish request d online exact pending fresh live =>
    by_cases eq : key = request.key
    · subst key; simp_all
    · simpa [Weaver.FiniteStreamManifest.setAt, eq] using prior
  | _ => exact prior

theorem completion_keeps_ledger (s : State) (q : Request) :
    ({ s with base := { s.base with ranges := Weaver.FiniteStreamManifest.setAt s.base.ranges q.key { s.base.ranges q.key with active := false } }, results := Weaver.FiniteStreamManifest.setAt s.results q.key (some q) } : State).base.control = s.base.control := rfl

theorem completion_keeps_quota (s : State) (q : Request) (k r : Nat) :
    Weaver.FiniteStreamManifest.rangeQuota m ({ s.base with ranges := Weaver.FiniteStreamManifest.setAt s.base.ranges q.key { s.base.ranges q.key with active := false } }) k r = Weaver.FiniteStreamManifest.rangeQuota m s.base k r := by
  by_cases eq : (k,r) = q.key <;> simp [Weaver.FiniteStreamManifest.rangeQuota, Weaver.FiniteStreamManifest.setAt, eq]

theorem restart_does_not_transfer_tail (s : State) (key) (old : s.tails key = some s.generation) :
    ({ s with generation := s.generation + 1, online := true } : State).tails key ≠ some (s.generation + 1) := by
  simp [old]

theorem restart_retains_pending_results_and_slots (s : State) :
    ({ s with generation := s.generation + 1, online := false } : State).pending = s.pending ∧
    ({ s with generation := s.generation + 1, online := false } : State).results = s.results ∧
    ({ s with generation := s.generation + 1, online := false } : State).base = s.base := ⟨rfl,rfl,rfl⟩

theorem stale_request_cannot_finish (old : q.generation ≠ s.generation) : ¬ Exact m s q d := by
  intro exact; exact old exact.2.1

theorem quarantine_cannot_reopen_stream (s : State) (key : Weaver.FiniteStreamManifest.Key) :
    ({ s.base with
      ranges := Weaver.FiniteStreamManifest.setAt s.base.ranges key (Weaver.FiniteStreamManifest.closeRange (s.base.ranges key) (m.spec key.1 key.2).length)
      blocked := Weaver.LogicalMessageAuthority.update s.base.blocked (m.stream key.1) true } : Weaver.FiniteStreamManifest.State).blocked (m.stream key.1) = true := by
  simp [Weaver.LogicalMessageAuthority.update]

theorem pending_is_immutable (event : Step c m s t) (prior : s.pending key = some q) :
    t.pending key = some q := by
  cases event with
  | prepare request d online exact live fresh =>
    by_cases eq : key = request.key
    · subst key; simp_all
    · simpa [Weaver.FiniteStreamManifest.setAt, eq] using prior
  | _ => exact prior

theorem admitted_inactive_stays_inactive
    (event : Weaver.FiniteStreamManifest.Step c m a b)
    (stored : (a.ranges key).admission = some d) (closed : (a.ranges key).active = false) :
    (b.ranges key).active = false := by
  cases event with
  | delegate newKey binding ticket epoch incarnation descriptor gate =>
    by_cases eq : key = newKey
    · subst key; have fresh := gate.fresh; simp_all
    · simpa [Weaver.FiniteStreamManifest.admitted, Weaver.FiniteStreamManifest.setAt, eq] using closed
  | writePrefix newKey d n e inc stored live holder positive bound =>
    by_cases eq : key = newKey
    · subst key; simp_all
    · simpa [Weaver.FiniteStreamManifest.setAt, eq] using closed
  | finishRange newKey =>
    by_cases eq : key = newKey <;> simp_all [Weaver.FiniteStreamManifest.setAt]
  | uncertain newKey =>
    by_cases eq : key = newKey <;> simp_all [Weaver.FiniteStreamManifest.setAt]
  | _ => exact closed

def CompletionSafe (s : State) : Prop :=
  ∀ key q, s.results key = some q → s.pending key = some q ∧
    ∃ d, (s.base.ranges key).admission = some d ∧ (s.base.ranges key).active = false

theorem completion_step_preserves (safe : CompletionSafe s) (event : Step c m s t) : CompletionSafe t := by
  have old (key q) (hr : s.results key = some q) :
      t.pending key = some q ∧ ∃ d, (t.base.ranges key).admission = some d ∧ (t.base.ranges key).active = false := by
    obtain ⟨pending,d,stored,closed⟩ := safe key q hr
    exact ⟨pending_is_immutable event pending,d,
      Weaver.FiniteStreamManifest.range_admission_is_immutable (projection event) stored,
      admitted_inactive_stays_inactive (projection event) stored closed⟩
  cases event with
  | finish request d online exact pending fresh live =>
    intro key q result
    by_cases eq : key = request.key
    · subst key
      have same : q = request := by simpa [Weaver.FiniteStreamManifest.setAt] using result.symm
      subst q
      exact ⟨pending,d,by simpa [Weaver.FiniteStreamManifest.setAt] using exact.2.2.2.1,by simp [Weaver.FiniteStreamManifest.setAt]⟩
    · exact old key q (by simpa [Weaver.FiniteStreamManifest.setAt, eq] using result)
  | _ => exact old

theorem durable_completion_never_releases_another_slot (h : Reachable c m s) : CompletionSafe s := by
  induction h with
  | init => simp [CompletionSafe, initial]
  | next _ event ih => exact completion_step_preserves ih event

theorem original_tail_is_immutable (event : Step c m s t)
    (stored : (s.base.ranges key).admission = some d) : t.tails key = s.tails key := by
  cases event with
  | delegate newKey binding ticket epoch incarnation descriptor online gate =>
    by_cases eq : key = newKey
    · subst key; have fresh := gate.fresh; simp_all
    · simp [Weaver.FiniteStreamManifest.setAt, eq]
  | _ => rfl

theorem settlement_has_independent_final_usage (h : Reachable c m s)
    (charged : (s.base.control.journal.head.payload.messages k).charged = true) :
    (s.base.control.journal.head.payload.messages k).observed = true ∧
    (s.base.control.journal.head.payload.messages k).retired = true ∧
    (s.base.control.journal.head.payload.messages k).finalCost = true ∧
    (s.base.control.journal.head.payload.messages k).reserved = true := by
  have control := (Weaver.FiniteStreamManifest.reachable_invariant (reachable_projection h)).control
  have ledger := (Weaver.ComposedGatewayLifecycle.reachable_invariant control).journal.payload
  exact ((Weaver.FiniteDomainMigration.reachable_invariant ledger).messages k).2.2.2.2.1 charged

theorem finish_changes_only_original_slot (s : State) (q : Request) (different : other ≠ q.key) :
    (Weaver.FiniteStreamManifest.setAt s.base.ranges q.key
      { s.base.ranges q.key with active := false }) other = s.base.ranges other := by
  simp [Weaver.FiniteStreamManifest.setAt, different]

inductive Steps (c : Weaver.FiniteDomainMigration.Config) (m : Weaver.FiniteStreamManifest.Manifest c) : State → State → Prop where
  | refl : Steps c m s s
  | tail : Steps c m s t → Step c m t u → Steps c m s u

theorem trace_projection (trace : Steps c m s t) : Weaver.FiniteStreamManifest.Steps c m s.base t.base := by
  induction trace with
  | refl => exact .refl
  | tail _ event ih => exact .tail ih (projection event)

theorem tail_binding_survives_arbitrary_restarts (trace : Steps c m s t)
    (stored : (s.base.ranges key).admission = some d) :
    t.tails key = s.tails key ∧ (t.base.ranges key).admission = some d := by
  induction trace with
  | refl => exact ⟨rfl,stored⟩
  | tail _ event ih => exact ⟨(original_tail_is_immutable event ih.2).trans ih.1,
      Weaver.FiniteStreamManifest.range_admission_is_immutable (projection event) ih.2⟩

theorem old_driver_never_regains_tail (trace : Steps c m s t)
    (stored : (s.base.ranges key).admission = some d)
    (old : s.tails key = some generation) (newer : generation < t.generation) :
    t.tails key ≠ some t.generation := by
  have kept := (tail_binding_survives_arbitrary_restarts trace stored).1
  rw [kept,old]
  intro same
  have eq : generation = t.generation := Option.some.inj same
  omega

theorem original_claim_history_and_executor_survive (trace : Steps c m s t)
    (claim : (s.base.control.journal.head.payload.messages k).claimed = true)
    (history : (s.base.control.journal.head.payload.messages k).history = true) :
    (t.base.control.journal.head.payload.messages k).claimed = true ∧
    (t.base.control.journal.head.payload.messages k).claimToken = (s.base.control.journal.head.payload.messages k).claimToken ∧
    (t.base.control.journal.head.payload.messages k).claimStream = (s.base.control.journal.head.payload.messages k).claimStream ∧
    (t.base.control.journal.head.payload.messages k).history = true ∧
    t.base.control.journal.head.payload.claimOwner k = s.base.control.journal.head.payload.claimOwner k :=
  Weaver.FiniteStreamManifest.original_claim_and_history_survive_trace (trace_projection trace) claim history

def PendingBound (m : Weaver.FiniteStreamManifest.Manifest c) (s : State) : Prop :=
  ∀ key q, s.pending key = some q → q.key = key ∧ q.manifest = m.identity key.1 ∧
    q.frontier = (m.spec key.1 key.2).length

theorem pending_binding_step (safe : PendingBound m s) (event : Step c m s t) : PendingBound m t := by
  cases event with
  | prepare request d online exact live fresh =>
    intro key q record
    by_cases eq : key = request.key
    · subst key
      have same : q = request := by simpa [Weaver.FiniteStreamManifest.setAt] using record.symm
      subst q
      exact ⟨rfl,exact.1,exact.2.2.2.2.2.2.2⟩
    · exact safe key q (by simpa [Weaver.FiniteStreamManifest.setAt, eq] using record)
  | _ => exact safe

theorem canonical_pending_binding (h : Reachable c m s) : PendingBound m s := by
  induction h with
  | init => simp [PendingBound,initial]
  | next _ event ih => exact pending_binding_step ih event

theorem terminal_result_has_exact_original_binding (h : Reachable c m s)
    (result : s.results key = some q) : q.key = key ∧ q.manifest = m.identity key.1 ∧
    q.frontier = (m.spec key.1 key.2).length :=
  canonical_pending_binding h key q ((durable_completion_never_releases_another_slot h) key q result).1

theorem settled_message_has_no_live_tails (h : Reachable c m s)
    (charged : (s.base.control.journal.head.payload.messages k).charged = true) (r) :
    (s.base.ranges (k,r)).active = false :=
  retirement_requires_closed_tails h (k,r) (settlement_has_independent_final_usage h charged).2.1

#print axioms terminal_result_has_exact_original_binding
#print axioms settled_message_has_no_live_tails
#print axioms old_driver_never_regains_tail
#print axioms original_claim_history_and_executor_survive
#print axioms settlement_has_independent_final_usage
#print axioms finish_changes_only_original_slot
#print axioms durable_completion_never_releases_another_slot
#print axioms pending_is_immutable
#print axioms original_tail_is_immutable
#print axioms reachable_projection
#print axioms no_duplicate_bytes
#print axioms shared_escrow
#print axioms retirement_requires_closed_tails
#print axioms result_is_immutable
#print axioms completion_keeps_ledger
#print axioms completion_keeps_quota
#print axioms restart_does_not_transfer_tail
#print axioms stale_request_cannot_finish
end Weaver.DriverCompletionRecovery
