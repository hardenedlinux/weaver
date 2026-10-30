import CommittedSemanticProfile
namespace Weaver.NativeExitQualification
inductive Entry where
  | packageTest
  | diagnostic
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
end Weaver.NativeExitQualification
