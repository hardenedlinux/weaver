import LlmBootstrapInvitation
namespace Weaver.LlmBeneficiaryRegistration
open LlmBootstrapInvitation (Invitation)

-- The template has no beneficiary-key authority. Its key is erased to zero.
def eraseKey (i : Invitation) : Invitation :=
  {i with ticket := {i.ticket with target := {i.ticket.target with key := 0}}}
structure Root where
  template : Invitation
  enrollmentKey : Nat
  epoch : Nat
  challenge : Nat
structure Peer where
  enrollmentKey : Nat
  beneficiaryKey : Nat
  workload : Nat
  session : Nat
  challenge : Nat
structure Binding where
  root : Root
  invitation : Invitation
  peer : Peer
structure State where
  inner : LlmBootstrapInvitation.State
  roots : Nat → Option Root
  bindings : Nat → Option Binding
  published : Nat → Option Invitation
  epoch : Nat
  revision : Nat
  seen : Option Nat
structure Owner where
  -- Independent producer-controlled launch entitlement; never a shared-workload bearer.
  rootAuthorized : Root → Prop
  -- Two proofs cover root, full new key, session and exact original template.
  verify : Root → Invitation → Peer → Prop
  currentAllows : State → Binding → Prop
  durable : State → State → Prop
  readCurrent : State → Prop
  recover : Root → Nat → Prop

def Credential (o : Owner) (r : Root) (i : Invitation) (p : Peer) : Prop :=
  o.verify r i p ∧ p.enrollmentKey = r.enrollmentKey ∧
  p.beneficiaryKey = i.ticket.target.key ∧ p.workload = i.ticket.target.workload ∧
  p.session = r.template.ticket.session ∧ p.challenge = r.challenge

def Blueprint (s : State) (i : Invitation) : Prop :=
  i.ticket.previous = s.inner.inner.current.grant ∧
  i.ticket.parent = s.inner.inner.current.logical.journal.length ∧
  i.ticket.epoch = s.inner.inner.epoch ∧ i.ticket.challenge = s.inner.inner.challenge ∧
  s.inner.inner.current.now < i.ticket.target.expires

def CanBind (o : Owner) (s : State) (b : Binding) : Prop :=
  s.roots b.invitation.ticket.launch = some b.root ∧
  s.bindings b.invitation.ticket.launch = none ∧ b.root.epoch = s.epoch ∧
  eraseKey b.invitation = b.root.template ∧ Credential o b.root b.invitation b.peer ∧
  Blueprint s b.invitation ∧ s.seen = some s.revision

def CanPublish (o : Owner) (s : State) (b : Binding) : Prop :=
  s.roots b.invitation.ticket.launch = some b.root ∧
  s.bindings b.invitation.ticket.launch = some b ∧ b.root.epoch = s.epoch ∧
  s.published b.invitation.ticket.launch = none ∧ Blueprint s b.invitation ∧
  s.seen = some s.revision ∧ o.currentAllows s b

