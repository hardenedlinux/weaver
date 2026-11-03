-- SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
--
-- SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

import LlmBeneficiaryRegistration
namespace Weaver.LlmEnrollmentCredential
abbrev BState := LlmBeneficiaryRegistration.State
abbrev Root := LlmBeneficiaryRegistration.Root
structure Plan where
  root : Root
  subject : Nat
  subjectKey : Nat
  session : Nat
  challenge : Nat
  audience : Nat
  purpose : Nat
structure Peer where
  subject : Nat
  subjectKey : Nat
  enrollmentKey : Nat
  session : Nat
  challenge : Nat
  credentialId : Nat
structure Credential where
  plan : Plan
  id : Nat
  epoch : Nat
  peer : Peer
structure Holder where
  subject : Nat
  enrollmentKey : Nat
  session : Nat
structure State where
  inner : BState
  plans : Nat → Option Plan
  credentials : Nat → Option Credential
  ids : Nat → Option Nat
  requested : Nat → Option Credential
  released : Nat → Option Credential
  activated : Nat → Option Credential
  epoch : Nat
  nextId : Nat
  revision : Nat
  seen : Option Nat
structure Owner where
  -- Existing independent subject and producer-assigned launch, not a shared SA.
  planAuthorized : Plan → Prop
  verifyIssue : Credential → Prop
  verifyUse : Credential → Holder → Prop
  signature : Credential → Prop
  currentAllows : State → Credential → Prop
  durable : State → State → Prop
  readCurrent : State → Prop
  recover : Plan → Nat → Prop

def IssueBinding (o : Owner) (c : Credential) : Prop :=
  o.verifyIssue c ∧ c.peer.subject = c.plan.subject ∧
  c.peer.subjectKey = c.plan.subjectKey ∧
  c.peer.enrollmentKey = c.plan.root.enrollmentKey ∧
  c.peer.session = c.plan.session ∧ c.peer.challenge = c.plan.challenge ∧
  c.peer.credentialId = c.id

def UseBinding (o : Owner) (c : Credential) (p : Holder) : Prop :=
  o.verifyUse c p ∧ p.subject = c.plan.subject ∧
  p.enrollmentKey = c.plan.root.enrollmentKey ∧
  p.session = c.plan.root.template.ticket.session

def Valid (o : Owner) (s : State) : Prop := ∀ k c, s.credentials k = some c →
  s.plans k = some c.plan ∧ c.plan.root.template.ticket.launch = k ∧
  IssueBinding o c ∧ s.ids c.id = some k ∧ c.id < s.nextId

def Requested (s : State) : Prop := ∀ k c, s.requested k = some c → s.credentials k = some c
def Released (s : State) : Prop := ∀ k c, s.released k = some c →
  s.requested k = some c ∧ s.credentials k = some c
def Joined (s : State) : Prop := ∀ k r, s.inner.roots k = some r →
  ∃ c, s.activated k = some c ∧ s.released k = some c ∧
    s.credentials k = some c ∧ c.plan.root = r
def Outcome (s : State) : Prop := ∀ k c, s.activated k = some c →
  s.inner.roots k = some c.plan.root ∧ s.released k = some c ∧ s.credentials k = some c
def Qualified (o : Owner) (s : State) : Prop :=
  Valid o s ∧ Requested s ∧ Released s ∧ Joined s ∧ Outcome s

def Current (o : Owner) (s : State) (c : Credential) : Prop :=
  s.credentials c.plan.root.template.ticket.launch = some c ∧ c.epoch = s.epoch ∧
  c.plan.root.epoch = s.inner.epoch ∧
  LlmBeneficiaryRegistration.Blueprint s.inner c.plan.root.template ∧
  s.seen = some s.revision ∧ o.currentAllows s c ∧ Qualified o s

def put {α : Type} (m : Nat → Option α) (k : Nat) (v : α) := fun n => if n = k then some v else m n

