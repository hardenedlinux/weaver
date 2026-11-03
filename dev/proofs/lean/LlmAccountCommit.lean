-- SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
--
-- SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

import LlmExecutionReconciliation
namespace Weaver.LlmAccountCommit
structure Balance where
  available : Nat
  held : Nat
  charged : Nat
  deriving DecidableEq
structure Transaction where
  application : Nat
  reservation : Nat
  account : Nat
  bound : Nat
  usage : Nat
  resolution : Nat
  sourceApplication : Nat
  usageApplication : Nat
  deriving DecidableEq
structure Image where
  revision : Nat := 0
  balances : Nat → Balance
  holds : Nat → Nat
  applications : Nat → Option Transaction := fun _ => none
  reservations : Nat → Option Nat := fun _ => none
  writes : Nat → Nat := fun _ => 0
structure Proposal where
  transaction : Transaction
  before : Image
  worker : Nat
  sourceGeneration : Nat
structure Record where
  proposal : Proposal
  after : Image
structure State where
  authority : Image
  journal : List Record := []
  localImage : Image
  epoch : Nat := 0
  qualified : Bool := true
  prepared : List Proposal := []
  observations : List Nat := []
  sourceGeneration : Nat := 0
  sourceQualified : Bool := true
structure Owner where
  bound : Nat → Nat
  account : Nat → Nat
  sourceReady : Transaction → State → Prop
  sourceRecovery : State → Prop
  policy : Transaction → Image → Nat → Prop
  prefixAuthentic : State → Prop
  commitDurable : Record → Prop

def put (f : Nat → T) (k : Nat) (v : T) : Nat → T := fun i => if i=k then v else f i

def postBalance (b : Balance) (tx : Transaction) : Balance :=
  ⟨b.available+(tx.bound-tx.usage),b.held-tx.bound,b.charged+tx.usage⟩
def applyImage (image : Image) (tx : Transaction) : Image :=
  ⟨image.revision+1,put image.balances tx.account (postBalance (image.balances tx.account) tx),put image.holds tx.reservation 0,
   put image.applications tx.application (some tx),put image.reservations tx.reservation (some tx.application),
   put image.writes tx.reservation (image.writes tx.reservation+1)⟩
def initial (o : Owner) (balances : Nat → Balance) : State :=
  ⟨⟨0,balances,o.bound,fun _ => none,fun _ => none,fun _ => 0⟩,[],⟨0,balances,o.bound,fun _ => none,fun _ => none,fun _ => 0⟩,0,true,[],[],0,true⟩
def Ready (o : Owner) (s : State) (p : Proposal) : Prop :=
  s.qualified = true ∧ s.localImage = s.authority ∧ p.worker = s.epoch ∧ p.before = s.authority ∧
  p.transaction.bound = o.bound p.transaction.reservation ∧ p.transaction.account = o.account p.transaction.reservation ∧
  p.transaction.usage ≤ p.transaction.bound ∧ o.sourceReady p.transaction s ∧
  o.policy p.transaction s.authority s.epoch ∧ s.authority.applications p.transaction.application = none ∧
  s.authority.reservations p.transaction.reservation = none ∧
  p.transaction.bound ≤ (s.authority.balances p.transaction.account).held ∧
  s.authority.holds p.transaction.reservation = p.transaction.bound ∧
  s.sourceQualified = true ∧ p.sourceGeneration = s.sourceGeneration

inductive Step (o : Owner) : State → State → Prop where
  | prepare (s p) (ready : Ready o s p) : Step o s {s with prepared := s.prepared ++ [p]}
  | commit (s p) (stored : p ∈ s.prepared) (ready : Ready o s p)
      (durable : o.commitDurable ⟨p,applyImage s.authority p.transaction⟩) :
      Step o s {s with authority := applyImage s.authority p.transaction, journal := s.journal ++ [⟨p,applyImage s.authority p.transaction⟩], qualified := false}
  | invalidateSource (s) : Step o s {s with sourceGeneration := s.sourceGeneration+1, sourceQualified := false}
  | qualifySource (s) (valid : o.sourceRecovery s) : Step o s {s with sourceQualified := true}
  | rotate (s) : Step o s {s with epoch := s.epoch+1, qualified := false}
  | restore (s image) (closed : s.qualified = false) : Step o s {s with localImage := image}
  | recover (s) (closed : s.qualified = false) (exact : s.localImage = s.authority)
      (authentic : o.prefixAuthentic s) : Step o s {s with qualified := true}
  | query (s id tx) (known : s.authority.applications id = some tx) (authentic : o.prefixAuthentic s) :
      Step o s {s with observations := s.observations ++ [id]}
  | loseReply (s) : Step o s {s with observations := []}

