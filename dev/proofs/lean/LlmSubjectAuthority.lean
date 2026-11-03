-- SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
--
-- SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

import LlmEnrollmentCredential
namespace Weaver.LlmSubjectAuthority
abbrev EState := LlmEnrollmentCredential.State
abbrev Plan := LlmEnrollmentCredential.Plan
structure Principal where
  authority : Nat
  tenant : Nat
  subject : Nat
  key : Nat
  generation : Nat
structure Task where
  template : Plan
  authority : Nat
  tenant : Nat
  producer : Nat
structure Assignment where
  task : Task
  plan : Plan
structure Approval where
  subject : Principal
  producer : Principal
structure State where
  inner : EState
  subjects : Nat → Option Principal
  producers : Nat → Option Principal
  tasks : Nat → Option Task
  assignments : Nat → Option Assignment
  approvals : Nat → Option Approval
  published : Nat → Option Assignment
  revision : Nat
  seen : Option Nat
structure Owner where
  -- Configured enterprise identity authority; never a caller-nominated issuer/SA.
  subjectSource : Principal → Prop
  producerSource : Principal → Prop
  taskSource : Task → Prop
  verify : Assignment → Approval → Prop
  verifyNewIssue : State → Assignment → Approval → LlmEnrollmentCredential.Credential → Prop
  currentAllows : State → Assignment → Prop
  durable : State → State → Prop
  readCurrent : State → Prop
  recover : Task → Principal → Prop

def eraseSubjectKey (p : Plan) : Plan := {p with subjectKey := 0}
def Original (a : Assignment) : Prop := eraseSubjectKey a.plan = a.task.template

def AuthBinding (o : Owner) (a : Assignment) (v : Approval) : Prop :=
  o.verify a v ∧ v.subject.subject = a.plan.subject ∧
  v.subject.authority = a.task.authority ∧ v.subject.tenant = a.task.tenant ∧
  v.subject.key = a.plan.subjectKey ∧ v.producer.subject = a.task.producer ∧
  v.producer.authority = a.task.authority ∧ v.producer.tenant = a.task.tenant

def Rotation (old next : Principal) : Prop :=
  next.authority = old.authority ∧ next.tenant = old.tenant ∧
  next.subject = old.subject ∧ next.generation = old.generation+1

def Sources (o : Owner) (s : State) : Prop :=
  (∀ k r, s.subjects k = some r → r.subject = k ∧ o.subjectSource r) ∧
  (∀ k r, s.producers k = some r → r.subject = k ∧ o.producerSource r)
def Valid (s : State) : Prop := ∀ k a, s.assignments k = some a →
  s.tasks k = some a.task ∧ a.plan.root.template.ticket.launch = k ∧ Original a

def Joined (s : State) : Prop := ∀ k p, s.inner.plans k = some p →
  ∃ a, s.assignments k = some a ∧ s.published k = some a ∧ a.plan = p

def Outcome (s : State) : Prop := ∀ k a, s.published k = some a →
  s.assignments k = some a ∧ s.inner.plans k = some a.plan

def Qualified (o : Owner) (s : State) : Prop := Sources o s ∧ Valid s ∧ Joined s ∧ Outcome s

def CanApprove (o : Owner) (s : State) (a : Assignment) (v : Approval) : Prop :=
  s.assignments a.plan.root.template.ticket.launch = some a ∧
  s.subjects a.plan.subject = some v.subject ∧ s.producers a.task.producer = some v.producer ∧
  AuthBinding o a v ∧ s.seen = some s.revision ∧ o.currentAllows s a ∧
  a.plan.root.epoch = s.inner.inner.epoch ∧
  LlmBeneficiaryRegistration.Blueprint s.inner.inner a.plan.root.template ∧ Qualified o s