inductive Step (edge : BState → BState → Prop) (o : Owner) : State → State → Prop where
  | plan (s p) (authorized : o.planAuthorized p)
      (fresh : s.plans p.root.template.ticket.launch = none)
      (epoch : p.root.epoch = s.inner.epoch)
      (canonical : LlmBeneficiaryRegistration.eraseKey p.root.template = p.root.template)
      (audience : p.audience = p.root.template.ticket.target.domain) (purpose : p.purpose = 2)
      (durable : o.durable s {s with plans := put s.plans p.root.template.ticket.launch p, revision := s.revision+1, seen := none}) :
      Step edge o s {s with plans := put s.plans p.root.template.ticket.launch p, revision := s.revision+1, seen := none}
  | issue (s c) (qualified : Qualified o s)
      (plan : s.plans c.plan.root.template.ticket.launch = some c.plan)
      (fresh : s.credentials c.plan.root.template.ticket.launch = none)
      (id : c.id = s.nextId) (unused : s.ids c.id = none) (epoch : c.epoch = s.epoch)
      (binding : IssueBinding o c)
      (current : c.plan.root.epoch = s.inner.epoch ∧ LlmBeneficiaryRegistration.Blueprint s.inner c.plan.root.template ∧ s.seen = some s.revision ∧ o.currentAllows s c)
      (durable : o.durable s {s with credentials := put s.credentials c.plan.root.template.ticket.launch c, ids := put s.ids c.id c.plan.root.template.ticket.launch, nextId := s.nextId+1, revision := s.revision+1, seen := none}) :
      Step edge o s {s with credentials := put s.credentials c.plan.root.template.ticket.launch c, ids := put s.ids c.id c.plan.root.template.ticket.launch, nextId := s.nextId+1, revision := s.revision+1, seen := none}
  | request (s c) (ready : Current o s c) (fresh : s.requested c.plan.root.template.ticket.launch = none)
      (durable : o.durable s {s with requested := put s.requested c.plan.root.template.ticket.launch c, revision := s.revision+1, seen := none}) :
      Step edge o s {s with requested := put s.requested c.plan.root.template.ticket.launch c, revision := s.revision+1, seen := none}
  | release (s c) (ready : Current o s c) (requested : s.requested c.plan.root.template.ticket.launch = some c)
      (signature : o.signature c) (fresh : s.released c.plan.root.template.ticket.launch = none)
      (durable : o.durable s {s with released := put s.released c.plan.root.template.ticket.launch c, revision := s.revision+1, seen := none}) :
      Step edge o s {s with released := put s.released c.plan.root.template.ticket.launch c, revision := s.revision+1, seen := none}
  | activate (s next c p) (ready : Current o s c) (released : s.released c.plan.root.template.ticket.launch = some c)
      (holder : UseBinding o c p) (fresh : s.inner.roots c.plan.root.template.ticket.launch = none)
      (actual : edge s.inner next)
      (root : next.roots = put s.inner.roots c.plan.root.template.ticket.launch c.plan.root)
      (pendingOnly : next = {s.inner with roots := put s.inner.roots c.plan.root.template.ticket.launch c.plan.root, revision := s.inner.revision+1, seen := none})
      (durable : o.durable s {s with inner := next, activated := put s.activated c.plan.root.template.ticket.launch c, revision := s.revision+1, seen := none}) :
      Step edge o s {s with inner := next, activated := put s.activated c.plan.root.template.ticket.launch c, revision := s.revision+1, seen := none}
  | advance (s next) (qualified : Qualified o s) (actual : edge s.inner next) (noRoot : next.roots = s.inner.roots)
      (durable : o.durable s {s with inner := next, revision := s.revision+1, seen := none}) :
      Step edge o s {s with inner := next, revision := s.revision+1, seen := none}
  | revoke (s next) (actual : edge s.inner next) (noRoot : next.roots = s.inner.roots)
      (fence : next.epoch = s.inner.epoch+1)
      (durable : o.durable s {s with inner := next, epoch := s.epoch+1, revision := s.revision+1, seen := none}) :
      Step edge o s {s with inner := next, epoch := s.epoch+1, revision := s.revision+1, seen := none}
  | observe (s) (authentic : o.readCurrent s) : Step edge o s {s with seen := some s.revision}
  | restart (s) : Step edge o s {s with seen := none}
  | recover (s k p reader) (known : s.plans k = some p) (allowed : o.recover p reader) : Step edge o s s
inductive Run (edge : BState → BState → Prop) (o : Owner) : State → State → Prop where
  | refl (s) : Run edge o s s
  | next : Run edge o a b → Step edge o b c → Run edge o a c