inductive Run (o : Owner) : State → State → Prop where
  | refl (s) : Run o s s
  | next : Run o a b → Step o b d → Run o a d

def Safe (o : Owner) (genesis : Nat → Balance) (s : State) : Prop :=
  (∀ k, (s.authority.balances k).available + (s.authority.balances k).held + (s.authority.balances k).charged =
    (genesis k).available + (genesis k).held + (genesis k).charged) ∧
  (∀ k, s.authority.writes k ≤ 1 ∧ (s.authority.reservations k = none → s.authority.writes k = 0)) ∧
  (∀ id tx, s.authority.applications id = some tx → tx.application = id ∧ s.authority.reservations tx.reservation = some id) ∧
  (s.qualified = true → s.localImage = s.authority) ∧
  (∀ k, s.authority.reservations k = none → s.authority.holds k = o.bound k)

theorem safe_step (h : Safe o genesis s) (e : Step o s t) : Safe o genesis t := by
  rcases h with ⟨conserved,once,linked,qualified,held⟩
  cases e with
  | commit p stored ready durable =>
    rcases ready with ⟨hq,localExact,worker,before,bound,account,usage,source,policy,fresh,freshSlot,enough,holdBound,sourceQualified,sourceGeneration⟩
    refine ⟨?_,?_,?_,by simp,?_⟩
    · intro k; by_cases eq : k = p.transaction.account
      · subst k; simp [applyImage,put,postBalance]; have old := conserved p.transaction.account; omega
      · simpa [applyImage,put,eq] using conserved k
    · intro k; by_cases eq : k = p.transaction.reservation
      · subst k; simp [applyImage,put,(once _).2 freshSlot]
      · simpa [applyImage,put,eq] using once k
    · intro id tx record; by_cases eq : id = p.transaction.application
      · subst id; have same : tx = p.transaction := by simpa [applyImage,put] using record.symm
        subst tx; exact ⟨rfl,by simp [applyImage,put]⟩
      · have old : s.authority.applications id = some tx := by simpa [applyImage,put,eq] using record
        have original := linked id tx old
        have other : tx.reservation ≠ p.transaction.reservation := by
          intro same; rw [same,freshSlot] at original; simp at original
        exact ⟨original.1,by simpa [applyImage,put,other] using original.2⟩
    · intro k freshK; by_cases eq : k = p.transaction.reservation
      · subst k; simp [applyImage,put] at freshK
      · have original : s.authority.reservations k = none := by simpa [applyImage,put,eq] using freshK
        simpa [applyImage,put,eq] using held k original
  | rotate => exact ⟨conserved,once,linked,by simp,held⟩
  | restore image closed => exact ⟨conserved,once,linked,by simp [closed],held⟩
  | recover closed exact authentic => exact ⟨conserved,once,linked,by intro _; exact exact,held⟩
  | _ => exact ⟨conserved,once,linked,qualified,held⟩

theorem initialized_safe (run : Run o (initial o genesis) s) : Safe o genesis s := by
  induction run with
  | refl => simp [Safe,initial]
  | next prior event ih => exact safe_step ih event

theorem balance_conserved (run : Run o (initial o genesis) s) (account) :
    (s.authority.balances account).available + (s.authority.balances account).held + (s.authority.balances account).charged =
    (genesis account).available + (genesis account).held + (genesis account).charged := (initialized_safe run).1 account

theorem original_reservation_at_most_once (run : Run o (initial o genesis) s) (reservation) : s.authority.writes reservation ≤ 1 :=
  ((initialized_safe run).2.1 reservation).1

theorem application_and_reservation_join (run : Run o (initial o genesis) s)
    (id : Nat) (record : s.authority.applications id = some tx) : tx.application = id ∧ s.authority.reservations tx.reservation = some id :=
  (initialized_safe run).2.2.1 id tx record

theorem applications_immutable (e : Step o s t) (id : Nat) (old : s.authority.applications id = some tx) : t.authority.applications id = some tx := by
  cases e with
  | commit p stored ready durable =>
    have fresh := ready.2.2.2.2.2.2.2.2.2.1
    by_cases same : id = p.transaction.application
    · subst id; simp [old] at fresh
    · simpa [applyImage,put,same] using old
  | _ => exact old