inductive Step (edge : LlmBootstrapInvitation.State → LlmBootstrapInvitation.State → Prop)
    (o : Owner) : State → State → Prop where
  | root (s r) (authorized : o.rootAuthorized r)
      (fresh : s.roots r.template.ticket.launch = none) (epoch : r.epoch = s.epoch)
      (canonical : eraseKey r.template = r.template)
      (durable : o.durable s {s with roots := fun k => if k = r.template.ticket.launch then some r else s.roots k, revision := s.revision+1, seen := none}) :
      Step edge o s {s with roots := fun k => if k = r.template.ticket.launch then some r else s.roots k, revision := s.revision+1, seen := none}
  | bind (s b) (ready : CanBind o s b)
      (durable : o.durable s {s with bindings := fun k => if k = b.invitation.ticket.launch then some b else s.bindings k, revision := s.revision+1, seen := none}) :
      Step edge o s {s with bindings := fun k => if k = b.invitation.ticket.launch then some b else s.bindings k, revision := s.revision+1, seen := none}
  | publish (s next b) (ready : CanPublish o s b)
      (fresh : s.inner.invitations b.invitation.id = none)
      (actual : edge s.inner next)
      (registered : next.invitations = fun k => if k = b.invitation.id then some b.invitation else s.inner.invitations k)
      (pendingOnly : next.inner = s.inner.inner)
      (durable : o.durable s {s with inner := next, published := fun k => if k = b.invitation.ticket.launch then some b.invitation else s.published k, revision := s.revision+1, seen := none}) :
      Step edge o s {s with inner := next, published := fun k => if k = b.invitation.ticket.launch then some b.invitation else s.published k, revision := s.revision+1, seen := none}
  | advance (s next) (actual : edge s.inner next) (noPublish : next.invitations = s.inner.invitations)
      (durable : o.durable s {s with inner := next, revision := s.revision+1, seen := none}) :
      Step edge o s {s with inner := next, revision := s.revision+1, seen := none}
  | revoke (s next) (actual : edge s.inner next) (noPublish : next.invitations = s.inner.invitations)
      (issuerFence : next.inner.epoch = s.inner.inner.epoch+1)
      (durable : o.durable s {s with inner := next, epoch := s.epoch+1, revision := s.revision+1, seen := none}) :
      Step edge o s {s with inner := next, epoch := s.epoch+1, revision := s.revision+1, seen := none}
  | observe (s) (authentic : o.readCurrent s) : Step edge o s {s with seen := some s.revision}
  | restart (s) : Step edge o s {s with seen := none}
  | recover (s launch r reader) (known : s.roots launch = some r) (allowed : o.recover r reader) : Step edge o s s

inductive Run (edge : LlmBootstrapInvitation.State → LlmBootstrapInvitation.State → Prop)
    (o : Owner) : State → State → Prop where
  | refl (s) : Run edge o s s
  | next : Run edge o a b → Step edge o b c → Run edge o a c

theorem root_retained (e : Step edge o s t) (known : s.roots k = some r) : t.roots k = some r := by
  cases e <;> simp_all <;> intro eq <;> simp_all

theorem binding_retained (e : Step edge o s t) (known : s.bindings k = some b) : t.bindings k = some b := by
  cases e <;> simp_all [CanBind] <;> intro eq <;> simp_all

theorem publication_retained (e : Step edge o s t) (known : s.published k = some i) : t.published k = some i := by
  cases e <;> simp_all [CanPublish] <;> intro eq <;> simp_all

theorem binding_run (r : Run edge o s t) (known : s.bindings k = some b) : t.bindings k = some b := by
  induction r with
  | refl => exact known
  | next r e ih => exact binding_retained e ih

theorem no_replacement (r : Run edge o s t) (old : s.bindings k = some b) (new : t.bindings k = some other) : b = other := by
  have retained := binding_run r old
  rw [retained] at new
  exact Option.some.inj new

theorem shared_identity_not_entitlement (wrong : p.enrollmentKey ≠ r.enrollmentKey) : ¬ Credential o r i p := by
  intro h
  exact wrong h.2.1

theorem beneficiary_possession_required (wrong : p.beneficiaryKey ≠ i.ticket.target.key) : ¬ Credential o r i p := by
  intro h
  exact wrong h.2.2.1

theorem session_cannot_be_selected (wrong : p.session ≠ r.template.ticket.session) : ¬ Credential o r i p := by
  intro h
  exact wrong h.2.2.2.2.1

theorem original_previous_preserved {r : Root} {i : Invitation} (aligned : eraseKey i = r.template) : i.ticket.previous = r.template.ticket.previous := by
  have h := congrArg (fun x : Invitation => x.ticket.previous) aligned
  simpa [eraseKey] using h

theorem stale_epoch_cannot_publish (wrong : b.root.epoch ≠ s.epoch) : ¬ CanPublish o s b := by
  intro h
  exact wrong h.2.2.1

theorem stale_read_cannot_publish (wrong : s.seen ≠ some s.revision) : ¬ CanPublish o s b := by
  intro h
  exact wrong h.2.2.2.2.2.1

def ValidBindings (o : Owner) (s : State) : Prop := ∀ k b, s.bindings k = some b →
  s.roots k = some b.root ∧ b.invitation.ticket.launch = k ∧
  eraseKey b.invitation = b.root.template ∧ Credential o b.root b.invitation b.peer

