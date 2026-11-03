-- SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
--
-- SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

import LlmExecutorOffer
namespace Weaver.LlmExecutionReconciliation

structure Decision (S : Type) where
  execution : Weaver.LlmExecutorOffer.State S
  kind : Nat
  cut : Nat
structure State (S : Type) where
  execution : Weaver.LlmExecutorOffer.State S
  source : Weaver.LlmAttemptLedger.State
  epoch : Nat := 0
  qualified : Bool := true
  sealed : Bool := false
  decision : Option (Decision S) := none
  applied : Bool := false
  metered : Bool := false
  amount : Nat := 0
  accountApplied : Bool := false
  released : Nat := 0
structure Owner (S : Type) where
  closedPrefix : Weaver.LlmExecutorOffer.State S → Nat → Prop
  terminal : Weaver.LlmExecutorOffer.State S → Nat → Prop
  usage : Decision S → Nat → Prop
  recovery : State S → Prop
  account : Decision S → Weaver.LlmAttemptLedger.State → Nat → Prop

def Negative (x : Weaver.LlmExecutorOffer.State S) : Prop := x.burn = none ∧ x.submitted = false ∧ x.lane.calls = 0
def Positive (x : Weaver.LlmExecutorOffer.State S) : Prop := x.submitted = true ∧ x.lane.calls = 1
-- A seal retires possible execution, not receipt ingestion. Later progress must preserve these fields.
def SamePower (x y : Weaver.LlmExecutorOffer.State S) : Prop := y.burn = x.burn ∧ y.submitted = x.submitted ∧ y.lane.calls = x.lane.calls

def initial (x : Weaver.LlmExecutorOffer.State S) (a : Weaver.LlmAttemptLedger.State) : State S := ⟨x,a,0,true,false,none,false,false,0,false,0⟩
def Safe (attempt : Weaver.LlmAttemptLedger.Attempt) (s : State S) : Prop :=
  (∀ d, s.decision = some d → s.sealed = true ∧
    (d.kind = 1 ∧ Negative d.execution ∨ d.kind = 2 ∧ Positive d.execution)) ∧
  (s.applied = true → ∃ d, s.decision = some d ∧ s.source.terminal attempt.id = d.kind) ∧
  (s.metered = true → s.applied = true ∧ s.source.usage attempt.id = some s.amount ∧ s.amount ≤ attempt.bound) ∧
  (s.accountApplied = true → s.metered = true ∧ s.released + s.amount = attempt.bound) ∧
  (s.accountApplied = false → s.released = 0)

inductive Step (D : Weaver.LlmExecutorOffer.State S → Weaver.LlmExecutorOffer.State S → Prop) (c : Weaver.LlmRouting.Config)
    (p : Weaver.LlmAttemptLedger.Profile) (ao : Weaver.LlmAttemptLedger.Owner) (attempt : Weaver.LlmAttemptLedger.Attempt) (o : Owner S) : State S → State S → Prop where
  | execution (s next) (actual : D s.execution next)
      (closed : s.sealed = true → SamePower s.execution next) :
      Step D c p ao attempt o s {s with execution := next}
  | closeExecution (s worker) (current : worker = s.epoch) (qualified : s.qualified = true)
      (evidence : o.closedPrefix s.execution s.epoch) :
      Step D c p ao attempt o s {s with sealed := true}
  | negative (s worker) (current : worker = s.epoch) (qualified : s.qualified = true)
      (closed : s.sealed = true) (complete : o.closedPrefix s.execution s.epoch)
      (absent : Negative s.execution) (fresh : s.decision = none) :
      Step D c p ao attempt o s {s with decision := some ⟨s.execution,1,s.epoch⟩}
  | terminal (s worker) (current : worker = s.epoch) (qualified : s.qualified = true)
      (closed : s.sealed = true) (complete : o.closedPrefix s.execution s.epoch)
      (called : Positive s.execution) (valid : o.terminal s.execution 2) (fresh : s.decision = none) :
      Step D c p ao attempt o s {s with decision := some ⟨s.execution,2,s.epoch⟩}
  | sourceProgress (s next) (actual : Weaver.LlmAttemptLedger.Step c p ao s.source next)
      (terminal : next.terminal attempt.id = s.source.terminal attempt.id)
      (usage : next.usage attempt.id = s.source.usage attempt.id)
      (invokeBound : next.calls attempt.id ≠ s.source.calls attempt.id → Positive s.execution) :
      Step D c p ao attempt o s {s with source := next}
  | applySource (s next d worker) (current : worker = s.epoch) (qualified : s.qualified = true)
      (original : s.decision = some d) (fresh : s.applied = false) (unmetered : s.metered = false)
      (unpaid : s.accountApplied = false) (freshTerminal : s.source.terminal attempt.id = 0)
      (aligned : next.calls attempt.id = if d.kind = 1 then 0 else 1) (actual : Weaver.LlmAttemptLedger.Step c p ao s.source next)
      (terminal : next.terminal attempt.id = d.kind) :
      Step D c p ao attempt o s {s with source := next, applied := true}
  | applyUsage (s next d amount worker) (current : worker = s.epoch) (qualified : s.qualified = true)
      (original : s.decision = some d) (applied : s.applied = true) (fresh : s.metered = false)
      (valid : o.usage d amount) (negativeZero : d.kind = 1 → amount = 0)
      (bound : amount ≤ attempt.bound) (freshUsage : s.source.usage attempt.id = none) (actual : Weaver.LlmAttemptLedger.Step c p ao s.source next)
      (terminal : next.terminal attempt.id = s.source.terminal attempt.id)
      (usage : next.usage attempt.id = some amount) :
      Step D c p ao attempt o s {s with source := next, metered := true, amount := amount}
  | applyAccount (s d worker) (current : worker = s.epoch) (qualified : s.qualified = true)
      (original : s.decision = some d) (metered : s.metered = true) (fresh : s.accountApplied = false)
      (valid : o.account d s.source s.amount) :
      Step D c p ao attempt o s {s with accountApplied := true, released := attempt.bound-s.amount}
  | restart (s) : Step D c p ao attempt o s {s with epoch := s.epoch+1, qualified := false}
  | recover (s) (closed : s.qualified = false) (valid : o.recovery s) :
      Step D c p ao attempt o s {s with qualified := true}
  | queryOrLostReply (s) : Step D c p ao attempt o s s