theorem original_reservation_immutable (e : Step o s t) (id : Nat) (old : s.authority.reservations k = some id) : t.authority.reservations k = some id := by
  cases e with
  | commit p stored ready durable =>
    have fresh := ready.2.2.2.2.2.2.2.2.2.2.1
    by_cases same : k = p.transaction.reservation
    · subst k; simp [old] at fresh
    · simpa [applyImage,put,same] using old
  | _ => exact old

theorem commit_is_atomic (e : Step o s t) (changed : t.authority.revision ≠ s.authority.revision) :
    ∃ p, Ready o s p ∧ t.authority = applyImage s.authority p.transaction ∧
      t.journal = s.journal ++ [⟨p,t.authority⟩] ∧ t.qualified = false := by
  cases e with
  | commit p stored ready durable => exact ⟨p,ready,rfl,rfl,rfl⟩
  | _ => exact False.elim (changed rfl)

theorem new_commit_requires_final_source (e : Step o s t) (changed : t.authority.revision ≠ s.authority.revision) :
    ∃ p : Proposal, o.sourceReady p.transaction s ∧ o.policy p.transaction s.authority s.epoch ∧ p.worker = s.epoch := by
  obtain ⟨p,ready,_,_,_⟩ := commit_is_atomic e changed
  exact ⟨p,ready.2.2.2.2.2.2.2.1,ready.2.2.2.2.2.2.2.2.1,ready.2.2.1⟩

theorem stale_before_image_blocks_commit (p : Proposal) (stale : p.before ≠ s.authority) : ¬ Ready o s p := by
  intro h; exact stale h.2.2.2.1

theorem old_worker_blocks_commit (p : Proposal) (old : p.worker ≠ s.epoch) : ¬ Ready o s p := by
  intro h; exact old h.2.2.1

theorem complete_image_before_visibility (run : Run o (initial o genesis) s) (online : s.qualified = true) : s.localImage = s.authority :=
  (initialized_safe run).2.2.2.1 online

theorem restore_cannot_rollback_authority (s : State) (image : Image) :
    ({s with localImage := image} : State).authority = s.authority := rfl

theorem commit_response_loss_preserves_result (s : State) :
    ({s with observations := []} : State).authority = s.authority := rfl

theorem account_zero_delta_is_still_consumed (run : Run o (initial o genesis) s)
    (id : Nat) (record : s.authority.applications id = some tx) (zero : tx.usage = tx.bound) :
    s.authority.reservations tx.reservation = some id ∧ tx.bound-tx.usage = 0 := by
  exact ⟨(application_and_reservation_join run id record).2,by omega⟩

-- Concrete bridge from the actual preceding reconciliation model to account evidence.
def OriginalReady (originalKey : Nat) (attempt : Weaver.LlmAttemptLedger.Attempt) (source : Weaver.LlmExecutionReconciliation.State S) (tx : Transaction) : Prop :=
  source.metered = true ∧ source.amount = tx.usage ∧ tx.bound = attempt.bound ∧ tx.reservation = originalKey

theorem actual_reconciliation_has_terminal_and_bound
    (run : Weaver.LlmExecutionReconciliation.Run D c p ao a ro (Weaver.LlmExecutionReconciliation.initial x seed) source)
    (ready : OriginalReady originalKey a source tx) :
    (∃ d, source.decision = some d ∧ source.source.terminal a.id = d.kind) ∧ tx.usage ≤ tx.bound := by
  have safe := Weaver.LlmExecutionReconciliation.initialized_safe run
  have metered := safe.2.2.1 ready.1
  exact ⟨safe.2.1 metered.1,by rw [← ready.2.1,ready.2.2.1]; exact metered.2.2⟩

theorem unknown_reconciliation_has_no_account_authority
    (source : Weaver.LlmExecutionReconciliation.State S) (unknownUsage : source.metered = false) :
    ¬ OriginalReady originalKey a source tx := by
  intro h; have bad := h.1; simp [unknownUsage] at bad
theorem unknown_reservation_hold_is_unchanged (run : Run o (initial o genesis) s)
    (unapplied : s.authority.reservations k = none) : s.authority.holds k = o.bound k :=
  (initialized_safe run).2.2.2.2 k unapplied

theorem journal_revision (run : Run o (initial o genesis) s) : s.authority.revision = s.journal.length := by
  induction run with
  | refl => rfl
  | next prior event ih => cases event <;> simp_all [applyImage]

theorem journal_prefix_retained (event : Step o s t) : ∃ suffix, t.journal = s.journal ++ suffix := by
  cases event with
  | commit p stored ready durable => exact ⟨[⟨p,applyImage s.authority p.transaction⟩],rfl⟩
  | _ => exact ⟨[],by simp⟩

