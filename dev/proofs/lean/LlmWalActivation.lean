-- SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
--
-- SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

import LlmAccountCommit
namespace Weaver.LlmWalActivation
structure Receipt where
  head : Weaver.LlmAccountCommit.Image
  journal : List Weaver.LlmAccountCommit.Record
  epoch : Nat
  sourceGeneration : Nat
structure State where
  core : Weaver.LlmAccountCommit.State
  wal : List Weaver.LlmAccountCommit.Record := []
  submitted : List Weaver.LlmAccountCommit.Record := []
  receipt : Option Receipt := none
  active : Bool := false
structure Owner where
  walDurable : Weaver.LlmAccountCommit.Record → Prop
  candidateDurable : Weaver.LlmAccountCommit.Record → Prop
  prefixAuthentic : State → Prop

def frame (p : Weaver.LlmAccountCommit.Proposal) : Weaver.LlmAccountCommit.Record :=
  ⟨p,Weaver.LlmAccountCommit.applyImage p.before p.transaction⟩
def current (s : State) : Receipt := ⟨s.core.authority,s.core.journal,s.core.epoch,s.core.sourceGeneration⟩
def Current (s : State) : Prop := s.receipt = some (current s)
def CompleteWal (s : State) : Prop := ∃ tail, s.wal = s.core.journal ++ tail
def Live (s : State) : Prop := s.active = true → s.core.qualified = true ∧
  s.core.localImage = s.core.authority ∧ s.core.sourceQualified = true ∧ Current s ∧ CompleteWal s

def initial (accountOwner : Weaver.LlmAccountCommit.Owner) (genesis : Nat → Weaver.LlmAccountCommit.Balance) : State :=
  let base := Weaver.LlmAccountCommit.initial accountOwner genesis
  ⟨base,[],[],some ⟨base.authority,[],0,0⟩,true⟩

inductive Step (ao : Weaver.LlmAccountCommit.Owner) (o : Owner) : State → State → Prop where
  | prepare (s p) (live : s.active = true) (ready : Weaver.LlmAccountCommit.Ready ao s.core p) :
      Step ao o s {s with core := {s.core with prepared := s.core.prepared ++ [p]}}
  | flush (s p) (stored : p ∈ s.core.prepared) (ready : Weaver.LlmAccountCommit.Ready ao s.core p)
      (exact : s.wal = s.core.journal) (durable : o.walDurable (frame p)) :
      Step ao o s {s with wal := s.wal ++ [frame p]}
  | submit (s p) (recorded : frame p ∈ s.wal) (stored : p ∈ s.core.prepared)
      (ready : Weaver.LlmAccountCommit.Ready ao s.core p) (durable : o.candidateDurable (frame p)) :
      Step ao o s {s with submitted := s.submitted ++ [frame p], active := false}
  | anchor (s p) (accepted : frame p ∈ s.submitted) (stored : p ∈ s.core.prepared)
      (ready : Weaver.LlmAccountCommit.Ready ao s.core p)
      (durable : ao.commitDurable ⟨p,Weaver.LlmAccountCommit.applyImage s.core.authority p.transaction⟩) :
      Step ao o s {s with core := {s.core with authority := Weaver.LlmAccountCommit.applyImage s.core.authority p.transaction, journal := s.core.journal ++ [⟨p,Weaver.LlmAccountCommit.applyImage s.core.authority p.transaction⟩], qualified := false}, active := false}
  | rotate (s) : Step ao o s {s with core := {s.core with epoch := s.core.epoch+1, qualified := false}, active := false}
  | invalidateSource (s) : Step ao o s {s with core := {s.core with sourceGeneration := s.core.sourceGeneration+1, sourceQualified := false}, active := false}
  | qualifySource (s) (authentic : ao.sourceRecovery s.core) :
      Step ao o s {s with core := {s.core with sourceQualified := true}, active := false}
  | restoreWal (s records) : Step ao o s {s with wal := records, active := false}
  | repairWal (s) (authentic : o.prefixAuthentic s) : Step ao o s {s with wal := s.core.journal, active := false}
  | observe (s) (authentic : o.prefixAuthentic s) : Step ao o s {s with receipt := some (current s)}
  | install (s) (closed : s.core.qualified = false) (confirmed : Current s) (complete : CompleteWal s)
      (authentic : o.prefixAuthentic s) :
      Step ao o s {s with core := {s.core with localImage := s.core.authority}, active := false}
  | activateRecovered (s) (closed : s.core.qualified = false) (exact : s.core.localImage = s.core.authority)
      (confirmed : Current s) (complete : CompleteWal s) (sourceReady : s.core.sourceQualified = true)
      (authentic : ao.prefixAuthentic s.core) (currentPrefix : o.prefixAuthentic s) :
      Step ao o s {s with core := {s.core with qualified := true}, active := true}
  | activateCurrent (s) (qualified : s.core.qualified = true) (exact : s.core.localImage = s.core.authority)
      (confirmed : Current s) (complete : CompleteWal s) (sourceReady : s.core.sourceQualified = true)
      (authentic : o.prefixAuthentic s) : Step ao o s {s with active := true}
  | loseReply (s) : Step ao o s {s with receipt := none, active := false}