def CanAssign (o : Owner) (s : State) (a : Assignment) (v : Approval) : Prop :=
  s.tasks a.plan.root.template.ticket.launch = some a.task ∧
  s.assignments a.plan.root.template.ticket.launch = none ∧ Original a ∧
  s.subjects a.plan.subject = some v.subject ∧ s.producers a.task.producer = some v.producer ∧
  AuthBinding o a v ∧ s.seen = some s.revision ∧ o.currentAllows s a ∧ Qualified o s

-- Authorization-key rotation affects new issuance; historical credentials are not erased.
def NewIssues (o : Owner) (s : State) (next : EState) : Prop := ∀ k c,
  next.credentials k = some c → s.inner.credentials k = none →
  ∃ a v, s.assignments k = some a ∧ s.approvals k = some v ∧
    c.plan = a.plan ∧ CanApprove o s a v ∧ o.verifyNewIssue s a v c

abbrev put := @LlmEnrollmentCredential.put
inductive Step (edge : EState → EState → Prop) (o : Owner) : State → State → Prop where
  | subject (s r) (native : o.subjectSource r) (fresh : s.subjects r.subject = none)
      (durable : o.durable s {s with subjects := put s.subjects r.subject r, revision := s.revision+1, seen := none}) :
      Step edge o s {s with subjects := put s.subjects r.subject r, revision := s.revision+1, seen := none}
  | producer (s r) (native : o.producerSource r) (fresh : s.producers r.subject = none)
      (durable : o.durable s {s with producers := put s.producers r.subject r, revision := s.revision+1, seen := none}) :
      Step edge o s {s with producers := put s.producers r.subject r, revision := s.revision+1, seen := none}
  | rotateSubject (s old next) (known : s.subjects old.subject = some old)
      (rotation : Rotation old next) (native : o.subjectSource next)
      (durable : o.durable s {s with subjects := put s.subjects old.subject next, revision := s.revision+1, seen := none}) :
      Step edge o s {s with subjects := put s.subjects old.subject next, revision := s.revision+1, seen := none}
  | rotateProducer (s old next) (known : s.producers old.subject = some old)
      (rotation : Rotation old next) (native : o.producerSource next)
      (durable : o.durable s {s with producers := put s.producers old.subject next, revision := s.revision+1, seen := none}) :
      Step edge o s {s with producers := put s.producers old.subject next, revision := s.revision+1, seen := none}
  | task (s t) (native : o.taskSource t) (fresh : s.tasks t.template.root.template.ticket.launch = none)
      (canonical : eraseSubjectKey t.template = t.template)
      (durable : o.durable s {s with tasks := put s.tasks t.template.root.template.ticket.launch t, revision := s.revision+1, seen := none}) :
      Step edge o s {s with tasks := put s.tasks t.template.root.template.ticket.launch t, revision := s.revision+1, seen := none}
  | assign (s a v) (ready : CanAssign o s a v)
      (durable : o.durable s {s with assignments := put s.assignments a.plan.root.template.ticket.launch a, revision := s.revision+1, seen := none}) :
      Step edge o s {s with assignments := put s.assignments a.plan.root.template.ticket.launch a, revision := s.revision+1, seen := none}
  | approve (s a v) (ready : CanApprove o s a v)
      (durable : o.durable s {s with approvals := put s.approvals a.plan.root.template.ticket.launch v, revision := s.revision+1, seen := none}) :
      Step edge o s {s with approvals := put s.approvals a.plan.root.template.ticket.launch v, revision := s.revision+1, seen := none}
  | publish (s next a v) (ready : CanApprove o s a v)
      (approved : s.approvals a.plan.root.template.ticket.launch = some v)
      (fresh : s.inner.plans a.plan.root.template.ticket.launch = none)
      (actual : edge s.inner next)
      (exactUpdate : next = {s.inner with plans := put s.inner.plans a.plan.root.template.ticket.launch a.plan, revision := s.inner.revision+1, seen := none})
      (durable : o.durable s {s with inner := next, published := put s.published a.plan.root.template.ticket.launch a, revision := s.revision+1, seen := none}) :
      Step edge o s {s with inner := next, published := put s.published a.plan.root.template.ticket.launch a, revision := s.revision+1, seen := none}
  | advance (s next) (qualified : Qualified o s) (actual : edge s.inner next)
      (noPlan : next.plans = s.inner.plans) (newIssues : NewIssues o s next)
      (durable : o.durable s {s with inner := next, revision := s.revision+1, seen := none}) :
      Step edge o s {s with inner := next, revision := s.revision+1, seen := none}
  | observe (s) (native : o.readCurrent s) : Step edge o s {s with seen := some s.revision}
  | restart (s) : Step edge o s {s with seen := none}
  | recover (s k t r) (task : s.tasks k = some t) (current : s.subjects r.subject = some r)
      (binding : r.subject = t.template.subject ∧ r.authority = t.authority ∧ r.tenant = t.tenant)
      (allowed : o.recover t r) : Step edge o s s