theorem plan_retained (e : Step edge o s t) (known : s.plans k = some p) : t.plans k = some p := by
  cases e <;> simp_all [put] <;> intro eq <;> simp_all

theorem credential_retained (e : Step edge o s t) (known : s.credentials k = some c) : t.credentials k = some c := by
  cases e <;> simp_all [put] <;> intro eq <;> simp_all

theorem id_retained (e : Step edge o s t) (known : s.ids n = some k) : t.ids n = some k := by
  cases e <;> simp_all [put] <;> intro eq <;> simp_all

theorem request_retained (e : Step edge o s t) (known : s.requested k = some c) : t.requested k = some c := by
  cases e <;> simp_all [put] <;> intro eq <;> simp_all

theorem release_retained (e : Step edge o s t) (known : s.released k = some c) : t.released k = some c := by
  cases e <;> simp_all [put] <;> intro eq <;> simp_all

theorem activation_retained (e : Step edge o s t) (valid : Outcome s) (known : s.activated k = some c) : t.activated k = some c := by
  cases e with
  | activate next new p ready released holder fresh actual root pendingOnly durable =>
    have old := (valid k c known).1
    have different : k ≠ new.plan.root.template.ticket.launch := by
      intro eq
      have no : s.inner.roots k = none := by simpa [eq] using fresh
      rw [old] at no
      cases no
    simpa [put,different] using known
  | _ => exact known

theorem credential_run (r : Run edge o s t) (known : s.credentials k = some c) : t.credentials k = some c := by
  induction r with
  | refl => exact known
  | next r e ih => exact credential_retained e ih

theorem no_subject_or_key_replacement (r : Run edge o s t) (old : s.credentials k = some c) (new : t.credentials k = some d) : c = d := by
  have h := credential_run r old
  rw [h] at new
  exact Option.some.inj new

theorem forwarded_subject_rejected (wrong : c.peer.subjectKey ≠ c.plan.subjectKey) : ¬ IssueBinding o c := by
  intro h; exact wrong h.2.2.1

theorem nominated_enrollment_key_rejected (wrong : c.peer.enrollmentKey ≠ c.plan.root.enrollmentKey) : ¬ IssueBinding o c := by
  intro h; exact wrong h.2.2.2.1

theorem issue_session_bound (wrong : c.peer.session ≠ c.plan.session) : ¬ IssueBinding o c := by
  intro h; exact wrong h.2.2.2.2.1

theorem holder_session_bound (wrong : p.session ≠ c.plan.root.template.ticket.session) : ¬ UseBinding o c p := by
  intro h; exact wrong h.2.2.2

theorem stale_issuer_rejected (wrong : c.epoch ≠ s.epoch) : ¬ Current o s c := by
  intro h; exact wrong h.2.1

theorem stale_read_rejected (wrong : s.seen ≠ some s.revision) : ¬ Current o s c := by
  intro h; exact wrong h.2.2.2.2.1

theorem valid_step (e : Step edge o s t) (valid : Valid o s) : Valid o t := by
  intro k c known
  have event := e
  cases e with
  | plan p authorized fresh epoch canonical audience purpose durable =>
    obtain ⟨plan,index,binding,id,lt⟩ := valid k c known
    have different : k ≠ p.root.template.ticket.launch := by
      intro eq
      have no : s.plans k = none := by simpa [eq] using fresh
      rw [plan] at no; cases no
    exact ⟨by simpa [put,different] using plan,index,binding,id,lt⟩
  | issue new qualified plan fresh id unused epoch binding current durable =>
    dsimp only at known ⊢
    by_cases eq : k = new.plan.root.template.ticket.launch
    · have same : new = c := by simpa [put,eq] using known
      subst c
      exact ⟨by simpa [eq] using plan,eq.symm,binding,by simp [put,eq],by omega⟩
    · obtain ⟨planOld,index,bound,owner,lt⟩ := valid k c (by simpa [put,eq] using known)
      have different : c.id ≠ new.id := by omega
      exact ⟨planOld,index,bound,by simpa [put,different] using owner,by omega⟩
  | _ => exact valid k c known

theorem valid_run (r : Run edge o s t) (valid : Valid o s) : Valid o t := by
  induction r with
  | refl => exact valid
  | next r e ih => exact valid_step e ih