theorem valid_bindings_step (e : Step edge o s t) (valid : ValidBindings o s) : ValidBindings o t := by
  intro k b known
  cases e with
  | root r authorized fresh epoch canonical durable =>
    obtain ⟨root,launch,template,proof⟩ := valid k b known
    have different : k ≠ r.template.ticket.launch := by
      intro eq
      have no : s.roots k = none := by simpa [eq] using fresh
      rw [no] at root
      cases root
    exact ⟨by simpa [different] using root,launch,template,proof⟩
  | bind new ready durable =>
    by_cases eq : k = new.invitation.ticket.launch
    · have same : new = b := by simpa [eq] using known
      subst b
      exact ⟨by simpa [eq] using ready.1,eq.symm,ready.2.2.2.1,ready.2.2.2.2.1⟩
    · exact valid k b (by simpa [eq] using known)
  | _ => exact valid k b known

theorem valid_bindings_run (r : Run edge o s t) (valid : ValidBindings o s) : ValidBindings o t := by
  induction r with
  | refl => exact valid
  | next r e ih => exact valid_bindings_step e ih

def Covered (s : State) : Prop := ∀ k i, s.inner.invitations k = some i →
  ∃ launch b, s.bindings launch = some b ∧ b.invitation = i

theorem covered_step (e : Step edge o s t) (cover : Covered s) : Covered t := by
  intro k i known
  cases e with
  | publish next b ready fresh actual registered pendingOnly durable =>
    change next.invitations k = some i at known
    rw [registered] at known
    by_cases eq : k = b.invitation.id
    · have same : b.invitation = i := by simpa [eq] using known
      exact ⟨b.invitation.ticket.launch,b,ready.2.1,same⟩
    · exact cover k i (by simpa [eq] using known)
  | advance next actual noPublish durable => exact cover k i (by simpa [noPublish] using known)
  | revoke next actual noPublish issuerFence durable => exact cover k i (by simpa [noPublish] using known)
  | bind new ready durable =>
    obtain ⟨launch,b,old,same⟩ := cover k i known
    have different : launch ≠ new.invitation.ticket.launch := by
      intro eq
      have no : s.bindings launch = none := by simpa [eq] using ready.2.1
      rw [old] at no
      cases no
    exact ⟨launch,b,by simpa [different] using old,same⟩
  | _ => exact cover k i known

theorem covered_run (r : Run edge o s t) (cover : Covered s) : Covered t := by
  induction r with
  | refl => exact cover
  | next r e ih => exact covered_step e ih

theorem root_origin (r : Run edge o s t) (empty : ∀ k, s.roots k = none) (known : t.roots k = some root) : o.rootAuthorized root := by
  induction r with
  | refl => rw [empty] at known; cases known
  | next r e ih =>
    cases e with
    | root new authorized fresh epoch canonical durable =>
      by_cases eq : k = new.template.ticket.launch
      · have same : new = root := by simpa [eq] using known
        simpa [← same] using authorized
      · exact ih (by simpa [eq] using known)
    | _ => exact ih known

theorem published_from_entitlement (r : Run edge o s t) (empty : ∀ k, s.roots k = none)
    (cover : Covered s) (valid : ValidBindings o s) (known : t.inner.invitations k = some i) :
    ∃ b : Binding, b.invitation = i ∧ o.rootAuthorized b.root ∧
      eraseKey i = b.root.template ∧ Credential o b.root i b.peer := by
  obtain ⟨launch,b,bound,same⟩ := covered_run r cover k i known
  obtain ⟨root,index,template,proof⟩ := valid_bindings_run r valid launch b bound
  subst i
  exact ⟨b,rfl,root_origin r empty root,template,proof⟩

def Joined (s : State) : Prop := ∀ k i, s.inner.invitations k = some i →
  s.published i.ticket.launch = some i

theorem joined_step (e : Step edge o s t) (joined : Joined s) : Joined t := by
  intro k i known
  cases e with
  | publish next b ready fresh actual registered pendingOnly durable =>
    change next.invitations k = some i at known
    rw [registered] at known
    by_cases eq : k = b.invitation.id
    · have same : b.invitation = i := by simpa [eq] using known
      subst i
      simp
    · have old : s.inner.invitations k = some i := by simpa [eq] using known
      have outcome := joined k i old
      have different : i.ticket.launch ≠ b.invitation.ticket.launch := by
        intro same
        have no := ready.2.2.2.1
        rw [same, no] at outcome
        cases outcome
      simpa [different] using outcome
  | advance next actual noPublish durable => exact joined k i (by simpa [noPublish] using known)
  | revoke next actual noPublish issuerFence durable => exact joined k i (by simpa [noPublish] using known)
  | _ => exact joined k i known