inductive Run (edge : EState → EState → Prop) (o : Owner) : State → State → Prop where
  | refl (s) : Run edge o s s
  | next : Run edge o a b → Step edge o b c → Run edge o a c

theorem task_retained (e : Step edge o s t) (known : s.tasks k = some r) : t.tasks k = some r := by
  cases e <;> simp_all [put,LlmEnrollmentCredential.put] <;> intro eq <;> simp_all

theorem assignment_retained (e : Step edge o s t) (known : s.assignments k = some a) : t.assignments k = some a := by
  cases e <;> simp_all [put,LlmEnrollmentCredential.put,CanAssign] <;> intro eq <;> simp_all

theorem assignment_run (r : Run edge o s t) (known : s.assignments k = some a) : t.assignments k = some a := by
  induction r with
  | refl => exact known
  | next r e ih => exact assignment_retained e ih

theorem no_enrollment_replacement (r : Run edge o s t) (old : s.assignments k = some a) (new : t.assignments k = some b) : a.plan.root.enrollmentKey = b.plan.root.enrollmentKey := by
  have retained := assignment_run r old
  rw [retained] at new
  exact congrArg (fun a : Assignment => a.plan.root.enrollmentKey) (Option.some.inj new)

theorem original_enrollment_bound (h : Original a) : a.plan.root.enrollmentKey = a.task.template.root.enrollmentKey := by
  have same := congrArg (fun p : Plan => p.root.enrollmentKey) h
  simpa [eraseSubjectKey] using same

theorem shared_identity_rejected (wrong : v.subject.key ≠ a.plan.subjectKey) : ¬ AuthBinding o a v := by
  intro h; exact wrong h.2.2.2.2.1

theorem other_authority_rejected (wrong : v.subject.authority ≠ a.task.authority) : ¬ AuthBinding o a v := by
  intro h; exact wrong h.2.2.1

theorem other_tenant_rejected (wrong : v.subject.tenant ≠ a.task.tenant) : ¬ AuthBinding o a v := by
  intro h; exact wrong h.2.2.2.1

theorem wrong_producer_rejected (wrong : v.producer.subject ≠ a.task.producer) : ¬ AuthBinding o a v := by
  intro h; exact wrong h.2.2.2.2.2.1

theorem rotation_preserves_identity (r : Rotation old next) : next.authority = old.authority ∧ next.tenant = old.tenant ∧ next.subject = old.subject := ⟨r.1,r.2.1,r.2.2.1⟩

theorem rotation_advances_generation (r : Rotation old next) : old.generation < next.generation := by
  have h := r.2.2.2; omega

theorem stale_subject_rejected (wrong : s.subjects a.plan.subject ≠ some v.subject) : ¬ CanApprove o s a v := by
  intro h; exact wrong h.2.1

theorem stale_producer_rejected (wrong : s.producers a.task.producer ≠ some v.producer) : ¬ CanApprove o s a v := by
  intro h; exact wrong h.2.2.1

theorem missing_current_credential_rejected (missing : ¬ o.verify a v) : ¬ CanApprove o s a v := by
  intro h; exact missing h.2.2.2.1.1

