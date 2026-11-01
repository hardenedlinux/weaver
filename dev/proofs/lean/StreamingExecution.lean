namespace Weaver.StreamingExecution

/- Native refinement premises: authentic source and cost bounds; durable SQLite
   CAS/lock semantics; non-forgeable Rust capabilities; immutable BLOB ownership;
   unused canonical range at send; faithful bounded TCP/TLS observations.
   No compiler, filesystem power-loss, provider exactly-once or native timing proof. -/
structure State (Message : Type) where
  held : Nat := 0
  reserved : Message → Bool := fun _ => false
  unknown : Message → Bool := fun _ => false
  calls : Message × Nat → Nat := fun _ => 0
  revision : Nat := 0
  fence : Nat := 1
  generation : Nat := 0

def Safe (budget : Nat) (s : State M) : Prop :=
  s.held ≤ budget ∧ (∀ key, s.calls key ≤ 1) ∧
  (∀ m, s.unknown m = true → s.reserved m = true)

structure Permit (M : Type) where
  message : M
  offset : Nat
  revision : Nat
  fence : Nat
  generation : Nat

def Current (s : State M) (p : Permit M) : Prop :=
  p.revision = s.revision ∧ p.fence = s.fence ∧ p.generation = s.generation

def Resumable (s : State M) (m : M) : Prop := s.unknown m = false

structure ExecutorEvidence (M : Type) where
  zeroCallAndRetired : State M → M → Prop

inductive Step {M : Type} [DecidableEq M] (owner : ExecutorEvidence M) (budget : Nat) : State M → State M → Prop where
  | reserve (s m cost) (positive : 0 < cost) (fresh : s.reserved m = false)
      (capacity : s.held + cost ≤ budget) : Step owner budget s
      {s with held := s.held+cost, reserved := fun x => if x=m then true else s.reserved x}
  | burn (s m) (reserved : s.reserved m = true) : Step owner budget s
      {s with unknown := fun x => if x=m then true else s.unknown x}
  | send (s p) (current : Current s p) (reserved : s.reserved p.message = true)
      (burned : s.unknown p.message = true)
      (nativeFresh : s.calls (p.message,p.offset) = 0) : Step owner budget s
      {s with calls := fun k => if k=(p.message,p.offset) then 1 else s.calls k}
  | retireZeroCall (s m) (nativeZeroCallAndPermitDestroyed : owner.zeroCallAndRetired s m) : Step owner budget s
      {s with unknown := fun x => if x=m then false else s.unknown x}
  | publish (s) : Step owner budget s {s with revision := s.revision+1, fence := s.fence+1}
  | custody (s) : Step owner budget s {s with generation := s.generation+1}
  | crashOrReplyLoss (s) : Step owner budget s s

theorem safe_step {M : Type} [DecidableEq M] {s t : State M} {owner : ExecutorEvidence M} (h : Safe budget s) (step : Step owner budget s t) : Safe budget t := by
  rcases h with ⟨capacity,calls,unknown⟩
  cases step with
  | reserve m cost positive fresh bound =>
      refine ⟨bound,calls,?_⟩
      intro x hx; by_cases same : x=m
      · simp [same]
      · simpa [same] using unknown x hx
  | burn m reserved =>
      refine ⟨capacity,calls,?_⟩
      intro x hx; by_cases same : x=m
      · simpa [same] using reserved
      · exact unknown x (by simpa [same] using hx)
  | send p current reserved burned fresh =>
      refine ⟨capacity,?_,unknown⟩
      intro key; by_cases same : key=(p.message,p.offset)
      · simp [same]
      · simpa [same] using calls key
  | retireZeroCall m evidence =>
      refine ⟨capacity,calls,?_⟩
      intro x hx; by_cases same : x=m
      · simp [same] at hx
      · exact unknown x (by simpa [same] using hx)
  | publish => exact ⟨capacity,calls,unknown⟩
  | custody => exact ⟨capacity,calls,unknown⟩
  | crashOrReplyLoss => exact ⟨capacity,calls,unknown⟩

inductive Run {M : Type} [DecidableEq M] (owner : ExecutorEvidence M) (budget : Nat) : State M → State M → Prop where
  | refl (s) : Run owner budget s s
  | next : Run owner budget a b → Step owner budget b c → Run owner budget a c

theorem safe_run {M : Type} [DecidableEq M] {s t : State M} {owner : ExecutorEvidence M} (initial : Safe budget s) (run : Run owner budget s t) : Safe budget t := by
  induction run with
  | refl => exact initial
  | next history step ih => exact safe_step ih step

theorem arbitrary_finite_messages_and_ranges (n : Nat) (budget : Nat) (owner : ExecutorEvidence (Fin n)) (t : State (Fin n))
    (run : Run (M := Fin n) owner budget ({} : State (Fin n)) t) :
    t.held ≤ budget ∧ ∀ key, t.calls key ≤ 1 := by
  have safe : Safe budget ({} : State (Fin n)) := ⟨Nat.zero_le _,by simp,by simp⟩
  exact ⟨(safe_run safe run).1,(safe_run safe run).2.1⟩

theorem unknown_cannot_resume (s : State M) (m : M) (unknown : s.unknown m = true) :
    ¬ Resumable s m := by simp [Resumable,unknown]