theorem new_publication_has_current_binding (e : Step edge o s t)
    (absent : s.inner.invitations k = none) (known : t.inner.invitations k = some i) :
    ∃ b : Binding, CanPublish o s b ∧ i = b.invitation ∧
      t.published i.ticket.launch = some i ∧ t.inner.inner = s.inner.inner := by
  cases e with
  | publish next b ready fresh actual registered pendingOnly durable =>
    change next.invitations k = some i at known
    rw [registered] at known
    by_cases eq : k = b.invitation.id
    · have same : b.invitation = i := by simpa [eq] using known
      subst i
      exact ⟨b,ready,rfl,by simp,pendingOnly⟩
    · have old : s.inner.invitations k = some i := by simpa [eq] using known
      rw [absent] at old
      cases old
  | advance next actual noPublish durable =>
    change next.invitations k = some i at known
    rw [noPublish,absent] at known
    cases known
  | revoke next actual noPublish issuerFence durable =>
    change next.invitations k = some i at known
    rw [noPublish,absent] at known
    cases known
  | _ => rw [absent] at known; cases known

theorem revision_monotone (e : Step edge o s t) : s.revision ≤ t.revision := by
  cases e <;> simp_all

theorem old_ticket_epoch_rejected {s t : State} {ticket : LlmIncarnationIssuance.Ticket}
    (old : ticket.epoch = s.inner.inner.epoch)
    (raised : t.inner.inner.epoch = s.inner.inner.epoch+1) : ticket.epoch ≠ t.inner.inner.epoch := by
  omega

theorem joined_run (r : Run edge o s t) (joined : Joined s) : Joined t := by
  induction r with
  | refl => exact joined
  | next r e ih => exact joined_step e ih

def OutcomeBound (s : State) : Prop := ∀ launch i, s.published launch = some i →
  s.inner.invitations i.id = some i

theorem outcome_bound_step (e : Step edge o s t) (bound : OutcomeBound s) : OutcomeBound t := by
  intro launch i known
  cases e with
  | publish next b ready fresh actual registered pendingOnly durable =>
    change next.invitations i.id = some i
    rw [registered]
    by_cases eq : launch = b.invitation.ticket.launch
    · have same : b.invitation = i := by simpa [eq] using known
      subst i
      simp
    · have old : s.published launch = some i := by simpa [eq] using known
      have registeredOld := bound launch i old
      have different : i.id ≠ b.invitation.id := by
        intro same
        rw [same,fresh] at registeredOld
        cases registeredOld
      simpa [different] using registeredOld
  | advance next actual noPublish durable => simpa [noPublish] using bound launch i known
  | revoke next actual noPublish issuerFence durable => simpa [noPublish] using bound launch i known
  | _ => exact bound launch i known

theorem outcome_bound_run (r : Run edge o s t) (bound : OutcomeBound s) : OutcomeBound t := by
  induction r with
  | refl => exact bound
  | next r e ih => exact outcome_bound_step e ih

theorem invitation_extend (r : LlmBootstrapInvitation.Run ie io a b)
    (prior : LlmBootstrapInvitation.Run ie io x a) : LlmBootstrapInvitation.Run ie io x b := by
  induction r with
  | refl => exact prior
  | next r e ih => exact .next ih e

theorem composition (r : Run edge o s t)
    (actual : ∀ a b, edge a b → LlmBootstrapInvitation.Run ie io a b)
    (prior : LlmBootstrapInvitation.Run ie io x s.inner) : LlmBootstrapInvitation.Run ie io x t.inner := by
  induction r with
  | refl => exact prior
  | next r e ih =>
    cases e with
    | publish next b ready fresh event registered pendingOnly durable => exact invitation_extend (actual _ _ event) ih
    | advance next event noPublish durable => exact invitation_extend (actual _ _ event) ih
    | revoke next event noPublish issuerFence durable => exact invitation_extend (actual _ _ event) ih
    | _ => exact ih