theorem stale_read_rejected (wrong : s.seen ≠ some s.revision) : ¬ CanApprove o s a v := by
  intro h; exact wrong h.2.2.2.2.1

theorem sources_step (e : Step edge o s t) (valid : Sources o s) : Sources o t := by
  constructor
  · intro k r known
    cases e with
    | subject new native fresh durable =>
      by_cases eq : k = new.subject
      · have same : new = r := by simpa [put,LlmEnrollmentCredential.put,eq] using known
        subst r; exact ⟨eq.symm,native⟩
      · exact valid.1 k r (by simpa [put,LlmEnrollmentCredential.put,eq] using known)
    | rotateSubject old next prior rotation native durable =>
      by_cases eq : k = old.subject
      · have same : next = r := by simpa [put,LlmEnrollmentCredential.put,eq] using known
        subst r; exact ⟨rotation.2.2.1.trans eq.symm,native⟩
      · exact valid.1 k r (by simpa [put,LlmEnrollmentCredential.put,eq] using known)
    | _ => exact valid.1 k r known
  · intro k r known
    cases e with
    | producer new native fresh durable =>
      by_cases eq : k = new.subject
      · have same : new = r := by simpa [put,LlmEnrollmentCredential.put,eq] using known
        subst r; exact ⟨eq.symm,native⟩
      · exact valid.2 k r (by simpa [put,LlmEnrollmentCredential.put,eq] using known)
    | rotateProducer old next prior rotation native durable =>
      by_cases eq : k = old.subject
      · have same : next = r := by simpa [put,LlmEnrollmentCredential.put,eq] using known
        subst r; exact ⟨rotation.2.2.1.trans eq.symm,native⟩
      · exact valid.2 k r (by simpa [put,LlmEnrollmentCredential.put,eq] using known)
    | _ => exact valid.2 k r known

theorem valid_step (e : Step edge o s t) (valid : Valid s) : Valid t := by
  intro k a known
  have event := e
  cases e with
  | task new native fresh canonical durable =>
    obtain ⟨task,index,original⟩ := valid k a known
    have different : k ≠ new.template.root.template.ticket.launch := by
      intro eq
      have no : s.tasks k = none := by simpa [eq] using fresh
      rw [task] at no; cases no
    exact ⟨by simpa [put,LlmEnrollmentCredential.put,different] using task,index,original⟩
  | assign new v ready durable =>
    by_cases eq : k = new.plan.root.template.ticket.launch
    · have same : new = a := by simpa [put,LlmEnrollmentCredential.put,eq] using known
      subst a
      exact ⟨by simpa [eq] using ready.1,eq.symm,ready.2.2.1⟩
    · exact valid k a (by simpa [put,LlmEnrollmentCredential.put,eq] using known)
  | _ => exact ⟨task_retained event (valid k a known).1,(valid k a known).2⟩

theorem joined_step (e : Step edge o s t) (valid : Joined s) : Joined t := by
  intro k p known
  have event := e
  cases e with
  | publish next a v ready approved fresh actual exactUpdate durable =>
    change next.plans k = some p at known
    rw [exactUpdate] at known
    by_cases eq : k = a.plan.root.template.ticket.launch
    · have same : a.plan = p := by simpa [put,LlmEnrollmentCredential.put,eq] using known
      exact ⟨a,by simpa [eq] using ready.1,by simp [put,LlmEnrollmentCredential.put,eq],same⟩
    · obtain ⟨old,assignment,published,same⟩ := valid k p (by simpa [put,LlmEnrollmentCredential.put,eq] using known)
      exact ⟨old,assignment,by simpa [put,LlmEnrollmentCredential.put,eq] using published,same⟩
  | advance next qualified actual noPlan newIssues durable => exact valid k p (by simpa [noPlan] using known)
  | _ =>
    obtain ⟨a,assignment,published,same⟩ := valid k p known
    exact ⟨a,assignment_retained event assignment,published,same⟩

