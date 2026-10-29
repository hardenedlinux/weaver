import LlmIncarnationIssuance
namespace Weaver.LlmBootstrapInvitation
open LlmIncarnationIssuance (Ticket Bootstrap)
structure Invitation where
  id : Nat
  ticket : Ticket
structure State where
  inner : LlmIncarnationIssuance.State
  invitations : Nat → Option Invitation
  launches : Nat → Option Nat
  consumed : Nat → Option Ticket
  revision : Nat
  seen : Option Nat
structure Owner where
  -- Authenticated producer assignment, not a caller-selected key or Kubernetes identity.
  register : Invitation → Prop
  verify : Invitation → Bootstrap → Prop
  durable : State → State → Prop
  readCurrent : State → Prop
  recover : Bootstrap → Invitation → Prop

def Credential (o : Owner) (i : Invitation) (b : Bootstrap) : Prop :=
  o.verify i b ∧ b.key = i.ticket.target.key ∧ b.session = i.ticket.session ∧ b.workload = i.ticket.target.workload

def Ready (o : Owner) (s : State) (i : Invitation) (b : Bootstrap) : Prop :=
  s.invitations i.id = some i ∧ s.launches i.ticket.launch = some i.id ∧
  s.consumed i.id = none ∧ s.seen = some s.revision ∧ Credential o i b

-- Instantiate edge with the actual predecessor Step, not a second enrollment service.
inductive Step (edge : LlmIncarnationIssuance.State → LlmIncarnationIssuance.State → Prop)
    (o : Owner) : State → State → Prop where
  | register (s i) (authentic : o.register i) (fresh : s.invitations i.id = none)
      (canonical : s.launches i.ticket.launch = none)
      (durable : o.durable s {s with invitations := fun k => if k = i.id then some i else s.invitations k, launches := fun k => if k = i.ticket.launch then some i.id else s.launches k, revision := s.revision+1, seen := none}) :
      Step edge o s {s with invitations := fun k => if k = i.id then some i else s.invitations k, launches := fun k => if k = i.ticket.launch then some i.id else s.launches k, revision := s.revision+1, seen := none}
  | consume (s next i b) (ready : Ready o s i b)
      (fresh : s.inner.issued i.ticket.id = none)
      (actual : edge s.inner next)
      (issued : next.issued = fun k => if k = i.ticket.id then some i.ticket else s.inner.issued k)
      (pendingOnly : next.current = s.inner.current)
      (durable : o.durable s {s with inner := next, consumed := fun k => if k = i.id then some i.ticket else s.consumed k, revision := s.revision+1, seen := none}) :
      Step edge o s {s with inner := next, consumed := fun k => if k = i.id then some i.ticket else s.consumed k, revision := s.revision+1, seen := none}
  | advance (s next) (actual : edge s.inner next) (noIssue : next.issued = s.inner.issued)
      (durable : o.durable s {s with inner := next, revision := s.revision+1, seen := none}) :
      Step edge o s {s with inner := next, revision := s.revision+1, seen := none}
  | observe (s) (authentic : o.readCurrent s) : Step edge o s {s with seen := some s.revision}
  | restart (s) : Step edge o s {s with seen := none}
  | recover (s i b ticket) (registered : s.invitations i.id = some i)
      (known : s.consumed i.id = some ticket) (exact : ticket = i.ticket)
      (allowed : o.recover b i) : Step edge o s s

inductive Run (edge : LlmIncarnationIssuance.State → LlmIncarnationIssuance.State → Prop)
    (o : Owner) : State → State → Prop where
  | refl (s) : Run edge o s s
  | next : Run edge o a b → Step edge o b c → Run edge o a c

theorem invitation_retained (e : Step edge o s t) (known : s.invitations k = some i) : t.invitations k = some i := by
  cases e <;> simp_all <;> intro eq <;> simp_all

theorem launch_retained (e : Step edge o s t) (known : s.launches k = some ident) : t.launches k = some ident := by
  cases e <;> simp_all <;> intro eq <;> simp_all

theorem consumed_retained (e : Step edge o s t) (known : s.consumed k = some ticket) : t.consumed k = some ticket := by
  cases e <;> simp_all [Ready] <;> intro eq <;> simp_all

theorem consumed_run (r : Run edge o s t) (known : s.consumed k = some ticket) : t.consumed k = some ticket := by
  induction r with
  | refl => exact known
  | next r e ih => exact consumed_retained e ih

