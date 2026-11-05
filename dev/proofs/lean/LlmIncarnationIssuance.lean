-- SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
--
-- SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

import LlmCallerCustody
namespace Weaver.LlmIncarnationIssuance

-- Enrollment is expanded here; the predecessor remains the logical custody machine.
def logicalOwner (o : LlmCallerCustody.Owner) : LlmCallerCustody.Owner :=
  {o with enrolled := fun _ _ _ => True}
structure Ticket where
  id : Nat
  launch : Nat
  parent : Nat
  epoch : Nat
  challenge : Nat
  session : Nat
  audience : Nat
  purpose : Nat
  previous : LlmCallerCustody.Capability
  target : LlmCallerCustody.Capability
structure Bootstrap where
  workload : Nat
  key : Nat
  session : Nat
structure Receipt where
  ticket : Ticket
  peer : Bootstrap
structure State where
  current : LlmCallerCustody.State
  issued : Nat → Option Ticket
  launches : Nat → Option Nat
  proofs : Nat → Option Receipt
  outcomes : Nat → Option LlmCallerCustody.Capability
  reserved : List Nat
  challenge : Nat
  epoch : Nat
  revision : Nat
  seen : Option Nat
structure Owner where
  base : LlmCallerCustody.Owner
  -- Independent launch authorization freezes the beneficiary key, original scope and operation.
  launchAuthorized : LlmCallerCustody.Context → LlmCallerCustody.State → Ticket → Prop
  -- Native verification covers exact transcript, audience, purpose, key and channel binding.
  verify : Ticket → Bootstrap → Prop
  durable : State → State → Prop
  readCurrent : State → Prop
  canReadTicket : LlmCallerCustody.Context → State → Ticket → Prop

def Current (s : State) (t : Ticket) : Prop :=
  s.issued t.id = some t ∧ t.previous = s.current.grant ∧
  t.parent = s.current.logical.journal.length ∧ t.epoch = s.epoch ∧
  t.audience = t.target.domain ∧ t.purpose = 1 ∧ s.current.now < t.target.expires

def Possession (o : Owner) (t : Ticket) (c : Bootstrap) : Prop :=
  o.verify t c ∧ c.workload = t.target.workload ∧ c.key = t.target.key ∧ c.session = t.session

def CanActivate (o : Owner) (s : State) (t : Ticket) (c : Bootstrap) : Prop :=
  Current s t ∧ Possession o t c ∧ s.proofs t.id = some ⟨t,c⟩ ∧
  s.outcomes t.id = none ∧ s.seen = some s.revision