inductive Run (ao : Weaver.LlmAccountCommit.Owner) (o : Owner) : State → State → Prop where
  | refl (s) : Run ao o s s
  | next : Run ao o a b → Step ao o b d → Run ao o a d

theorem core_projection (event : Step ao o s t) : Weaver.LlmAccountCommit.Run ao s.core t.core := by
  cases event with
  | prepare p live ready => exact .next (.refl _) (.prepare _ _ ready)
  | anchor p accepted stored ready durable => exact .next (.refl _) (.commit _ _ stored ready durable)
  | rotate => exact .next (.refl _) (.rotate _)
  | invalidateSource => exact .next (.refl _) (.invalidateSource _)
  | qualifySource authentic => exact .next (.refl _) (.qualifySource _ authentic)
  | install closed confirmed complete authentic => exact .next (.refl _) (.restore _ _ closed)
  | activateRecovered closed exact confirmed complete sourceReady authentic currentPrefix => exact .next (.refl _) (.recover _ closed exact authentic)
  | _ => exact .refl _

theorem core_extend (suffixRun : Weaver.LlmAccountCommit.Run ao a b) (prefixRun : Weaver.LlmAccountCommit.Run ao x a) :
    Weaver.LlmAccountCommit.Run ao x b := by
  induction suffixRun with
  | refl => exact prefixRun
  | next prior event ih => exact .next ih event

theorem actual_account_composition (run : Run ao o s t)
    (prefixRun : Weaver.LlmAccountCommit.Run ao (Weaver.LlmAccountCommit.initial ao genesis) s.core) :
    Weaver.LlmAccountCommit.Run ao (Weaver.LlmAccountCommit.initial ao genesis) t.core := by
  induction run with
  | refl => exact prefixRun
  | next prior event ih => exact core_extend (core_projection event) ih

theorem live_step (safe : Live s) (event : Step ao o s t) : Live t := by
  cases event with
  | prepare p live ready =>
    have old := safe live
    exact fun _ => ⟨old.1,old.2.1,old.2.2.1,old.2.2.2.1,old.2.2.2.2⟩
  | flush p stored ready exact durable =>
    intro live; have old := safe live
    refine ⟨old.1,old.2.1,old.2.2.1,old.2.2.2.1,?_⟩
    exact ⟨[frame p],by simp [exact]⟩
  | observe authentic =>
    intro live; have old := safe live
    exact ⟨old.1,old.2.1,old.2.2.1,rfl,old.2.2.2.2⟩
  | activateRecovered closed exact confirmed complete sourceReady authentic currentPrefix =>
    exact fun _ => ⟨rfl,exact,sourceReady,confirmed,complete⟩
  | activateCurrent qualified exact confirmed complete sourceReady authentic =>
    exact fun _ => ⟨qualified,exact,sourceReady,confirmed,complete⟩
  | _ => simp [Live]

theorem initialized_live (run : Run ao o (initial ao genesis) s) : Live s := by
  induction run with
  | refl => exact fun _ => ⟨rfl,rfl,rfl,rfl,[],rfl⟩
  | next prior event ih => exact live_step ih event

theorem visible_balance_is_current (run : Run ao o (initial ao genesis) s) (visible : s.active = true) :
    s.core.localImage = s.core.authority ∧ Current s ∧ CompleteWal s := by
  have safe := initialized_live run visible
  exact ⟨safe.2.1,safe.2.2.2.1,safe.2.2.2.2⟩

theorem original_reservation_once (run : Run ao o (initial ao genesis) s) (key) : s.core.authority.writes key ≤ 1 :=
  Weaver.LlmAccountCommit.original_reservation_at_most_once (actual_account_composition run (.refl _)) key

theorem account_conservation (run : Run ao o (initial ao genesis) s) (account) :
    (s.core.authority.balances account).available + (s.core.authority.balances account).held + (s.core.authority.balances account).charged =
    (genesis account).available + (genesis account).held + (genesis account).charged :=
  Weaver.LlmAccountCommit.balance_conserved (actual_account_composition run (.refl _)) account

theorem committed_application_retained (event : Step ao o s t) (id : Nat)
    (old : s.core.authority.applications id = some tx) : t.core.authority.applications id = some tx := by
  cases event with
  | anchor p accepted stored ready durable =>
    exact Weaver.LlmAccountCommit.applications_immutable (.commit _ _ stored ready durable) id old
  | _ => exact old