theorem no_second_consume (known : s.consumed i.id = some ticket) : ¬ Ready o s i b := by
  intro h
  have no := h.2.2.1
  rw [known] at no
  cases no

theorem forwarded_bearer_wrong_key (different : b.key ≠ i.ticket.target.key) : ¬ Credential o i b := by
  intro h
  exact different h.2.1

theorem wrong_session (different : b.session ≠ i.ticket.session) : ¬ Credential o i b := by
  intro h
  exact different h.2.2.1

theorem stale_read (different : s.seen ≠ some s.revision) : ¬ Ready o s i b := by
  intro h
  exact different h.2.2.2.1

def Covered (s : State) : Prop := ∀ k ticket, s.inner.issued k = some ticket →
  ∃ ident, s.consumed ident = some ticket

theorem covered_step (e : Step edge o s t) (cover : Covered s) : Covered t := by
  intro k ticket known
  cases e with
  | consume next i b ready fresh actual issued pendingOnly durable =>
    change next.issued k = some ticket at known
    rw [issued] at known
    by_cases eq : k = i.ticket.id
    · have same : i.ticket = ticket := by simpa [eq] using known
      subst ticket
      exact ⟨i.id, by simp⟩
    · obtain ⟨ident, old⟩ := cover k ticket (by simpa [eq] using known)
      have notSame : ident ≠ i.id := by
        intro same
        subst ident
        have no := ready.2.2.1
        rw [old] at no
        cases no
      exact ⟨ident, by simpa [notSame] using old⟩
  | advance next actual noIssue durable => exact cover k ticket (by simpa [noIssue] using known)
  | _ => exact cover k ticket known

theorem covered_run (r : Run edge o s t) (initial : Covered s) : Covered t := by
  induction r with
  | refl => exact initial
  | next r e ih => exact covered_step e ih

theorem registration_origin (r : Run edge o s t) (empty : ∀ k, s.invitations k = none)
    (known : t.invitations k = some i) : o.register i := by
  induction r with
  | refl => rw [empty] at known; cases known
  | next r e ih =>
    cases e with
    | register new authentic fresh canonical durable =>
      by_cases eq : k = new.id
      · have same : new = i := by simpa [eq] using known
        simpa [← same] using authentic
      · exact ih (by simpa [eq] using known)
    | _ => exact ih known

def SpentBound (s : State) : Prop := ∀ k ticket, s.consumed k = some ticket →
  ∃ i, s.invitations k = some i ∧ ticket = i.ticket

theorem spent_bound_step (e : Step edge o s t) (bound : SpentBound s) : SpentBound t := by
  intro k ticket known
  cases e with
  | consume next i b ready fresh actual issued pendingOnly durable =>
    by_cases eq : k = i.id
    · have same : i.ticket = ticket := by simpa [eq] using known
      exact ⟨i, by simpa [eq] using ready.1, same.symm⟩
    · exact bound k ticket (by simpa [eq] using known)
  | register i authentic fresh canonical durable =>
    obtain ⟨old, row, exact⟩ := bound k ticket known
    have different : k ≠ i.id := by
      intro eq
      subst k
      rw [fresh] at row
      cases row
    exact ⟨old, by simpa [different] using row, exact⟩
  | _ => exact bound k ticket known

theorem spent_bound_run (r : Run edge o s t) (initial : SpentBound s) : SpentBound t := by
  induction r with
  | refl => exact initial
  | next r e ih => exact spent_bound_step e ih

theorem issued_from_registered_assignment (r : Run edge o s t)
    (empty : ∀ k, s.invitations k = none) (cover : Covered s) (bound : SpentBound s)
    (known : t.inner.issued k = some ticket) :
    ∃ ident i, o.register i ∧ ticket = i.ticket ∧ t.consumed ident = some ticket := by
  obtain ⟨ident, spent⟩ := covered_run r cover k ticket known
  obtain ⟨i, row, exact⟩ := spent_bound_run r bound ident ticket spent
  exact ⟨ident, i, registration_origin r empty row, exact, spent⟩

theorem original_result_unique (r : Run edge o s t) (old : s.consumed k = some a)
    (new : t.consumed k = some b) : a = b := by
  have retained := consumed_run r old
  rw [retained] at new
  exact Option.some.inj new

theorem issuance_extend (r : LlmIncarnationIssuance.Run ao wo co ho fo jo semantic po io genesis a b)
    (prior : LlmIncarnationIssuance.Run ao wo co ho fo jo semantic po io genesis x a) :
    LlmIncarnationIssuance.Run ao wo co ho fo jo semantic po io genesis x b := by
  induction r with
  | refl => exact prior
  | next r e ih => exact .next ih e