inductive Step (ao : LlmAccountCommit.Owner) (wo : LlmWalActivation.Owner)
    (co : LlmCheckpointTruncation.Owner) (ho : LlmAppendHandoff.Owner)
    (fo : LlmAdmissionFloor.Owner) (jo : LlmSourceJoin.Owner)
    (semantic : LlmAdmissionFloor.Proposal → LlmAdmissionFloor.Proposal → Prop)
    (po : LlmCustodyPublication.Owner) (o : Owner) (genesis : LlmAccountCommit.Image) : State → State → Prop where
  | issue (s t issuer) (authentic : o.base.authentic issuer) (role : issuer.recovery = true)
      (allowed : o.launchAuthorized issuer s.current t)
      (fresh : s.issued t.id = none) (launchFresh : s.launches t.launch = none)
      (incFresh : t.target.incarnation ∉ s.reserved) (unused : t.target.incarnation ∉ s.current.used)
      (parent : t.parent = s.current.logical.journal.length) (previous : t.previous = s.current.grant)
      (scope : LlmCallerCustody.Scope s.current.grant t.target)
      (serial : t.target.serial = s.current.grant.serial + 1)
      (fence : t.target.fence = s.current.grant.fence + 1)
      (challenge : t.challenge = s.challenge) (epoch : t.epoch = s.epoch)
      (audience : t.audience = t.target.domain) (purpose : t.purpose = 1)
      (valid : s.current.now < t.target.expires) (durable : o.durable s {s with issued := (fun key => if key = t.id then some t else s.issued key), launches := (fun launch => if launch = t.launch then some t.id else s.launches launch), reserved := s.reserved ++ [t.target.incarnation], challenge := s.challenge+1, revision := s.revision+1, seen := none}) :
      Step ao wo co ho fo jo semantic po o genesis s {s with issued := (fun key => if key = t.id then some t else s.issued key), launches := (fun launch => if launch = t.launch then some t.id else s.launches launch), reserved := s.reserved ++ [t.target.incarnation], challenge := s.challenge+1, revision := s.revision+1, seen := none}
  | prove (s t c) (current : Current s t) (possession : Possession o t c)
      (fresh : s.proofs t.id = none) (durable : o.durable s {s with proofs := (fun key => if key = t.id then some ⟨t,c⟩ else s.proofs key), revision := s.revision+1, seen := none}) :
      Step ao wo co ho fo jo semantic po o genesis s {s with proofs := (fun key => if key = t.id then some ⟨t,c⟩ else s.proofs key), revision := s.revision+1, seen := none}
  | activate (s next t c) (ready : CanActivate o s t c)
      (actual : LlmCallerCustody.Step ao wo co ho fo jo semantic po (logicalOwner o.base) genesis s.current next)
      (target : next.grant = t.target)
      (changed : next.grant.incarnation ≠ s.current.grant.incarnation)
      (durable : o.durable s {s with current := next, outcomes := (fun key => if key = t.id then some t.target else s.outcomes key), revision := s.revision+1, seen := none}) :
      Step ao wo co ho fo jo semantic po o genesis s {s with current := next, outcomes := (fun key => if key = t.id then some t.target else s.outcomes key), revision := s.revision+1, seen := none}
  | advance (s next) (actual : LlmCallerCustody.Step ao wo co ho fo jo semantic po (logicalOwner o.base) genesis s.current next)
      (sameGrant : next.grant = s.current.grant) (durable : o.durable s {s with current := next, revision := s.revision+1, seen := none}) :
      Step ao wo co ho fo jo semantic po o genesis s {s with current := next, revision := s.revision+1, seen := none}
  | revoke (s) (durable : o.durable s {s with epoch := s.epoch+1, revision := s.revision+1, seen := none}) :
      Step ao wo co ho fo jo semantic po o genesis s {s with epoch := s.epoch+1, revision := s.revision+1, seen := none}
  | observe (s) (authentic : o.readCurrent s) :
      Step ao wo co ho fo jo semantic po o genesis s {s with seen := some s.revision}
  | restart (s) : Step ao wo co ho fo jo semantic po o genesis s {s with seen := none}
  | redeliver (s t c) (issued : s.issued t.id = some t) (possession : Possession o t c) :
      Step ao wo co ho fo jo semantic po o genesis s s
  | lookup (s ticket issuer) (mapped : s.launches ticket.launch = some ticket.id)
      (issued : s.issued ticket.id = some ticket) (authentic : o.base.authentic issuer)
      (role : issuer.recovery = true) (allowed : o.canReadTicket issuer s ticket) :
      Step ao wo co ho fo jo semantic po o genesis s s

inductive Run (ao : LlmAccountCommit.Owner) (wo : LlmWalActivation.Owner)
    (co : LlmCheckpointTruncation.Owner) (ho : LlmAppendHandoff.Owner)
    (fo : LlmAdmissionFloor.Owner) (jo : LlmSourceJoin.Owner)
    (semantic : LlmAdmissionFloor.Proposal → LlmAdmissionFloor.Proposal → Prop)
    (po : LlmCustodyPublication.Owner) (o : Owner) (genesis : LlmAccountCommit.Image) : State → State → Prop where
  | refl (s) : Run ao wo co ho fo jo semantic po o genesis s s
  | next : Run ao wo co ho fo jo semantic po o genesis a b → Step ao wo co ho fo jo semantic po o genesis b d → Run ao wo co ho fo jo semantic po o genesis a d

