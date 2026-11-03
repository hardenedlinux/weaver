-- SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
--
-- SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

import CommittedSemanticProfile
namespace Weaver.GerbilExitQualification
-- Handles denote FFI-loaded library acquisitions. Qualification does not need
-- an auxiliary executable; package tests and actual execution remain distinct.
-- Config.source abstracts the complete maintained project input closure, not
-- only runtime files or the directly checked model. Go SourceInputs inventories
-- formal trees and Org/D2 sources; plan-derived tests require every gate root.
-- Native before/after hashing is not an atomic snapshot or cache-integrity proof.
inductive Entry where
  | packageTest
  | diagnostic
  | instrumentedPackageTest
  deriving DecidableEq
structure Config where
  expectedChecks : Nat
  budget : Nat
  source : Nat
structure State where
  entry : Entry := .packageTest
  source : Nat
  checks : Nat := 0
  duplicateRejected : Bool := false
  complete : Bool := false
  returned : Bool := false
  handles : List Nat := []
  everOpened : List Nat := []
  closed : List Nat := []
  elapsed : Nat := 0
  exited : Bool := false

def initial (c : Config) : State := {source := c.source}
inductive Step (c : Config) : State → State → Prop where
  | check (s) (live : s.returned = false) (fresh : s.complete = false) :
      Step c s {s with checks := s.checks+1}
  | rejectDuplicate (s) (live : s.returned = false) : Step c s {s with duplicateRejected := true}
  | finishChecks (s) (exact : s.checks = c.expectedChecks) (decoder : s.duplicateRejected = true)
      (live : s.returned = false) : Step c s {s with complete := true}
  | acquire (s handle) (live : s.returned = false) (fresh : handle ∉ s.everOpened) :
      Step c s {s with handles := handle::s.handles,everOpened := handle::s.everOpened}
  | release (s handle) (owned : handle ∈ s.handles) (live : s.exited = false) :
      Step c s {s with handles := s.handles.filter (fun h => h != handle),closed := handle::s.closed}
  | returnMain (s) (checked : s.complete = true) : Step c s {s with returned := true}
  | tick (s) (live : s.exited = false) : Step c s {s with elapsed := s.elapsed+1}
  | naturalExit (s) (returned : s.returned = true) (clean : s.handles = []) :
      Step c s {s with exited := true}
inductive Run (c : Config) : State → State → Prop where
  | refl (s) : Run c s s
  | next : Run c a b → Step c b d → Run c a d

def Audit (c : Config) (s : State) : Prop :=
  s.source = c.source ∧
  (s.complete = true → s.checks = c.expectedChecks ∧ s.duplicateRejected = true) ∧
  (s.returned = true → s.complete = true) ∧
  (s.exited = true → s.returned = true ∧ s.handles = [])

theorem audit_step (safe : Audit c s) (event : Step c s t) : Audit c t := by
  rcases safe with ⟨source,checks,returned,exit⟩
  cases event with
  | check live fresh =>
    refine ⟨source,?_,returned,exit⟩
    intro completed; simp [fresh] at completed
  | rejectDuplicate live =>
    refine ⟨source,?_,returned,exit⟩
    intro completed; exact ⟨(checks completed).1,rfl⟩
  | finishChecks exact decoder live => exact ⟨source,fun _ => ⟨exact,decoder⟩,fun _ => rfl,exit⟩
  | acquire handle live fresh =>
    refine ⟨source,checks,returned,?_⟩
    intro exited; have wasReturned := (exit exited).1; simp [live] at wasReturned
  | release handle owned live =>
    refine ⟨source,checks,returned,?_⟩
    intro exited; simp [live] at exited
  | returnMain checked => exact ⟨source,checks,fun _ => checked,fun exited => ⟨rfl,(exit exited).2⟩⟩
  | tick live => exact ⟨source,checks,returned,exit⟩
  | naturalExit wasReturned clean => exact ⟨source,checks,returned,fun _ => ⟨wasReturned,clean⟩⟩

theorem initialized_audit (run : Run c (initial c) s) : Audit c s := by
  induction run with
  | refl => simp [Audit,initial]
  | next prior event ih => exact audit_step ih event

def Qualified (c : Config) (s : State) : Prop :=
  Audit c s ∧ s.exited = true ∧ s.elapsed ≤ c.budget ∧ s.entry = .packageTest

theorem qualification_preserves_deadline (accepted : Qualified c s) : s.elapsed ≤ c.budget :=
  accepted.2.2.1

theorem package_entry_required (accepted : Qualified c s) : s.entry = .packageTest :=
  accepted.2.2.2

theorem completion_marker_is_insufficient (noExit : s.exited = false) : ¬ Qualified c s := by
  intro accepted; have exited := accepted.2.1; simp [noExit] at exited

theorem qualification_preserves_cleanup (accepted : Qualified c s) : s.returned = true ∧ s.handles = [] :=
  accepted.1.2.2.2 accepted.2.1

theorem qualification_preserves_actual_checks (accepted : Qualified c s) :
    s.checks = c.expectedChecks ∧ s.duplicateRejected = true :=
  accepted.1.2.1 (accepted.1.2.2.1 (qualification_preserves_cleanup accepted).1)