inductive Run (D : Weaver.LlmExecutorOffer.State S → Weaver.LlmExecutorOffer.State S → Prop) (c : Weaver.LlmRouting.Config)
    (p : Weaver.LlmAttemptLedger.Profile) (ao : Weaver.LlmAttemptLedger.Owner) (attempt : Weaver.LlmAttemptLedger.Attempt) (o : Owner S) : State S → State S → Prop where
  | refl (s) : Run D c p ao attempt o s s
  | next : Run D c p ao attempt o a b → Step D c p ao attempt o b d → Run D c p ao attempt o a d

theorem safe_step (h : Safe a s) (e : Step D c p ao a o s t) : Safe a t := by
  rcases h with ⟨dec,applied,metered,account,zero⟩
  cases e with
  | execution next actual closed => exact ⟨dec,applied,metered,account,zero⟩
  | sourceProgress next actual terminal usage invokeBound =>
    refine ⟨dec,?_,?_,account,zero⟩
    · intro ha; obtain ⟨d,hd,ht⟩ := applied ha; exact ⟨d,hd,terminal.trans ht⟩
    · intro hm; obtain ⟨ha,hu,hb⟩ := metered hm; exact ⟨ha,usage.trans hu,hb⟩
  | closeExecution worker current qualified evidence =>
    exact ⟨by intro d hd; exact ⟨rfl,(dec d hd).2⟩,applied,metered,account,zero⟩
  | negative worker current qualified closed complete absent fresh =>
    refine ⟨?_,?_,?_,account,zero⟩
    · intro d hd; cases Option.some.inj hd; exact ⟨closed,Or.inl ⟨rfl,absent⟩⟩
    · intro ha; obtain ⟨d,hd,_⟩ := applied ha; simp [fresh] at hd
    · intro hm; obtain ⟨ha,_,_⟩ := metered hm; obtain ⟨d,hd,_⟩ := applied ha; simp [fresh] at hd
  | terminal worker current qualified closed complete called valid fresh =>
    refine ⟨?_,?_,?_,account,zero⟩
    · intro d hd; cases Option.some.inj hd; exact ⟨closed,Or.inr ⟨rfl,called⟩⟩
    · intro ha; obtain ⟨d,hd,_⟩ := applied ha; simp [fresh] at hd
    · intro hm; obtain ⟨ha,_,_⟩ := metered hm; obtain ⟨d,hd,_⟩ := applied ha; simp [fresh] at hd
  | applySource next d worker current qualified original fresh unmetered unpaid freshTerminal aligned actual terminal =>
    exact ⟨dec,by intro _; exact ⟨d,original,terminal⟩,by simp [unmetered],by simp [unpaid],zero⟩
  | applyUsage next d amount worker current qualified original ha fresh valid negativeZero bound freshUsage actual terminal usage =>
    refine ⟨dec,?_,by intro _; exact ⟨ha,usage,bound⟩,?_,zero⟩
    · intro hap; obtain ⟨d,hd,ht⟩ := applied hap; exact ⟨d,hd,terminal.trans ht⟩
    · intro paid; have bad := (account paid).1; simp [fresh] at bad
  | applyAccount d worker current qualified original hm fresh valid =>
    refine ⟨dec,applied,metered,?_,by simp⟩
    intro _; exact ⟨hm,Nat.sub_add_cancel (metered hm).2.2⟩
  | restart => exact ⟨dec,applied,metered,account,zero⟩
  | recover closed valid => exact ⟨dec,applied,metered,account,zero⟩
  | queryOrLostReply => exact ⟨dec,applied,metered,account,zero⟩