theorem projection (event : Step ao wo co ho fo jo semantic po o genesis s t) :
    LlmCallerCustody.Run ao wo co ho fo jo semantic po (logicalOwner o.base) genesis s.current t.current := by
  cases event with
  | activate next ticket c ready actual target changed durable => exact .next (.refl _) actual
  | advance next actual same durable => exact .next (.refl _) actual
  | _ => exact .refl _

theorem caller_extend (r : LlmCallerCustody.Run ao wo co ho fo jo semantic po owner genesis a b)
    (prior : LlmCallerCustody.Run ao wo co ho fo jo semantic po owner genesis x a) :
    LlmCallerCustody.Run ao wo co ho fo jo semantic po owner genesis x b := by
  induction r with
  | refl => exact prior
  | next r e ih => exact .next ih e

theorem composition (run : Run ao wo co ho fo jo semantic po o genesis s t)
    (prior : LlmCallerCustody.Run ao wo co ho fo jo semantic po (logicalOwner o.base) genesis x s.current) :
    LlmCallerCustody.Run ao wo co ho fo jo semantic po (logicalOwner o.base) genesis x t.current := by
  induction run with
  | refl => exact prior
  | next r e ih => exact caller_extend (projection e) ih

theorem issued_retained (event : Step ao wo co ho fo jo semantic po o genesis s t) (known : s.issued key = some ticket) : t.issued key = some ticket := by
  cases event <;> simp_all <;> intro eq <;> simp_all

def IssueEvidence (o : Owner) (ticket : Ticket) : Prop :=
  ∃ current issuer, o.base.authentic issuer ∧ issuer.recovery = true ∧ o.launchAuthorized issuer current ticket

theorem issue_origin_step (event : Step ao wo co ho fo jo semantic po o genesis s t)
    (known : t.issued key = some ticket) : s.issued key = some ticket ∨ IssueEvidence o ticket := by
  cases event with
  | issue new issuer authentic role allowed fresh launchFresh incFresh unused parent previous scope serial fence challenge epoch audience purpose valid durable =>
    by_cases eq : key = new.id
    · subst key
      have same : new = ticket := by simpa using known
      subst ticket
      exact .inr ⟨s.current,issuer,authentic,role,allowed⟩
    · exact .inl (by simpa [eq] using known)
  | _ => exact .inl known

theorem issued_was_authorized (run : Run ao wo co ho fo jo semantic po o genesis s t)
    (empty : ∀ key, s.issued key = none) : t.issued key = some ticket → IssueEvidence o ticket := by
  induction run with
  | refl => intro known; have no := empty key; rw [no] at known; cases known
  | next r e ih =>
    intro known
    rcases issue_origin_step e known with old | evidence
    · exact ih old
    · exact evidence

theorem launch_retained (event : Step ao wo co ho fo jo semantic po o genesis s t) (known : s.launches launch = some key) : t.launches launch = some key := by
  cases event <;> simp_all <;> intro eq <;> simp_all

theorem outcome_retained (event : Step ao wo co ho fo jo semantic po o genesis s t) (known : s.outcomes key = some grant) : t.outcomes key = some grant := by
  cases event <;> simp_all [CanActivate] <;> intro eq <;> simp_all

theorem issued_run (run : Run ao wo co ho fo jo semantic po o genesis s t) (known : s.issued key = some ticket) : t.issued key = some ticket := by
  induction run with
  | refl => exact known
  | next r e ih => exact issued_retained e ih

theorem outcome_run (run : Run ao wo co ho fo jo semantic po o genesis s t) (known : s.outcomes key = some grant) : t.outcomes key = some grant := by
  induction run with
  | refl => exact known
  | next r e ih => exact outcome_retained e ih