theorem late_natural_exit_still_fails (late : c.budget < s.elapsed) : ¬ Qualified c s := by
  intro accepted; have bound := accepted.2.2.1; omega

theorem wrong_source_is_not_qualified (wrong : s.source ≠ c.source) : ¬ Qualified c s := by
  intro accepted; exact wrong accepted.1.1

theorem live_handle_blocks_qualification (live : s.handles ≠ []) : ¬ Qualified c s := by
  intro accepted; exact live (qualification_preserves_cleanup accepted).2

theorem natural_pass_still_needs_gateway_policy (_accepted : Qualified c receipt)
    (event : LlmRouting.Step router owner before after) (changed : after.dispatches ≠ before.dispatches) :
    ∃ p, owner.wireValid p ∧ owner.finalPolicyValid p (LlmRouting.view before) := by
  obtain ⟨p,stored,bound,current,eligible,wire,policy,fresh⟩ := LlmRouting.actual_dispatch_rechecks_target event changed
  exact ⟨p,wire,policy⟩

theorem instrumented_sdk_is_not_acceptance (profiled : s.entry = .instrumentedPackageTest) :
    ¬ Qualified c s := by
  intro accepted
  have entry := package_entry_required accepted
  simp [profiled] at entry

namespace TimingStudy
-- Ordered native observations are premises, not a proof of the OS clock,
-- dyld implementation, file-cache state or host scheduling fairness.
structure Cuts where
  start : Nat
  discoveryBegin : Nat
  discoveryEnd : Nat
  importsBegin : Nat
  importsEnd : Nat
  executionBegin : Nat
  executionEnd : Nat
  returned : Nat
  exited : Nat

def Ordered (o : Cuts) : Prop :=
  o.start ≤ o.discoveryBegin ∧ o.discoveryBegin ≤ o.discoveryEnd ∧
  o.discoveryEnd ≤ o.importsBegin ∧ o.importsBegin ≤ o.importsEnd ∧
  o.importsEnd ≤ o.executionBegin ∧ o.executionBegin ≤ o.executionEnd ∧
  o.executionEnd ≤ o.returned ∧ o.returned ≤ o.exited

theorem observed_partition (ordered : Ordered o) :
    (o.discoveryBegin-o.start) + (o.discoveryEnd-o.discoveryBegin) +
    (o.importsBegin-o.discoveryEnd) + (o.importsEnd-o.importsBegin) +
    (o.executionBegin-o.importsEnd) + (o.executionEnd-o.executionBegin) +
    (o.returned-o.executionEnd) + (o.exited-o.returned) = o.exited-o.start := by
  unfold Ordered at ordered
  omega

theorem bounded_cleanup_does_not_bound_total :
    ∃ o : Cuts, Ordered o ∧ o.exited-o.returned ≤ 2 ∧ o.exited-o.start > 15 := by
  exact ⟨⟨0,2,2,2,13,13,15,15,16⟩, by simp [Ordered], by decide, by decide⟩

structure Trial where
  id : Nat
  study : Nat
  artifact : Nat
  firstUse : Bool
  native : State

def Matched (a b : Trial) : Prop :=
  a.study = b.study ∧ a.firstUse = true ∧ b.firstUse = true ∧
  a.artifact ≠ b.artifact ∧ a.native.entry = .packageTest ∧ b.native.entry = .packageTest

theorem warm_replay_is_not_a_cold_pair (warm : b.firstUse = false) : ¬ Matched a b := by
  intro pair
  have cold := pair.2.2.1
  simp [warm] at cold

theorem new_source_cannot_be_silently_paired (changed : a.study ≠ b.study) : ¬ Matched a b := by
  intro pair
  exact changed pair.1

theorem reused_artifact_is_not_independent (same : a.artifact = b.artifact) : ¬ Matched a b := by
  intro pair
  exact pair.2.2.2.1 same

-- Appending a successful observation cannot mutate an earlier failed receipt.
-- Native collectors must also enforce unique slot IDs and exact study keys.
theorem append_preserves_failed_receipt (present : old ∈ history)
    (failed : ¬ Qualified c old.native) (next : Trial) :
    old ∈ history ++ [next] ∧ ¬ Qualified c old.native := by
  exact ⟨List.mem_append_left _ present,failed⟩

end TimingStudy

#print axioms audit_step
#print axioms package_entry_required
#print axioms initialized_audit
#print axioms completion_marker_is_insufficient
#print axioms qualification_preserves_cleanup
#print axioms qualification_preserves_actual_checks
#print axioms late_natural_exit_still_fails
#print axioms wrong_source_is_not_qualified
#print axioms live_handle_blocks_qualification
#print axioms natural_pass_still_needs_gateway_policy
#print axioms instrumented_sdk_is_not_acceptance
#print axioms TimingStudy.observed_partition
#print axioms TimingStudy.bounded_cleanup_does_not_bound_total
#print axioms TimingStudy.warm_replay_is_not_a_cold_pair
#print axioms TimingStudy.new_source_cannot_be_silently_paired
#print axioms TimingStudy.reused_artifact_is_not_independent
#print axioms TimingStudy.append_preserves_failed_receipt
end Weaver.GerbilExitQualification