theorem old_generation_cannot_pass (s : State M) (p : Permit M)
    (old : p.generation < s.generation) : ¬ Current s p := by
  intro current; exact (Nat.ne_of_lt old) current.2.2

theorem held_never_decreases {M : Type} [DecidableEq M] {s t : State M} {owner : ExecutorEvidence M} (step : Step owner budget s t) : s.held ≤ t.held := by
  cases step <;> simp [Nat.le_add_right]

theorem bounded_range_copy_work (rangeCount maximumRange : Nat)
    (lengths : List Nat) (count : lengths.length ≤ rangeCount)
    (bounded : ∀ n ∈ lengths, n ≤ maximumRange) : lengths.sum ≤ lengths.length * maximumRange := by
  induction lengths with
  | nil => simp
  | cons head tail ih =>
      have hhead := bounded head (by simp)
      have htail : ∀ n ∈ tail, n ≤ maximumRange := by intro n hn; exact bounded n (by simp [hn])
      have sumTail := ih (by simp_all; omega) htail
      simp only [List.sum_cons,List.length_cons,Nat.add_mul,Nat.one_mul]
      omega

#print axioms safe_step
#print axioms safe_run
#print axioms arbitrary_finite_messages_and_ranges
#print axioms unknown_cannot_resume
#print axioms old_generation_cannot_pass
#print axioms held_never_decreases
#print axioms bounded_range_copy_work

/- Lifecycle composition is conditional on faithful task registration: neither
   dropping an HTTP future nor cancellation removes a still-running native writer.
   Drain is the acknowledgment boundary, not an instantaneous network revocation. -/
namespace Lifecycle

def Tracked (running registered : Worker → Bool) : Prop :=
  ∀ w, running w = true → registered w = true

def Drained (registered : Worker → Bool) : Prop := ∀ w, registered w = false

theorem drain_has_no_live_writer {running registered : Worker → Bool}
    (tracking : Tracked running registered) (drained : Drained registered) :
    ∀ w, running w = false := by
  intro w
  cases hw : running w with
  | false => rfl
  | true => have present := tracking w hw; rw [drained w] at present; contradiction

theorem disconnect_keeps_tracking {running registered : Worker → Bool}
    (tracking : Tracked running registered) : Tracked running registered := tracking

def CanAdmit (closing : Bool) : Prop := closing = false

theorem shutdown_blocks_admission : ¬ CanAdmit true := by simp [CanAdmit]

theorem execution_and_drain_composition {M Worker : Type} [DecidableEq M]
    {owner : ExecutorEvidence M} {s t : State M} {running registered : Worker → Bool}
    (initial : Safe budget s) (history : Run owner budget s t)
    (tracking : Tracked running registered) (drained : Drained registered) :
    Safe budget t ∧ ∀ w, running w = false :=
  ⟨safe_run initial history, drain_has_no_live_writer tracking drained⟩

#print axioms drain_has_no_live_writer
#print axioms disconnect_keeps_tracking
#print axioms shutdown_blocks_admission
#print axioms execution_and_drain_composition
end Lifecycle
/- Refinement of the final durable receipt join. The database transaction must
   read these fields faithfully and hold the writer lock through the callback.
   This premise excludes coherent rollback and hostile storage forgery. -/
namespace RangeReceipt

structure Identity where
  sequence : Nat
  offset : Nat
  length : Nat
  deriving DecidableEq

structure Record where
  identity : Identity
  unknown : Bool
  written : Option Nat
  cursor : Nat
  nextSequence : Nat

def Exact (r : Record) (p : Identity) : Prop :=
  r.identity = p ∧ r.unknown = true ∧ r.written = none ∧
  r.cursor = p.offset ∧ r.nextSequence = p.sequence + 1

def GuardedStep {M : Type} [DecidableEq M] (owner : ExecutorEvidence M)
    (budget : Nat) (s t : State M) (r : Record) (p : Identity) : Prop :=
  Exact r p ∧ Step owner budget s t

theorem mismatched_record_denies {r : Record} {p : Identity}
    (mismatch : r.identity ≠ p ∨ r.unknown ≠ true ∨ r.written ≠ none ∨
      r.cursor ≠ p.offset ∨ r.nextSequence ≠ p.sequence + 1) : ¬ Exact r p := by
  intro h
  rcases h with ⟨identity, unknown, written, cursor, successor⟩
  rcases mismatch with h | h | h | h | h
  · exact h identity
  · exact h unknown
  · exact h written
  · exact h cursor
  · exact h successor

theorem inexact_cannot_refine_execution {M : Type} [DecidableEq M]
    {owner : ExecutorEvidence M} {s t : State M} {r : Record} {p : Identity}
    (inexact : ¬ Exact r p) : ¬ GuardedStep owner budget s t r p := by
  intro step
  exact inexact step.1

theorem guarded_step_preserves_safety {M : Type} [DecidableEq M]
    {owner : ExecutorEvidence M} {s t : State M} {r : Record} {p : Identity}
    (safe : Safe budget s) (step : GuardedStep owner budget s t r p) : Safe budget t :=
  safe_step safe step.2

#print axioms mismatched_record_denies
#print axioms inexact_cannot_refine_execution
#print axioms guarded_step_preserves_safety
end RangeReceipt
end Weaver.StreamingExecution