theorem credential_id_unique (valid : Valid o s) (one : s.credentials k = some c) (two : s.credentials j = some d) (same : c.id = d.id) : k = j := by
  have a := (valid k c one).2.2.2.1
  have b := (valid j d two).2.2.2.1
  rw [same,b] at a
  exact (Option.some.inj a).symm

theorem requested_step (e : Step edge o s t) (valid : Requested s) : Requested t := by
  intro k c known
  have event := e
  cases e with
  | request new ready fresh durable =>
    by_cases eq : k = new.plan.root.template.ticket.launch
    · have same : new = c := by simpa [put,eq] using known
      subst c
      simpa [eq] using ready.1
    · exact valid k c (by simpa [put,eq] using known)
  | _ => exact credential_retained (by assumption) (valid k c known)

theorem released_step (e : Step edge o s t) (valid : Released s) : Released t := by
  intro k c known
  have event := e
  cases e with
  | release new ready requested signature fresh durable =>
    by_cases eq : k = new.plan.root.template.ticket.launch
    · have same : new = c := by simpa [put,eq] using known
      subst c
      exact ⟨by simpa [eq] using requested,by simpa [eq] using ready.1⟩
    · exact valid k c (by simpa [put,eq] using known)
  | _ => exact ⟨request_retained (by assumption) (valid k c known).1,credential_retained (by assumption) (valid k c known).2⟩

theorem joined_step (e : Step edge o s t) (valid : Joined s) : Joined t := by
  intro k r known
  have event := e
  cases e with
  | activate next c p ready released holder fresh actual root pendingOnly durable =>
    change next.roots k = some r at known
    rw [root] at known
    by_cases eq : k = c.plan.root.template.ticket.launch
    · have same : c.plan.root = r := by simpa [put,eq] using known
      exact ⟨c,by simp [put,eq],by simpa [eq] using released,by simpa [eq] using ready.1,same⟩
    · obtain ⟨old,activated,releasedOld,credential,same⟩ := valid k r (by simpa [put,eq] using known)
      exact ⟨old,by simpa [put,eq] using activated,releasedOld,credential,same⟩
  | advance next qualified actual noRoot durable => exact valid k r (by simpa [noRoot] using known)
  | revoke next actual noRoot fence durable => exact valid k r (by simpa [noRoot] using known)
  | _ =>
    obtain ⟨c,activation,released,credential,same⟩ := valid k r known
    exact ⟨c,activation,release_retained (by assumption) released,credential_retained (by assumption) credential,same⟩

theorem outcome_step (e : Step edge o s t) (valid : Outcome s) : Outcome t := by
  intro k c known
  have event := e
  cases e with
  | activate next new p ready released holder fresh actual root pendingOnly durable =>
    change next.roots k = some c.plan.root ∧ _
    rw [root]
    by_cases eq : k = new.plan.root.template.ticket.launch
    · have same : new = c := by simpa [put,eq] using known
      subst c
      exact ⟨by simp [put,eq],by simpa [eq] using released,by simpa [eq] using ready.1⟩
    · obtain ⟨old,releaseOld,cred⟩ := valid k c (by simpa [put,eq] using known)
      exact ⟨by simpa [put,eq] using old,releaseOld,cred⟩
  | advance next qualified actual noRoot durable => simpa [noRoot] using valid k c known
  | revoke next actual noRoot fence durable => simpa [noRoot] using valid k c known
  | _ => exact ⟨(valid k c known).1,release_retained (by assumption) (valid k c known).2.1,credential_retained (by assumption) (valid k c known).2.2⟩

theorem qualified_step (e : Step edge o s t) (q : Qualified o s) : Qualified o t :=
  ⟨valid_step e q.1,requested_step e q.2.1,released_step e q.2.2.1,joined_step e q.2.2.2.1,outcome_step e q.2.2.2.2⟩
theorem qualified_run (r : Run edge o s t) (q : Qualified o s) : Qualified o t := by
  induction r with
  | refl => exact q
  | next r e ih => exact qualified_step e ih

theorem inconsistent_image_rejected (bad : ¬ Qualified o s) : ¬ Current o s c := by
  intro h; exact bad h.2.2.2.2.2.2