theorem commit_joins_actual_reconciliation
    (sourceRun : Weaver.LlmExecutionReconciliation.Run D c profile ao attempt ro (Weaver.LlmExecutionReconciliation.initial x seed) source)
    (binding : ∀ tx, o.sourceReady tx s → OriginalReady originalKey attempt source tx)
    (event : Step o s t) (changed : t.authority.revision ≠ s.authority.revision) :
    ∃ tx : Transaction, tx.reservation = originalKey ∧ tx.usage ≤ tx.bound ∧
      ∃ d, source.decision = some d ∧ source.source.terminal attempt.id = d.kind := by
  obtain ⟨proposal,ready,_,_,_⟩ := commit_is_atomic event changed
  have evidence := binding proposal.transaction ready.2.2.2.2.2.2.2.1
  have original := actual_reconciliation_has_terminal_and_bound sourceRun evidence
  exact ⟨proposal.transaction,evidence.2.2.2,original.2,original.1⟩

theorem changed_source_generation_blocks_commit (p : Proposal)
    (changed : p.sourceGeneration ≠ s.sourceGeneration) : ¬ Ready o s p := by
  intro h; exact changed h.2.2.2.2.2.2.2.2.2.2.2.2.2.2

theorem blocked_reservation_unapplied (run : Run o (initial o genesis) s)
    (blocked : ∀ tx state, tx.reservation = k → o.sourceReady tx state → False) :
    s.authority.reservations k = none := by
  induction run with
  | refl => rfl
  | next prior event ih =>
    cases event with
    | commit p stored ready durable =>
      by_cases eq : k = p.transaction.reservation
      · exact False.elim (blocked p.transaction _ eq.symm ready.2.2.2.2.2.2.2.1)
      · simpa [applyImage,put,eq] using ih
    | _ => exact ih

theorem unknown_source_retains_original_hold (run : Run o (initial o genesis) s)
    (source : Weaver.LlmExecutionReconciliation.State S) (unknownUsage : source.metered = false)
    (binding : ∀ tx state, tx.reservation = originalKey → o.sourceReady tx state → OriginalReady originalKey attempt source tx) :
    s.authority.reservations originalKey = none ∧ s.authority.holds originalKey = o.bound originalKey := by
  have unapplied := blocked_reservation_unapplied run (fun tx state key ready =>
    unknown_reconciliation_has_no_account_authority source unknownUsage (binding tx state key ready))
  exact ⟨unapplied,unknown_reservation_hold_is_unchanged run unapplied⟩

end Weaver.LlmAccountCommit
#print axioms Weaver.LlmAccountCommit.initialized_safe
#print axioms Weaver.LlmAccountCommit.balance_conserved
#print axioms Weaver.LlmAccountCommit.original_reservation_at_most_once
#print axioms Weaver.LlmAccountCommit.application_and_reservation_join
#print axioms Weaver.LlmAccountCommit.applications_immutable
#print axioms Weaver.LlmAccountCommit.original_reservation_immutable
#print axioms Weaver.LlmAccountCommit.commit_is_atomic
#print axioms Weaver.LlmAccountCommit.new_commit_requires_final_source
#print axioms Weaver.LlmAccountCommit.stale_before_image_blocks_commit
#print axioms Weaver.LlmAccountCommit.old_worker_blocks_commit
#print axioms Weaver.LlmAccountCommit.complete_image_before_visibility
#print axioms Weaver.LlmAccountCommit.restore_cannot_rollback_authority
#print axioms Weaver.LlmAccountCommit.commit_response_loss_preserves_result
#print axioms Weaver.LlmAccountCommit.account_zero_delta_is_still_consumed
#print axioms Weaver.LlmAccountCommit.actual_reconciliation_has_terminal_and_bound
#print axioms Weaver.LlmAccountCommit.unknown_reconciliation_has_no_account_authority
#print axioms Weaver.LlmAccountCommit.unknown_reservation_hold_is_unchanged
#print axioms Weaver.LlmAccountCommit.journal_revision
#print axioms Weaver.LlmAccountCommit.journal_prefix_retained
#print axioms Weaver.LlmAccountCommit.commit_joins_actual_reconciliation
#print axioms Weaver.LlmAccountCommit.changed_source_generation_blocks_commit
#print axioms Weaver.LlmAccountCommit.blocked_reservation_unapplied
#print axioms Weaver.LlmAccountCommit.unknown_source_retains_original_hold