theorem reserved_retained (event : Step ao wo co ho fo jo semantic po o genesis s t) (known : inc ∈ s.reserved) : inc ∈ t.reserved := by
  cases event <;> simp_all <;> intro eq <;> simp_all

theorem launch_run (run : Run ao wo co ho fo jo semantic po o genesis s t) (known : s.launches launch = some key) : t.launches launch = some key := by
  induction run with
  | refl => exact known
  | next r e ih => exact launch_retained e ih

theorem reserved_run (run : Run ao wo co ho fo jo semantic po o genesis s t) (known : inc ∈ s.reserved) : inc ∈ t.reserved := by
  induction run with
  | refl => exact known
  | next r e ih => exact reserved_retained e ih

theorem challenge_monotone (event : Step ao wo co ho fo jo semantic po o genesis s t) : s.challenge ≤ t.challenge := by
  cases event <;> simp <;> omega

theorem wrong_key_not_possession (wrong : c.key ≠ ticket.target.key) : ¬ Possession o ticket c := by
  intro h
  exact wrong h.2.2.1

theorem wrong_session_not_possession (wrong : c.session ≠ ticket.session) : ¬ Possession o ticket c := by
  intro h
  exact wrong h.2.2.2

theorem stale_epoch_rejected (wrong : ticket.epoch ≠ s.epoch) : ¬ CanActivate o s ticket c := by
  intro h
  exact wrong h.1.2.2.2.1

theorem stale_parent_rejected (wrong : ticket.parent ≠ s.current.logical.journal.length) : ¬ CanActivate o s ticket c := by
  intro h
  exact wrong h.1.2.2.1

theorem known_outcome_cannot_activate (known : s.outcomes ticket.id = some grant) : ¬ CanActivate o s ticket c := by
  intro h
  have eq := h.2.2.2.1
  rw [known] at eq
  cases eq

theorem activation_requires_issued_proof (event : Step ao wo co ho fo jo semantic po o genesis s t)
    (changed : t.current.grant.incarnation ≠ s.current.grant.incarnation) :
    ∃ ticket c, CanActivate o s ticket c ∧ t.current.grant = ticket.target ∧
      t.outcomes ticket.id = some ticket.target := by
  cases event with
  | activate next ticket c ready actual target different durable => exact ⟨ticket,c,ready,target,by simp⟩
  | advance next actual same durable => exact False.elim (changed (congrArg LlmCallerCustody.Capability.incarnation same))
  | _ => exact False.elim (changed rfl)

theorem activation_from_authorized_launch
    (prior : Run ao wo co ho fo jo semantic po o genesis start s)
    (empty : ∀ key, start.issued key = none)
    (event : Step ao wo co ho fo jo semantic po o genesis s t)
    (changed : t.current.grant.incarnation ≠ s.current.grant.incarnation) :
    ∃ ticket c, CanActivate o s ticket c ∧ IssueEvidence o ticket ∧ t.current.grant = ticket.target := by
  obtain ⟨ticket,c,ready,target,outcome⟩ := activation_requires_issued_proof event changed
  exact ⟨ticket,c,ready,issued_was_authorized prior empty ready.1.1,target⟩

theorem scope_run (run : Run ao wo co ho fo jo semantic po o genesis s t) : LlmCallerCustody.Scope s.current.grant t.current.grant :=
  LlmCallerCustody.scope_run (composition run (.refl _))

theorem original_result_unique (run : Run ao wo co ho fo jo semantic po o genesis start s)
    (priorCaller : LlmCallerCustody.Run ao wo co ho fo jo semantic po (logicalOwner o.base) genesis callerStart start.current)
    (priorPublication : LlmCustodyPublication.Run ao wo co ho fo jo semantic po genesis (LlmCustodyPublication.initial custodyStart) callerStart.logical)
    (priorCustody : LlmSourceCustody.Run ao wo co ho fo jo (LlmCustodyPublication.logicalOwner semantic) genesis (LlmSourceCustody.initial (LlmSourceJoin.initial (LlmAdmissionFloor.initial h))) custodyStart) :
    ∀ r ∈ s.current.logical.authority.logical.floorState.committed, ∀ other ∈ s.current.logical.authority.logical.floorState.committed, r.proposal.id = other.proposal.id → r = other :=
  LlmCallerCustody.original_result_unique (composition run priorCaller) priorPublication priorCustody