theorem new_root_stages_only (e : Step edge o s t)
    (absent : s.inner.roots k = none) (present : t.inner.roots k = some r) :
    t.inner.bindings = s.inner.bindings ∧ t.inner.inner = s.inner.inner := by
  cases e with
  | activate next c p ready released holder fresh actual root pendingOnly durable =>
    change next.bindings = s.inner.bindings ∧ next.inner = s.inner.inner
    rw [pendingOnly]
    exact ⟨rfl,rfl⟩
  | advance next qualified actual noRoot durable =>
    change next.roots k = some r at present
    rw [noRoot,absent] at present; cases present
  | revoke next actual noRoot fence durable =>
    change next.roots k = some r at present
    rw [noRoot,absent] at present; cases present
  | _ => rw [absent] at present; cases present

theorem new_root_has_current_holder (e : Step edge o s t)
    (absent : s.inner.roots k = none) (present : t.inner.roots k = some r) :
    ∃ c p, Current o s c ∧ s.released k = some c ∧ UseBinding o c p ∧ c.plan.root = r := by
  cases e with
  | activate next c p ready released holder fresh actual root pendingOnly durable =>
    change next.roots k = some r at present
    rw [root] at present
    by_cases eq : k = c.plan.root.template.ticket.launch
    · have same : c.plan.root = r := by simpa [put,eq] using present
      exact ⟨c,p,ready,by simpa [eq] using released,holder,same⟩
    · have old : s.inner.roots k = some r := by simpa [put,eq] using present
      rw [absent] at old; cases old
  | advance next qualified actual noRoot durable =>
    change next.roots k = some r at present
    rw [noRoot,absent] at present; cases present
  | revoke next actual noRoot fence durable =>
    change next.roots k = some r at present
    rw [noRoot,absent] at present; cases present
  | _ => rw [absent] at present; cases present

theorem plan_origin (r : Run edge o s t) (empty : ∀ k, s.plans k = none) (known : t.plans k = some p) : o.planAuthorized p := by
  induction r with
  | refl => rw [empty] at known; cases known
  | next r e ih =>
    cases e with
    | plan new authorized fresh epoch canonical audience purpose durable =>
      by_cases eq : k = new.root.template.ticket.launch
      · have same : new = p := by simpa [put,eq] using known
        simpa [same] using authorized
      · exact ih (by simpa [put,eq] using known)
    | _ => exact ih known

theorem issuance_authorized (r : Run edge o s t) (empty : ∀ k, s.plans k = none)
    (valid : Valid o t) (known : t.credentials k = some c) : o.planAuthorized c.plan :=
  plan_origin r empty (valid k c known).1

theorem extend (r : LlmBeneficiaryRegistration.Run ie io a b)
    (prior : LlmBeneficiaryRegistration.Run ie io x a) : LlmBeneficiaryRegistration.Run ie io x b := by
  induction r with
  | refl => exact prior
  | next r e ih => exact .next ih e

theorem composition (r : Run edge o s t)
    (actual : ∀ a b, edge a b → LlmBeneficiaryRegistration.Run ie io a b)
    (prior : LlmBeneficiaryRegistration.Run ie io x s.inner) : LlmBeneficiaryRegistration.Run ie io x t.inner := by
  induction r with
  | refl => exact prior
  | next r e ih =>
    cases e with
    | activate next c p ready released holder fresh event root pendingOnly durable => exact extend (actual _ _ event) ih
    | advance next qualified event noRoot durable => exact extend (actual _ _ event) ih
    | revoke next event noRoot fence durable => exact extend (actual _ _ event) ih
    | _ => exact ih

theorem first_key_retained (r : Run edge o s t)
    (actual : ∀ a b, edge a b → LlmBeneficiaryRegistration.Run ie io a b)
    (old : s.inner.bindings k = some b) (new : t.inner.bindings k = some other) : b = other :=
  LlmBeneficiaryRegistration.no_replacement (composition r actual (.refl _)) old new