theorem outcome_step (e : Step edge o s t) (valid : Outcome s) : Outcome t := by
  intro k a known
  have event := e
  cases e with
  | publish next new v ready approved fresh actual exactUpdate durable =>
    change s.assignments k = some a ∧ next.plans k = some a.plan
    rw [exactUpdate]
    by_cases eq : k = new.plan.root.template.ticket.launch
    · have same : new = a := by simpa [put,LlmEnrollmentCredential.put,eq] using known
      subst a
      exact ⟨by simpa [eq] using ready.1,by simp [put,LlmEnrollmentCredential.put,eq]⟩
    · obtain ⟨assigned,plan⟩ := valid k a (by simpa [put,LlmEnrollmentCredential.put,eq] using known)
      exact ⟨assigned,by simpa [put,LlmEnrollmentCredential.put,eq] using plan⟩
  | advance next qualified actual noPlan newIssues durable => simpa [noPlan] using valid k a known
  | _ => exact ⟨assignment_retained event (valid k a known).1,(valid k a known).2⟩

theorem qualified_step (e : Step edge o s t) (q : Qualified o s) : Qualified o t :=
  ⟨sources_step e q.1,valid_step e q.2.1,joined_step e q.2.2.1,outcome_step e q.2.2.2⟩
theorem qualified_run (r : Run edge o s t) (q : Qualified o s) : Qualified o t := by
  induction r with
  | refl => exact q
  | next r e ih => exact qualified_step e ih

theorem inconsistent_image_rejected (bad : ¬ Qualified o s) : ¬ CanApprove o s a v := by
  intro h; exact bad h.2.2.2.2.2.2.2.2

theorem task_origin (r : Run edge o s t) (empty : ∀ k, s.tasks k = none) (known : t.tasks k = some task) : o.taskSource task := by
  induction r with
  | refl => rw [empty] at known; cases known
  | next r e ih =>
    cases e with
    | task new native fresh canonical durable =>
      by_cases eq : k = new.template.root.template.ticket.launch
      · have same : new = task := by simpa [put,LlmEnrollmentCredential.put,eq] using known
        simpa [same] using native
      · exact ih (by simpa [put,LlmEnrollmentCredential.put,eq] using known)
    | _ => exact ih known

theorem assignment_from_original_task (r : Run edge o s t) (empty : ∀ k, s.tasks k = none)
    (valid : Valid t) (known : t.assignments k = some a) : o.taskSource a.task :=
  task_origin r empty (valid k a known).1

theorem new_plan_has_current_assignment (e : Step edge o s t)
    (absent : s.inner.plans k = none) (present : t.inner.plans k = some p) :
    ∃ a v, CanApprove o s a v ∧ s.approvals k = some v ∧ a.plan = p := by
  cases e with
  | publish next a v ready approved fresh actual exactUpdate durable =>
    change next.plans k = some p at present
    rw [exactUpdate] at present
    by_cases eq : k = a.plan.root.template.ticket.launch
    · have same : a.plan = p := by simpa [put,LlmEnrollmentCredential.put,eq] using present
      exact ⟨a,v,ready,by simpa [eq] using approved,same⟩
    · have old : s.inner.plans k = some p := by simpa [put,LlmEnrollmentCredential.put,eq] using present
      rw [absent] at old; cases old
  | advance next qualified actual noPlan newIssues durable =>
    change next.plans k = some p at present
    rw [noPlan,absent] at present; cases present
  | _ => rw [absent] at present; cases present

theorem new_plan_has_no_credential_effect (e : Step edge o s t)
    (absent : s.inner.plans k = none) (present : t.inner.plans k = some p) :
    t.inner.credentials = s.inner.credentials ∧ t.inner.inner = s.inner.inner := by
  cases e with
  | publish next a v ready approved fresh actual exactUpdate durable =>
    change next.credentials = s.inner.credentials ∧ next.inner = s.inner.inner
    rw [exactUpdate]; exact ⟨rfl,rfl⟩
  | advance next qualified actual noPlan newIssues durable =>
    change next.plans k = some p at present
    rw [noPlan,absent] at present; cases present
  | _ => rw [absent] at present; cases present