theorem initialized_safe (run : Run D c p ao a o (initial x source) s) : Safe a s := by
  induction run with
  | refl => simp [Safe,initial]
  | next prior event ih => exact safe_step ih event

theorem source_projection (run : Run D c p ao a o s t) : Weaver.LlmAttemptLedger.Run c p ao s.source t.source := by
  induction run with
  | refl => exact .refl _
  | next prior event ih =>
    cases event with
    | sourceProgress next actual terminal usage invokeBound => exact .next ih actual
    | applySource next d worker current qualified original fresh unmetered unpaid freshTerminal aligned actual terminal => exact .next ih actual
    | applyUsage next d amount worker current qualified original ha fresh valid negativeZero bound freshUsage actual terminal usage => exact .next ih actual
    | _ => exact ih

theorem source_composition (run : Run D c p ao a o s t)
    (prefixRun : Weaver.LlmAttemptLedger.Run c p ao Weaver.LlmAttemptLedger.initial s.source) :
    Weaver.LlmAttemptLedger.Run c p ao Weaver.LlmAttemptLedger.initial t.source := by
  induction run with
  | refl => exact prefixRun
  | next prior event ih =>
    have previous := ih
    cases event with
    | sourceProgress next actual terminal usage invokeBound => exact .next previous actual
    | applySource next d worker current qualified original fresh unmetered unpaid freshTerminal aligned actual terminal => exact .next previous actual
    | applyUsage next d amount worker current qualified original ha fresh valid negativeZero bound freshUsage actual terminal usage => exact .next previous actual
    | _ => exact previous

inductive Path (D : T → T → Prop) : T → T → Prop where
  | refl (s) : Path D s s
  | next : Path D a b → D b d → Path D a d

theorem execution_projection (run : Run D c p ao a o s t) : Path D s.execution t.execution := by
  induction run with
  | refl => exact .refl _
  | next prior event ih =>
    cases event with
    | execution next actual closed => exact .next ih actual
    | _ => exact ih

theorem actual_executor_composition
    (mapping : ∀ x y, D x y → Weaver.LlmExecutorOffer.Step op ro R signals A limit Q V qo xo seed x y)
    (run : Run D c p ao a o s t)
    (prefixRun : Weaver.LlmExecutorOffer.Run op ro R signals A limit Q V qo xo seed (Weaver.LlmExecutorOffer.initial seed) s.execution) :
    Weaver.LlmExecutorOffer.Run op ro R signals A limit Q V qo xo seed (Weaver.LlmExecutorOffer.initial seed) t.execution := by
  induction run with
  | refl => exact prefixRun
  | next prior event ih =>
    have previous := ih
    cases event with
    | execution next actual closed => exact .next previous (mapping _ _ actual)
    | _ => exact previous

theorem negative_needs_dispatch_absence (run : Run D c p ao a o (initial x source) s)
    (chosen : s.decision = some d) (negative : d.kind = 1) : Negative d.execution := by
  have h := ((initialized_safe run).1 d chosen).2
  rcases h with h|h
  · exact h.2
  · omega

theorem no_source_zero_premise (x : Weaver.LlmExecutorOffer.State S) (burn : x.burn ≠ none) : ¬ Negative x := by
  intro h; exact burn h.1

theorem unknown_retains_full_reservation (run : Run D c p ao a o (initial x source) s)
    (unknownUsage : s.metered = false) : s.accountApplied = false ∧ s.released = 0 := by
  have h := initialized_safe run
  have unpaid : s.accountApplied = false := by
    cases paid : s.accountApplied with
    | false => rfl
    | true => have bad := (h.2.2.2.1 paid).1; simp [unknownUsage] at bad
  exact ⟨unpaid,h.2.2.2.2 unpaid⟩