theorem original_reservation_once (safe : LlmAppendHandoff.Safe ho h)
    (run : Run edge owner start s)
    (enrollment : ∀ a b, edge a b → LlmBeneficiaryRegistration.Run be bo a b)
    (publication : ∀ a b, be a b → LlmBootstrapInvitation.Run ie io a b)
    (actual : ∀ a b, ie a b → LlmIncarnationIssuance.Run ao wo co ho fo jo semantic po o genesis a b)
    (priorCaller : LlmCallerCustody.Run ao wo co ho fo jo semantic po (LlmIncarnationIssuance.logicalOwner o.base) genesis callerStart start.inner.inner.inner.current)
    (priorPublication : LlmCustodyPublication.Run ao wo co ho fo jo semantic po genesis (LlmCustodyPublication.initial custodyStart) callerStart.logical)
    (priorCustody : LlmSourceCustody.Run ao wo co ho fo jo (LlmCustodyPublication.logicalOwner semantic) genesis (LlmSourceCustody.initial (LlmSourceJoin.initial (LlmAdmissionFloor.initial h))) custodyStart)
    (priorAccount : LlmCheckpointTruncation.Run ao wo co genesis (LlmCheckpointTruncation.initial ao balances) h.logical) (key) :
    (LlmSourceJoin.account s.inner.inner.inner.current.logical.authority.logical).authority.writes key ≤ 1 :=
  LlmBeneficiaryRegistration.original_reservation_once safe (composition run enrollment (.refl _)) publication actual priorCaller priorPublication priorCustody priorAccount key

theorem unknown_original_hold_retained (safe : LlmAppendHandoff.Safe ho h)
    (run : Run edge owner start s)
    (enrollment : ∀ a b, edge a b → LlmBeneficiaryRegistration.Run be bo a b)
    (publication : ∀ a b, be a b → LlmBootstrapInvitation.Run ie io a b)
    (actual : ∀ a b, ie a b → LlmIncarnationIssuance.Run ao wo co ho fo jo semantic po o genesis a b)
    (priorCaller : LlmCallerCustody.Run ao wo co ho fo jo semantic po (LlmIncarnationIssuance.logicalOwner o.base) genesis callerStart start.inner.inner.inner.current)
    (priorPublication : LlmCustodyPublication.Run ao wo co ho fo jo semantic po genesis (LlmCustodyPublication.initial custodyStart) callerStart.logical)
    (priorCustody : LlmSourceCustody.Run ao wo co ho fo jo (LlmCustodyPublication.logicalOwner semantic) genesis (LlmSourceCustody.initial (LlmSourceJoin.initial (LlmAdmissionFloor.initial h))) custodyStart)
    (priorAccount : LlmCheckpointTruncation.Run ao wo co genesis (LlmCheckpointTruncation.initial ao balances) h.logical)
    (source : LlmExecutionReconciliation.State S) (unknownUsage : source.metered = false)
    (binding : ∀ tx state, tx.reservation = originalKey → ao.sourceReady tx state → LlmAccountCommit.OriginalReady originalKey attempt source tx) :
    (LlmSourceJoin.account s.inner.inner.inner.current.logical.authority.logical).authority.reservations originalKey = none ∧
    (LlmSourceJoin.account s.inner.inner.inner.current.logical.authority.logical).authority.holds originalKey = ao.bound originalKey :=
  LlmBeneficiaryRegistration.unknown_original_hold_retained safe (composition run enrollment (.refl _)) publication actual priorCaller priorPublication priorCustody priorAccount source unknownUsage binding


#print axioms plan_retained
#print axioms credential_retained
#print axioms id_retained
#print axioms request_retained
#print axioms release_retained
#print axioms activation_retained
#print axioms credential_run
#print axioms no_subject_or_key_replacement
#print axioms forwarded_subject_rejected
#print axioms nominated_enrollment_key_rejected
#print axioms issue_session_bound
#print axioms holder_session_bound
#print axioms stale_issuer_rejected
#print axioms stale_read_rejected
#print axioms valid_step
#print axioms valid_run
#print axioms credential_id_unique
#print axioms requested_step
#print axioms released_step
#print axioms joined_step
#print axioms outcome_step
#print axioms qualified_step
#print axioms qualified_run
#print axioms inconsistent_image_rejected
#print axioms new_root_stages_only
#print axioms new_root_has_current_holder
#print axioms plan_origin
#print axioms issuance_authorized
#print axioms composition
#print axioms first_key_retained
#print axioms original_reservation_once
#print axioms unknown_original_hold_retained
end Weaver.LlmEnrollmentCredential