theorem truncated_wal_cannot_be_visible (run : Run ao o (initial ao genesis) s) (missing : ¬ CompleteWal s) : s.active = false := by
  cases live : s.active with
  | false => rfl
  | true => exact False.elim (missing ((initialized_live run live).2.2.2.2))

theorem changed_epoch_invalidates_confirmation (s : State) (known : Current s) :
    ¬ Current {s with core := {s.core with epoch := s.core.epoch+1}} := by
  intro bad; unfold Current current at known bad
  have same := Option.some.inj (known.symm.trans bad)
  have epoch := congrArg Receipt.epoch same
  simp at epoch

theorem repair_does_not_change_account (s : State) :
    ({s with wal := s.core.journal, active := false} : State).core.authority = s.core.authority := rfl

theorem unconfirmed_candidate_has_no_financial_effect (s : State) (p) :
    ({s with submitted := s.submitted ++ [frame p], active := false} : State).core.authority = s.core.authority := rfl

theorem wal_flush_has_no_financial_effect (s : State) (p) :
    ({s with wal := s.wal ++ [frame p]} : State).core.authority = s.core.authority := rfl

theorem stale_worker_cannot_anchor (s : State) (p : Weaver.LlmAccountCommit.Proposal)
    (old : p.worker ≠ s.core.epoch) : ¬ Weaver.LlmAccountCommit.Ready ao s.core p :=
  Weaver.LlmAccountCommit.old_worker_blocks_commit p old

theorem committed_prefix_retained (event : Step ao o s t) : ∃ tail, t.core.journal = s.core.journal ++ tail := by
  cases event with
  | anchor p accepted stored ready durable => exact ⟨[⟨p,Weaver.LlmAccountCommit.applyImage s.core.authority p.transaction⟩],rfl⟩
  | _ => exact ⟨[],by simp⟩

theorem unknown_budget_hold_retained (run : Run ao o (initial ao genesis) s)
    (source : Weaver.LlmExecutionReconciliation.State S) (unknownUsage : source.metered = false)
    (binding : ∀ tx state, tx.reservation = originalKey → ao.sourceReady tx state →
      Weaver.LlmAccountCommit.OriginalReady originalKey attempt source tx) :
    s.core.authority.reservations originalKey = none ∧ s.core.authority.holds originalKey = ao.bound originalKey :=
  Weaver.LlmAccountCommit.unknown_source_retains_original_hold (actual_account_composition run (.refl _)) source unknownUsage binding
theorem financial_change_requires_anchor (event : Step ao o s t)
    (changed : t.core.authority.revision ≠ s.core.authority.revision) :
    ∃ p : Weaver.LlmAccountCommit.Proposal, frame p ∈ s.submitted ∧
      Weaver.LlmAccountCommit.Ready ao s.core p ∧ t.core.authority = Weaver.LlmAccountCommit.applyImage s.core.authority p.transaction ∧ t.active = false := by
  cases event with
  | anchor p accepted stored ready durable => exact ⟨p,accepted,ready,rfl,rfl⟩
  | _ => exact False.elim (changed rfl)

theorem accepted_candidate_retained (event : Step ao o s t) (accepted : record ∈ s.submitted) : record ∈ t.submitted := by
  cases event with
  | submit p recorded stored ready durable => simp only [List.mem_append]; exact Or.inl accepted
  | _ => exact accepted

end Weaver.LlmWalActivation
#print axioms Weaver.LlmWalActivation.core_projection
#print axioms Weaver.LlmWalActivation.actual_account_composition
#print axioms Weaver.LlmWalActivation.initialized_live
#print axioms Weaver.LlmWalActivation.visible_balance_is_current
#print axioms Weaver.LlmWalActivation.original_reservation_once
#print axioms Weaver.LlmWalActivation.account_conservation
#print axioms Weaver.LlmWalActivation.committed_application_retained
#print axioms Weaver.LlmWalActivation.truncated_wal_cannot_be_visible
#print axioms Weaver.LlmWalActivation.changed_epoch_invalidates_confirmation
#print axioms Weaver.LlmWalActivation.repair_does_not_change_account
#print axioms Weaver.LlmWalActivation.unconfirmed_candidate_has_no_financial_effect
#print axioms Weaver.LlmWalActivation.wal_flush_has_no_financial_effect
#print axioms Weaver.LlmWalActivation.stale_worker_cannot_anchor
#print axioms Weaver.LlmWalActivation.committed_prefix_retained
#print axioms Weaver.LlmWalActivation.unknown_budget_hold_retained
#print axioms Weaver.LlmWalActivation.financial_change_requires_anchor
#print axioms Weaver.LlmWalActivation.accepted_candidate_retained