theorem new_credential_rechecks_subject (e : Step edge o s t)
    (absent : s.inner.credentials k = none) (present : t.inner.credentials k = some c) :
    ∃ a v, s.assignments k = some a ∧ s.approvals k = some v ∧ c.plan = a.plan ∧ CanApprove o s a v ∧ o.verifyNewIssue s a v c := by
  cases e with
  | advance next qualified actual noPlan newIssues durable => exact newIssues k c present absent
  | publish next a v ready approved fresh actual exactUpdate durable =>
    change next.credentials k = some c at present
    rw [exactUpdate] at present
    change s.inner.credentials k = some c at present
    rw [absent] at present; cases present
  | _ => rw [absent] at present; cases present

theorem missing_issue_identity_rejected (e : Step edge o s t)
    (absent : s.inner.credentials k = none) (present : t.inner.credentials k = some c)
    (missing : ∀ a v, ¬ o.verifyNewIssue s a v c) : False := by
  obtain ⟨a,v,assigned,approved,plan,current,proof⟩ := new_credential_rechecks_subject e absent present
  exact missing a v proof

theorem extend (r : LlmEnrollmentCredential.Run ie io a b)
    (prior : LlmEnrollmentCredential.Run ie io x a) : LlmEnrollmentCredential.Run ie io x b := by
  induction r with
  | refl => exact prior
  | next r e ih => exact .next ih e

theorem composition (r : Run edge o s t)
    (actual : ∀ a b, edge a b → LlmEnrollmentCredential.Run ie io a b)
    (prior : LlmEnrollmentCredential.Run ie io x s.inner) : LlmEnrollmentCredential.Run ie io x t.inner := by
  induction r with
  | refl => exact prior
  | next r e ih =>
    cases e with
    | publish next a v ready approved fresh event exactUpdate durable => exact extend (actual _ _ event) ih
    | advance next qualified event noPlan newIssues durable => exact extend (actual _ _ event) ih
    | _ => exact ih

theorem credential_retained (r : Run edge o s t)
    (actual : ∀ a b, edge a b → LlmEnrollmentCredential.Run ie io a b)
    (old : s.inner.credentials k = some c) (new : t.inner.credentials k = some d) : c = d :=
  LlmEnrollmentCredential.no_subject_or_key_replacement (composition r actual (.refl _)) old new

theorem first_key_retained (r : Run edge o s t)
    (actual : ∀ a b, edge a b → LlmEnrollmentCredential.Run ie io a b)
    (enrollment : ∀ a b, ie a b → LlmBeneficiaryRegistration.Run be bo a b)
    (old : s.inner.inner.bindings k = some c) (new : t.inner.inner.bindings k = some d) : c = d :=
  LlmEnrollmentCredential.first_key_retained (composition r actual (.refl _)) enrollment old new
theorem original_reservation_once (safe : LlmAppendHandoff.Safe ho h)
    (run : Run edge owner start s)
    (identity : ∀ a b, edge a b → LlmEnrollmentCredential.Run ee eo a b)
    (enrollment : ∀ a b, ee a b → LlmBeneficiaryRegistration.Run be bo a b)
    (publication : ∀ a b, be a b → LlmBootstrapInvitation.Run ie io a b)
    (actual : ∀ a b, ie a b → LlmIncarnationIssuance.Run ao wo co ho fo jo semantic po o genesis a b)
    (priorCaller : LlmCallerCustody.Run ao wo co ho fo jo semantic po (LlmIncarnationIssuance.logicalOwner o.base) genesis callerStart start.inner.inner.inner.inner.current)
    (priorPublication : LlmCustodyPublication.Run ao wo co ho fo jo semantic po genesis (LlmCustodyPublication.initial custodyStart) callerStart.logical)
    (priorCustody : LlmSourceCustody.Run ao wo co ho fo jo (LlmCustodyPublication.logicalOwner semantic) genesis (LlmSourceCustody.initial (LlmSourceJoin.initial (LlmAdmissionFloor.initial h))) custodyStart)
    (priorAccount : LlmCheckpointTruncation.Run ao wo co genesis (LlmCheckpointTruncation.initial ao balances) h.logical) (key) :
    (LlmSourceJoin.account s.inner.inner.inner.inner.current.logical.authority.logical).authority.writes key ≤ 1 :=
  LlmEnrollmentCredential.original_reservation_once safe (composition run identity (.refl _)) enrollment publication actual priorCaller priorPublication priorCustody priorAccount key