-- Arbitrary finite runs compose with the actual predecessor; no native persistence is inferred.
theorem composition (r : Run edge o s t)
    (actual : ∀ a b, edge a b → LlmIncarnationIssuance.Run ao wo co ho fo jo semantic po io genesis a b)
    (prior : LlmIncarnationIssuance.Run ao wo co ho fo jo semantic po io genesis x s.inner) :
    LlmIncarnationIssuance.Run ao wo co ho fo jo semantic po io genesis x t.inner := by
  induction r with
  | refl => exact prior
  | next r e ih =>
    cases e with
    | consume next i b ready fresh event issued pendingOnly durable => exact issuance_extend (actual _ _ event) ih
    | advance next event noIssue durable => exact issuance_extend (actual _ _ event) ih
    | _ => exact ih

theorem original_reservation_once (safe : LlmAppendHandoff.Safe ho h)
    (run : Run edge owner start s)
    (actual : ∀ a b, edge a b → LlmIncarnationIssuance.Run ao wo co ho fo jo semantic po o genesis a b)
    (priorCaller : LlmCallerCustody.Run ao wo co ho fo jo semantic po (LlmIncarnationIssuance.logicalOwner o.base) genesis callerStart start.inner.current)
    (priorPublication : LlmCustodyPublication.Run ao wo co ho fo jo semantic po genesis (LlmCustodyPublication.initial custodyStart) callerStart.logical)
    (priorCustody : LlmSourceCustody.Run ao wo co ho fo jo (LlmCustodyPublication.logicalOwner semantic) genesis (LlmSourceCustody.initial (LlmSourceJoin.initial (LlmAdmissionFloor.initial h))) custodyStart)
    (priorAccount : LlmCheckpointTruncation.Run ao wo co genesis (LlmCheckpointTruncation.initial ao balances) h.logical) (key) :
    (LlmSourceJoin.account s.inner.current.logical.authority.logical).authority.writes key ≤ 1 :=
  LlmIncarnationIssuance.original_reservation_once safe (composition run actual (.refl _)) priorCaller priorPublication priorCustody priorAccount key

theorem unknown_original_hold_retained (safe : LlmAppendHandoff.Safe ho h)
    (run : Run edge owner start s)
    (actual : ∀ a b, edge a b → LlmIncarnationIssuance.Run ao wo co ho fo jo semantic po o genesis a b)
    (priorCaller : LlmCallerCustody.Run ao wo co ho fo jo semantic po (LlmIncarnationIssuance.logicalOwner o.base) genesis callerStart start.inner.current)
    (priorPublication : LlmCustodyPublication.Run ao wo co ho fo jo semantic po genesis (LlmCustodyPublication.initial custodyStart) callerStart.logical)
    (priorCustody : LlmSourceCustody.Run ao wo co ho fo jo (LlmCustodyPublication.logicalOwner semantic) genesis (LlmSourceCustody.initial (LlmSourceJoin.initial (LlmAdmissionFloor.initial h))) custodyStart)
    (priorAccount : LlmCheckpointTruncation.Run ao wo co genesis (LlmCheckpointTruncation.initial ao balances) h.logical)
    (source : LlmExecutionReconciliation.State S) (unknownUsage : source.metered = false)
    (binding : ∀ tx state, tx.reservation = originalKey → ao.sourceReady tx state → LlmAccountCommit.OriginalReady originalKey attempt source tx) :
    (LlmSourceJoin.account s.inner.current.logical.authority.logical).authority.reservations originalKey = none ∧
    (LlmSourceJoin.account s.inner.current.logical.authority.logical).authority.holds originalKey = ao.bound originalKey :=
  LlmIncarnationIssuance.unknown_original_hold_retained safe (composition run actual (.refl _)) priorCaller priorPublication priorCustody priorAccount source unknownUsage binding

#print axioms invitation_retained
#print axioms launch_retained
#print axioms consumed_retained
#print axioms consumed_run
#print axioms no_second_consume
#print axioms forwarded_bearer_wrong_key
#print axioms wrong_session
#print axioms stale_read
#print axioms covered_step
#print axioms covered_run
#print axioms registration_origin
#print axioms original_result_unique
#print axioms composition
#print axioms spent_bound_step
#print axioms spent_bound_run
#print axioms issued_from_registered_assignment
#print axioms original_reservation_once
#print axioms unknown_original_hold_retained
end Weaver.LlmBootstrapInvitation