theorem original_reservation_once (safe : LlmAppendHandoff.Safe ho h)
    (run : Run ao wo co ho fo jo semantic po o genesis start s)
    (priorCaller : LlmCallerCustody.Run ao wo co ho fo jo semantic po (logicalOwner o.base) genesis callerStart start.current)
    (priorPublication : LlmCustodyPublication.Run ao wo co ho fo jo semantic po genesis (LlmCustodyPublication.initial custodyStart) callerStart.logical)
    (priorCustody : LlmSourceCustody.Run ao wo co ho fo jo (LlmCustodyPublication.logicalOwner semantic) genesis (LlmSourceCustody.initial (LlmSourceJoin.initial (LlmAdmissionFloor.initial h))) custodyStart)
    (priorAccount : LlmCheckpointTruncation.Run ao wo co genesis (LlmCheckpointTruncation.initial ao balances) h.logical) (key) :
    (LlmSourceJoin.account s.current.logical.authority.logical).authority.writes key ≤ 1 :=
  LlmCallerCustody.original_reservation_once safe (composition run priorCaller) priorPublication priorCustody priorAccount key

theorem unknown_original_hold_retained (safe : LlmAppendHandoff.Safe ho h)
    (run : Run ao wo co ho fo jo semantic po o genesis start s)
    (priorCaller : LlmCallerCustody.Run ao wo co ho fo jo semantic po (logicalOwner o.base) genesis callerStart start.current)
    (priorPublication : LlmCustodyPublication.Run ao wo co ho fo jo semantic po genesis (LlmCustodyPublication.initial custodyStart) callerStart.logical)
    (priorCustody : LlmSourceCustody.Run ao wo co ho fo jo (LlmCustodyPublication.logicalOwner semantic) genesis (LlmSourceCustody.initial (LlmSourceJoin.initial (LlmAdmissionFloor.initial h))) custodyStart)
    (priorAccount : LlmCheckpointTruncation.Run ao wo co genesis (LlmCheckpointTruncation.initial ao balances) h.logical)
    (source : LlmExecutionReconciliation.State S) (unknownUsage : source.metered = false)
    (binding : ∀ tx state, tx.reservation = originalKey → ao.sourceReady tx state → LlmAccountCommit.OriginalReady originalKey attempt source tx) :
    (LlmSourceJoin.account s.current.logical.authority.logical).authority.reservations originalKey = none ∧
    (LlmSourceJoin.account s.current.logical.authority.logical).authority.holds originalKey = ao.bound originalKey :=
  LlmCallerCustody.unknown_original_hold_retained safe (composition run priorCaller) priorPublication priorCustody priorAccount source unknownUsage binding

#print axioms projection
#print axioms composition
#print axioms issued_retained
#print axioms issued_was_authorized
#print axioms launch_retained
#print axioms outcome_retained
#print axioms issued_run
#print axioms outcome_run
#print axioms reserved_retained
#print axioms launch_run
#print axioms reserved_run
#print axioms challenge_monotone
#print axioms wrong_key_not_possession
#print axioms wrong_session_not_possession
#print axioms stale_epoch_rejected
#print axioms stale_parent_rejected
#print axioms known_outcome_cannot_activate
#print axioms activation_requires_issued_proof
#print axioms activation_from_authorized_launch
#print axioms scope_run
#print axioms original_result_unique
#print axioms original_reservation_once
#print axioms unknown_original_hold_retained
end Weaver.LlmIncarnationIssuance