theorem unknown_original_hold_retained (safe : LlmAppendHandoff.Safe ho h)
    (run : Run edge owner start s)
    (identity : ∀ a b, edge a b → LlmEnrollmentCredential.Run ee eo a b)
    (enrollment : ∀ a b, ee a b → LlmBeneficiaryRegistration.Run be bo a b)
    (publication : ∀ a b, be a b → LlmBootstrapInvitation.Run ie io a b)
    (actual : ∀ a b, ie a b → LlmIncarnationIssuance.Run ao wo co ho fo jo semantic po o genesis a b)
    (priorCaller : LlmCallerCustody.Run ao wo co ho fo jo semantic po (LlmIncarnationIssuance.logicalOwner o.base) genesis callerStart start.inner.inner.inner.inner.current)
    (priorPublication : LlmCustodyPublication.Run ao wo co ho fo jo semantic po genesis (LlmCustodyPublication.initial custodyStart) callerStart.logical)
    (priorCustody : LlmSourceCustody.Run ao wo co ho fo jo (LlmCustodyPublication.logicalOwner semantic) genesis (LlmSourceCustody.initial (LlmSourceJoin.initial (LlmAdmissionFloor.initial h))) custodyStart)
    (priorAccount : LlmCheckpointTruncation.Run ao wo co genesis (LlmCheckpointTruncation.initial ao balances) h.logical)
    (source : LlmExecutionReconciliation.State S) (unknownUsage : source.metered = false)
    (binding : ∀ tx state, tx.reservation = originalKey → ao.sourceReady tx state → LlmAccountCommit.OriginalReady originalKey attempt source tx) :
    (LlmSourceJoin.account s.inner.inner.inner.inner.current.logical.authority.logical).authority.reservations originalKey = none ∧
    (LlmSourceJoin.account s.inner.inner.inner.inner.current.logical.authority.logical).authority.holds originalKey = ao.bound originalKey :=
  LlmEnrollmentCredential.unknown_original_hold_retained safe (composition run identity (.refl _)) enrollment publication actual priorCaller priorPublication priorCustody priorAccount source unknownUsage binding



#print axioms task_retained
#print axioms assignment_retained
#print axioms assignment_run
#print axioms no_enrollment_replacement
#print axioms original_enrollment_bound
#print axioms shared_identity_rejected
#print axioms other_authority_rejected
#print axioms other_tenant_rejected
#print axioms wrong_producer_rejected
#print axioms rotation_preserves_identity
#print axioms rotation_advances_generation
#print axioms stale_subject_rejected
#print axioms stale_producer_rejected
#print axioms missing_current_credential_rejected
#print axioms stale_read_rejected
#print axioms sources_step
#print axioms valid_step
#print axioms joined_step
#print axioms outcome_step
#print axioms qualified_step
#print axioms qualified_run
#print axioms inconsistent_image_rejected
#print axioms task_origin
#print axioms assignment_from_original_task
#print axioms new_plan_has_current_assignment
#print axioms new_plan_has_no_credential_effect
#print axioms new_credential_rechecks_subject
#print axioms missing_issue_identity_rejected
#print axioms composition
#print axioms credential_retained
#print axioms first_key_retained
#print axioms original_reservation_once
#print axioms unknown_original_hold_retained
end Weaver.LlmSubjectAuthority