theorem original_reservation_once (safe : LlmAppendHandoff.Safe ho h)
    (run : Run edge owner start s)
    (publication : ∀ a b, edge a b → LlmBootstrapInvitation.Run ie io a b)
    (actual : ∀ a b, ie a b → LlmIncarnationIssuance.Run ao wo co ho fo jo semantic po o genesis a b)
    (priorCaller : LlmCallerCustody.Run ao wo co ho fo jo semantic po (LlmIncarnationIssuance.logicalOwner o.base) genesis callerStart start.inner.inner.current)
    (priorPublication : LlmCustodyPublication.Run ao wo co ho fo jo semantic po genesis (LlmCustodyPublication.initial custodyStart) callerStart.logical)
    (priorCustody : LlmSourceCustody.Run ao wo co ho fo jo (LlmCustodyPublication.logicalOwner semantic) genesis (LlmSourceCustody.initial (LlmSourceJoin.initial (LlmAdmissionFloor.initial h))) custodyStart)
    (priorAccount : LlmCheckpointTruncation.Run ao wo co genesis (LlmCheckpointTruncation.initial ao balances) h.logical) (key) :
    (LlmSourceJoin.account s.inner.inner.current.logical.authority.logical).authority.writes key ≤ 1 :=
  LlmBootstrapInvitation.original_reservation_once safe (composition run publication (.refl _)) actual priorCaller priorPublication priorCustody priorAccount key

theorem unknown_original_hold_retained (safe : LlmAppendHandoff.Safe ho h)
    (run : Run edge owner start s)
    (publication : ∀ a b, edge a b → LlmBootstrapInvitation.Run ie io a b)
    (actual : ∀ a b, ie a b → LlmIncarnationIssuance.Run ao wo co ho fo jo semantic po o genesis a b)
    (priorCaller : LlmCallerCustody.Run ao wo co ho fo jo semantic po (LlmIncarnationIssuance.logicalOwner o.base) genesis callerStart start.inner.inner.current)
    (priorPublication : LlmCustodyPublication.Run ao wo co ho fo jo semantic po genesis (LlmCustodyPublication.initial custodyStart) callerStart.logical)
    (priorCustody : LlmSourceCustody.Run ao wo co ho fo jo (LlmCustodyPublication.logicalOwner semantic) genesis (LlmSourceCustody.initial (LlmSourceJoin.initial (LlmAdmissionFloor.initial h))) custodyStart)
    (priorAccount : LlmCheckpointTruncation.Run ao wo co genesis (LlmCheckpointTruncation.initial ao balances) h.logical)
    (source : LlmExecutionReconciliation.State S) (unknownUsage : source.metered = false)
    (binding : ∀ tx state, tx.reservation = originalKey → ao.sourceReady tx state → LlmAccountCommit.OriginalReady originalKey attempt source tx) :
    (LlmSourceJoin.account s.inner.inner.current.logical.authority.logical).authority.reservations originalKey = none ∧
    (LlmSourceJoin.account s.inner.inner.current.logical.authority.logical).authority.holds originalKey = ao.bound originalKey :=
  LlmBootstrapInvitation.unknown_original_hold_retained safe (composition run publication (.refl _)) actual priorCaller priorPublication priorCustody priorAccount source unknownUsage binding

#print axioms root_retained
#print axioms binding_retained
#print axioms publication_retained
#print axioms binding_run
#print axioms no_replacement
#print axioms shared_identity_not_entitlement
#print axioms beneficiary_possession_required
#print axioms session_cannot_be_selected
#print axioms original_previous_preserved
#print axioms stale_epoch_cannot_publish
#print axioms stale_read_cannot_publish
#print axioms valid_bindings_step
#print axioms valid_bindings_run
#print axioms covered_step
#print axioms covered_run
#print axioms root_origin
#print axioms published_from_entitlement
#print axioms joined_step
#print axioms new_publication_has_current_binding
#print axioms revision_monotone
#print axioms old_ticket_epoch_rejected
#print axioms joined_run
#print axioms outcome_bound_step
#print axioms outcome_bound_run
#print axioms composition
#print axioms original_reservation_once
#print axioms unknown_original_hold_retained
end Weaver.LlmBeneficiaryRegistration