theorem source_terminal_precedes_release (run : Run D c p ao a o (initial x source) s)
    (paid : s.accountApplied = true) : ∃ d, s.decision = some d ∧ s.source.terminal a.id = d.kind := by
  have h := initialized_safe run
  exact h.2.1 ((h.2.2.1 ((h.2.2.2.1 paid).1)).1)

theorem release_conserves_original_bound (run : Run D c p ao a o (initial x source) s)
    (paid : s.accountApplied = true) : s.released + s.amount = a.bound :=
  ((initialized_safe run).2.2.2.1 paid).2

theorem decision_immutable (e : Step D c p ao a o s t) (chosen : s.decision = some d) : t.decision = some d := by
  cases e <;> simp_all

theorem account_application_immutable (e : Step D c p ao a o s t) (paid : s.accountApplied = true) :
    t.accountApplied = true ∧ t.released = s.released := by
  cases e <;> simp_all

theorem sealed_execution_cannot_rearm (e : Step D c p ao a o s t) (closed : s.sealed = true) :
    SamePower s.execution t.execution := by
  cases e with
  | execution next actual guard => exact guard closed
  | _ => exact ⟨rfl,rfl,rfl⟩

theorem restart_retains_records (s : State S) :
    ({s with epoch := s.epoch+1, qualified := false} : State S).decision = s.decision ∧
    ({s with epoch := s.epoch+1, qualified := false} : State S).released = s.released := ⟨rfl,rfl⟩
theorem sealed_monotone (e : Step D c p ao a o s t) (closed : s.sealed = true) : t.sealed = true := by
  cases e <;> simp_all

theorem absence_after_seal (run : Run D c p ao a o s t) (closed : s.sealed = true)
    (absent : Negative s.execution) : t.sealed = true ∧ Negative t.execution := by
  induction run with
  | refl => exact ⟨closed,absent⟩
  | next prior event ih =>
    have same := sealed_execution_cannot_rearm event ih.1
    exact ⟨sealed_monotone event ih.1,same.1.trans ih.2.1,same.2.1.trans ih.2.2.1,same.2.2.trans ih.2.2.2⟩

theorem actual_source_capacity (run : Run D c p ao a o s t)
    (prefixRun : Weaver.LlmAttemptLedger.Run c p ao Weaver.LlmAttemptLedger.initial s.source) :
    Weaver.LlmAttemptLedger.total t.source.attempts ≤ c.escrow :=
  Weaver.LlmAttemptLedger.finite_attempt_budget_is_bounded (source_composition run prefixRun)

theorem actual_source_unknown_prevents_close (run : Run D c p ao a o s t)
    (prefixRun : Weaver.LlmAttemptLedger.Run c p ao Weaver.LlmAttemptLedger.initial s.source)
    (registered : a ∈ t.source.attempts) (unknownUsage : t.source.usage a.id = none) : t.source.closed = false :=
  Weaver.LlmAttemptLedger.unknown_usage_prevents_close (source_composition run prefixRun) registered unknownUsage

end Weaver.LlmExecutionReconciliation
#print axioms Weaver.LlmExecutionReconciliation.initialized_safe
#print axioms Weaver.LlmExecutionReconciliation.source_projection
#print axioms Weaver.LlmExecutionReconciliation.source_composition
#print axioms Weaver.LlmExecutionReconciliation.execution_projection
#print axioms Weaver.LlmExecutionReconciliation.actual_executor_composition
#print axioms Weaver.LlmExecutionReconciliation.negative_needs_dispatch_absence
#print axioms Weaver.LlmExecutionReconciliation.no_source_zero_premise
#print axioms Weaver.LlmExecutionReconciliation.unknown_retains_full_reservation
#print axioms Weaver.LlmExecutionReconciliation.source_terminal_precedes_release
#print axioms Weaver.LlmExecutionReconciliation.release_conserves_original_bound
#print axioms Weaver.LlmExecutionReconciliation.decision_immutable
#print axioms Weaver.LlmExecutionReconciliation.account_application_immutable
#print axioms Weaver.LlmExecutionReconciliation.sealed_execution_cannot_rearm
#print axioms Weaver.LlmExecutionReconciliation.restart_retains_records
#print axioms Weaver.LlmExecutionReconciliation.absence_after_seal
#print axioms Weaver.LlmExecutionReconciliation.actual_source_capacity
#print axioms Weaver.LlmExecutionReconciliation.actual_source_unknown_prevents_close
