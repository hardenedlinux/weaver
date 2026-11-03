-- SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
--
-- SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

import GateConsumptionPersistence
namespace Weaver.AnchorBrokerCommit
open Weaver.LogicalMessageAuthority (update)
abbrev Permit := Weaver.SettlementAnchorRecovery.Permit
inductive Phase where
  | sealRoot | grant | burn | result | fence
  deriving DecidableEq
structure Entry where
  root : Nat
  config : Nat
  term : Nat
  index : Nat
  phase : Phase
  key : Nat
  epoch : Nat
  permit : Permit
  deriving DecidableEq
structure Dispatch where
  entry : Entry
  observedTerm : Nat
  observedEpoch : Nat
structure RootOwner where
  commitValid : Entry → Prop
  currentReadValid : Nat → Nat → Nat → Nat → Prop
  barrierBound : Nat → Nat → Nat → Nat → Prop
structure State where
  base : Weaver.GateConsumptionPersistence.State := Weaver.GateConsumptionPersistence.initial
  term : Nat := 0
  head : Nat := 0
  log : Nat → Option Entry := fun _ => none
  proposals : List Entry := []
  replies : List Entry := []
  grants : Nat → Option Entry := fun _ => none
  burns : Nat → Option Entry := fun _ => none
  dispatches : Nat → Option Dispatch := fun _ => none
  dispatchCount : Nat → Nat := fun _ => 0
  readTerm : Option Nat := none
  readHead : Nat := 0
  fencedTerm : Option Nat := none
  writerTerm : Nat := 0
  writerEpoch : Nat := 0
  gateOpen : Bool := true
  barrierTerm : Option Nat := none
  active : Bool := true

def initial : State := {}
variable {c : Weaver.FiniteDomainMigration.Config} {m : Weaver.FiniteStreamManifest.Manifest c}
  {p : Weaver.WriterSettlementClosure.Profile c m} {lineage root config : Nat}
  {owner : Weaver.GateConsumptionPersistence.EvidenceOwner} {store : RootOwner}
def Qualified (store : RootOwner) (s : State) (e : Entry) : Prop :=
  s.log e.index = some e ∧ store.commitValid e

def Binds (s : Weaver.GateConsumptionPersistence.State) (e : Entry) : Prop := match e.phase with
  | .sealRoot => s.seals e.key = some e.permit
  | .grant => s.grants e.key = some e.epoch ∧ s.seals e.key = some e.permit
  | .burn => s.burns e.key = some ⟨e.permit,e.epoch⟩
  | .result => s.results e.key = some e.permit
  | .fence => e.epoch ≤ s.epoch

def Describes (s t : Weaver.GateConsumptionPersistence.State) (e : Entry) : Prop :=
  Binds t e ∧ t.base.authority.outcomes = s.base.authority.outcomes ∧
    match e.phase with
    | .sealRoot => s.seals e.key = none
    | .grant => s.grants e.key = none
    | .burn => s.burns e.key = none
    | .result => s.results e.key = none
    | .fence => t.epoch = s.epoch + 1

inductive Step (c : Weaver.FiniteDomainMigration.Config) (m : Weaver.FiniteStreamManifest.Manifest c)
    (p : Weaver.WriterSettlementClosure.Profile c m) (lineage root config : Nat) (owner : Weaver.GateConsumptionPersistence.EvidenceOwner) (store : RootOwner) : State → State → Prop where
  | propose (s e) : Step c m p lineage root config owner store s { s with proposals := e :: s.proposals }
  | commit (s next e) (proposed : e ∈ s.proposals)
      (identity : e.root = root ∧ e.config = config ∧ e.term = s.term ∧ e.index = s.head)
      (fresh : s.log s.head = none) (valid : store.commitValid e)
      (event : Weaver.GateConsumptionPersistence.Step c m p lineage owner s.base next) (describes : Describes s.base next e)
      (epoch : e.epoch = next.epoch)
      (allowed : e.phase = .fence ∨ e.phase = .result ∨ s.active = true)
      (held : e.phase = .burn → ∃ grant, s.grants e.key = some grant ∧ grant.epoch = s.base.epoch)
      (barrier : e.phase = .fence → s.barrierTerm = some s.term ∧ s.gateOpen = false ∧ s.writerTerm = s.term ∧ s.writerEpoch = next.epoch) :
      Step c m p lineage root config owner store s { s with
        base := next
        log := update s.log s.head (some e), head := s.head + 1, replies := e :: s.replies
        fencedTerm := if e.phase = .fence then some s.term else s.fencedTerm }
  | acknowledgeGrant (s e) (original : e ∈ s.replies) (qualified : Qualified store s e)
      (phase : e.phase = .grant) (current : s.gateOpen = true ∧ e.term = s.writerTerm ∧ e.epoch = s.writerEpoch)
      (fresh : s.grants e.key = none) :
      Step c m p lineage root config owner store s { s with grants := update s.grants e.key (some e) }
  | acknowledgeBurn (s e) (original : e ∈ s.replies) (qualified : Qualified store s e)
      (phase : e.phase = .burn) (current : s.gateOpen = true ∧ e.term = s.writerTerm ∧ e.epoch = s.writerEpoch)
      (fresh : s.burns e.key = none) :
      Step c m p lineage root config owner store s { s with burns := update s.burns e.key (some e) }
  | dispatch (s k e) (ack : s.burns k = some e) (qualified : Qualified store s e)
      (phase : e.phase = .burn) (key : e.key = k)
      (current : s.gateOpen = true ∧ e.term = s.writerTerm ∧ e.epoch = s.writerEpoch)
      (fresh : s.dispatches k = none) :
      Step c m p lineage root config owner store s { s with
        dispatches := update s.dispatches k (some ⟨e,s.writerTerm,s.writerEpoch⟩)
        dispatchCount := update s.dispatchCount k (s.dispatchCount k + 1) }
  | localEvent (s next) (event : Weaver.GateConsumptionPersistence.Step c m p lineage owner s.base next)
      (rootUnchanged : Weaver.GateConsumptionPersistence.journal next = Weaver.GateConsumptionPersistence.journal s.base)
      (fenceUnchanged : next.needsFence = s.base.needsFence)
      (actual : ∀ k a, next.base.authority.outcomes k = some a →
        s.base.base.authority.outcomes k = some a ∨ ∃ d, s.dispatches k = some d) :
      Step c m p lineage root config owner store s { s with base := next }
  | changeLeader (s) : Step c m p lineage root config owner store s { s with
      base := { s.base with base := { s.base.base with online := false }, needsFence := true }
      term := s.term + 1, active := false, readTerm := none, fencedTerm := none, barrierTerm := none }
  | loseJournal (s image) : Step c m p lineage root config owner store s { s with
      base := { s.base with base := { s.base.base with online := false }, disk := image, needsFence := true }
      active := false, readTerm := none, fencedTerm := none, barrierTerm := none, replies := [] }
  | isolateWriter (s) (valid : Weaver.GateConsumptionPersistence.EvidenceOwner.barrierValid owner s.base.epoch)
      (binding : store.barrierBound root config s.term (s.base.epoch + 1))
      (monotone : s.writerEpoch ≤ s.base.epoch + 1) :
      Step c m p lineage root config owner store s { s with
        gateOpen := false
        writerTerm := s.term, writerEpoch := s.base.epoch + 1, barrierTerm := some s.term }
  | readCurrent (s) (valid : store.currentReadValid root config s.term s.head) :
      Step c m p lineage root config owner store s { s with readTerm := some s.term, readHead := s.head }
  | activate (s) (read : s.readTerm = some s.term ∧ s.readHead = s.head)
      (fenced : s.fencedTerm = some s.term)
      (barrier : s.barrierTerm = some s.term ∧ s.writerTerm = s.term ∧ s.writerEpoch = s.base.epoch) (ready : Weaver.GateConsumptionPersistence.Ready s.base)
      (recovered : Weaver.SettlementAnchorRecovery.Recovered s.base.base) :
      Step c m p lineage root config owner store s { s with active := true, gateOpen := true }
  | dropReply (s e) : Step c m p lineage root config owner store s { s with replies := s.replies.filter (fun x => x != e) }

inductive Reachable (c : Weaver.FiniteDomainMigration.Config) (m : Weaver.FiniteStreamManifest.Manifest c)
    (p : Weaver.WriterSettlementClosure.Profile c m) (lineage root config : Nat) (owner : Weaver.GateConsumptionPersistence.EvidenceOwner) (store : RootOwner) : State → Prop where
  | init : Reachable c m p lineage root config owner store initial
  | next : Reachable c m p lineage root config owner store s → Step c m p lineage root config owner store s t → Reachable c m p lineage root config owner store t

theorem projection (event : Step c m p lineage root config owner store s t) : Weaver.GateConsumptionPersistence.Step c m p lineage owner s.base t.base := by
  cases event with
  | commit next e proposed identity fresh valid event => exact event
  | localEvent next event => exact event
  | changeLeader => exact .loseJournal _ _
  | loseJournal image => exact .loseJournal _ _
  | _ => exact .lostReply _
theorem base_reachable (h : Reachable c m p lineage root config owner store s) : Weaver.GateConsumptionPersistence.Reachable c m p lineage owner s.base := by
  induction h with
  | init => exact .init
  | next _ event ih => exact .next ih (projection event)
theorem entry_immutable (event : Step c m p lineage root config owner store s t) (old : s.log i = some e) : t.log i = some e := by
  cases event with
  | commit next entry proposed identity fresh => by_cases eq : i = s.head <;> simp_all [update]
  | _ => exact old
theorem dispatch_immutable (event : Step c m p lineage root config owner store s t) (old : s.dispatches k = some d) : t.dispatches k = some d := by
  cases event with
  | dispatch j => by_cases eq : k = j <;> simp_all [update]
  | _ => exact old
theorem binds_preserved (event : Weaver.GateConsumptionPersistence.Step c m p lineage owner s t) (bound : Binds s e) : Binds t e := by
  cases phase : e.phase <;> simp only [Binds,phase] at *
  · exact Weaver.GateConsumptionPersistence.seal_immutable event bound
  · exact ⟨Weaver.GateConsumptionPersistence.grant_immutable event bound.1,Weaver.GateConsumptionPersistence.seal_immutable event bound.2⟩
  · exact Weaver.GateConsumptionPersistence.burn_immutable event bound
  · exact Weaver.GateConsumptionPersistence.result_immutable event bound
  · exact Nat.le_trans bound (Weaver.GateConsumptionPersistence.epoch_monotone event)

structure Invariant (root config : Nat) (store : RootOwner) (s : State) : Prop where
  log : ∀ i e, s.log i = some e → e.index = i ∧ e.root = root ∧ e.config = config ∧ store.commitValid e ∧ Binds s.base e
  grants : ∀ k e, s.grants k = some e → Qualified store s e ∧ e.phase = .grant
  burns : ∀ k e, s.burns k = some e → Qualified store s e ∧ e.phase = .burn
  dispatches : ∀ k d, s.dispatches k = some d → Qualified store s d.entry ∧ d.entry.phase = .burn ∧
    d.entry.key = k ∧ d.entry.term = d.observedTerm ∧ d.entry.epoch = d.observedEpoch
  actual : ∀ k a, s.base.base.authority.outcomes k = some a → ∃ d, s.dispatches k = some d
  counts : Weaver.SettlementAnchorRecovery.CountSafe s.dispatches s.dispatchCount

theorem initial_invariant : Invariant root config store initial := by
  refine ⟨?_,?_,?_,?_,?_,?_⟩ <;> simp [initial,Weaver.GateConsumptionPersistence.initial,Weaver.SettlementAnchorRecovery.initial,Weaver.SettlementAnchorRecovery.CountSafe]

theorem invariant_step (inv : Invariant root config store s) (event : Step c m p lineage root config owner store s t) : Invariant root config store t := by
  have qualified (e) (old : Qualified store s e) : Qualified store t e := ⟨entry_immutable event old.1,old.2⟩
  have logs (i e) (old : s.log i = some e) := inv.log i e old
  have grants (k e) (old : s.grants k = some e) : Qualified store t e ∧ e.phase = .grant :=
    ⟨qualified e (inv.grants k e old).1,(inv.grants k e old).2⟩
  have burns (k e) (old : s.burns k = some e) : Qualified store t e ∧ e.phase = .burn :=
    ⟨qualified e (inv.burns k e old).1,(inv.burns k e old).2⟩
  have dispatches (k d) (old : s.dispatches k = some d) : Qualified store t d.entry ∧ d.entry.phase = .burn ∧
      d.entry.key = k ∧ d.entry.term = d.observedTerm ∧ d.entry.epoch = d.observedEpoch := by
    obtain ⟨q,rest⟩ := inv.dispatches k d old
    exact ⟨qualified d.entry q,rest⟩
  have actual (k a) (old : s.base.base.authority.outcomes k = some a) : ∃ d, t.dispatches k = some d := by
    obtain ⟨d,present⟩ := inv.actual k a old
    exact ⟨d,dispatch_immutable event present⟩
  have logOld (i e) (old : s.log i = some e) : e.index = i ∧ e.root = root ∧ e.config = config ∧ store.commitValid e ∧ Binds t.base e := by
    obtain ⟨index,identity,config,valid,bound⟩ := logs i e old
    exact ⟨index,identity,config,valid,binds_preserved (projection event) bound⟩
  cases event with
  | commit next e proposed identity fresh valid source describes epoch allowed held barrier =>
    refine ⟨?_,grants,burns,dispatches,?_,inv.counts⟩
    · intro i entry record; by_cases eq : i = s.head
      · subst i; have same : entry = e := by simpa [update] using record.symm
        subst entry; exact ⟨identity.2.2.2,identity.1,identity.2.1,valid,describes.1⟩
      · exact logOld i entry (by simpa [update,eq] using record)
    · intro k a record; exact actual k a (by simpa [describes.2.1] using record)
  | acknowledgeGrant e original q phase current fresh =>
    refine ⟨logOld,?_,burns,dispatches,actual,inv.counts⟩
    intro k entry record; by_cases eq : k = e.key
    · subst k; have same : entry = e := by simpa [update] using record.symm
      subst entry; exact ⟨q,phase⟩
    · exact grants k entry (by simpa [update,eq] using record)
  | acknowledgeBurn e original q phase current fresh =>
    refine ⟨logOld,grants,?_,dispatches,actual,inv.counts⟩
    intro k entry record; by_cases eq : k = e.key
    · subst k; have same : entry = e := by simpa [update] using record.symm
      subst entry; exact ⟨q,phase⟩
    · exact burns k entry (by simpa [update,eq] using record)
  | dispatch k e ack q phase key current fresh =>
    refine ⟨logOld,grants,burns,?_,actual,Weaver.SettlementAnchorRecovery.count_insert inv.counts fresh⟩
    intro j d record; by_cases eq : j = k
    · subst j; have same : d = ⟨e,s.writerTerm,s.writerEpoch⟩ := by simpa [update] using record.symm
      subst d; exact ⟨q,phase,key,current.2.1,current.2.2⟩
    · exact dispatches j d (by simpa [update,eq] using record)
  | localEvent next source rootUnchanged fenceUnchanged covered =>
    refine ⟨logOld,grants,burns,dispatches,?_,inv.counts⟩
    intro k a record
    rcases covered k a record with old | submitted
    · exact actual k a old
    · exact submitted
  | _ => exact ⟨logOld,grants,burns,dispatches,actual,inv.counts⟩

theorem reachable_invariant (h : Reachable c m p lineage root config owner store s) : Invariant root config store s := by
  induction h with
  | init => exact initial_invariant
  | next _ event ih => exact invariant_step ih event

theorem qualified_prefix_is_single_valued (a : Qualified store s left) (b : Qualified store s right) (index : left.index = right.index) : left = right := by
  have equal := a.1.symm.trans (index ▸ b.1)
  exact Option.some.inj equal

theorem actual_application_requires_qualified_original_dispatch (h : Reachable c m p lineage root config owner store s)
    (applied : s.base.base.authority.outcomes k = some a) :
    ∃ d, s.dispatches k = some d ∧ Qualified store s d.entry ∧ d.entry.phase = .burn ∧
      d.entry.key = k ∧ d.entry.term = d.observedTerm ∧ d.entry.epoch = d.observedEpoch ∧
      s.base.burns k = some ⟨a,d.entry.epoch⟩ := by
  have inv := reachable_invariant h
  obtain ⟨d,record⟩ := inv.actual k a applied
  obtain ⟨q,phase,key,term,epoch⟩ := inv.dispatches k d record
  have bound := (inv.log d.entry.index d.entry q.1).2.2.2.2
  have original : s.base.burns k = some ⟨d.entry.permit,d.entry.epoch⟩ := by simpa [Binds,phase,key] using bound
  obtain ⟨burn,stored,same⟩ := (Weaver.GateConsumptionPersistence.reachable_invariant (base_reachable h)).outcomes k a applied
  have equal : burn = ⟨d.entry.permit,d.entry.epoch⟩ := Option.some.inj (stored.symm.trans original)
  have permit : d.entry.permit = a := by simpa [equal] using same
  exact ⟨d,record,q,phase,key,term,epoch,by simpa [permit] using original⟩

theorem one_canonical_grant_and_consumption (h : Reachable c m p lineage root config owner store s) (k) :
    s.base.grantCount k ≤ 1 ∧ s.base.burnCount k ≤ 1 :=
  Weaver.GateConsumptionPersistence.no_regrant_or_reburn (base_reachable h) k

theorem qualified_burns_preserve_original_body (h : Reachable c m p lineage root config owner store s)
    (left : Qualified store s a) (right : Qualified store s b)
    (aBurn : a.phase = .burn) (bBurn : b.phase = .burn) (key : a.key = b.key) :
    a.permit = b.permit ∧ a.epoch = b.epoch := by
  have inv := reachable_invariant h
  have ab := (inv.log a.index a left.1).2.2.2.2
  have bb := (inv.log b.index b right.1).2.2.2.2
  have ar : s.base.burns a.key = some ⟨a.permit,a.epoch⟩ := by simpa [Binds,aBurn] using ab
  have br : s.base.burns a.key = some ⟨b.permit,b.epoch⟩ := by simpa [Binds,bBurn,← key] using bb
  have same := Option.some.inj (ar.symm.trans br)
  exact ⟨congrArg Weaver.GateConsumptionPersistence.Burn.permit same,congrArg Weaver.GateConsumptionPersistence.Burn.epoch same⟩

theorem no_duplicate_dispatch_or_application (h : Reachable c m p lineage root config owner store s) (k) :
    s.dispatchCount k ≤ 1 ∧ s.base.base.authority.writes k ≤ 1 :=
  ⟨((reachable_invariant h).counts k).1,Weaver.GateConsumptionPersistence.actual_account_application_at_most_once (base_reachable h) k⟩
theorem original_shared_budget_conserved (h : Reachable c m p lineage root config owner store s) (b) :
    Weaver.SettlementAnchorRecovery.accountMaterialized c s.base.base b ≤ Weaver.FiniteDomainMigration.booked c s.base.base.authority.source.base.base.control.journal.head.payload b ∧
    Weaver.SettlementAnchorRecovery.accountMaterialized c s.base.base b ≤ c.capacity b := Weaver.GateConsumptionPersistence.end_to_end_account_conservation (base_reachable h) b

theorem change_leader_does_not_erase_original_execution (s : State) :
    let t := { s with
      base := { s.base with base := { s.base.base with online := false }, needsFence := true }
      term := s.term + 1, active := false, readTerm := none, fencedTerm := none, barrierTerm := none }
    t.log = s.log ∧ t.grants = s.grants ∧ t.burns = s.burns ∧ t.dispatches = s.dispatches := ⟨rfl,rfl,rfl,rfl⟩
theorem root_term_monotone (event : Step c m p lineage root config owner store s t) : s.term ≤ t.term := by
  cases event <;> simp

theorem actual_writer_epoch_monotone (event : Step c m p lineage root config owner store s t) : s.writerEpoch ≤ t.writerEpoch := by
  cases event with
  | isolateWriter valid binding monotone => exact monotone
  | _ => exact Nat.le_refl _

def DispatchAdmissible (s : State) (e : Entry) : Prop :=
  s.gateOpen = true ∧ e.term = s.writerTerm ∧ e.epoch = s.writerEpoch

theorem actual_barrier_blocks_held_permission (s : State) (e : Entry) :
    ¬ DispatchAdmissible { s with
      gateOpen := false, writerTerm := s.term, writerEpoch := s.base.epoch + 1
      barrierTerm := some s.term } e := by
  simp [DispatchAdmissible]

theorem old_epoch_cannot_dispatch_after_reactivation (s : State) (e : Entry) (old : e.epoch ≠ s.writerEpoch) :
    ¬ DispatchAdmissible { s with active := true, gateOpen := true } e := by
  intro admissible; exact old admissible.2.2

theorem application_has_original_usage (h : Reachable c m p lineage root config owner store s)
    (record : s.base.base.authority.outcomes k = some a) :
    a.request.key = k ∧ a.request.lineage = lineage ∧ s.base.base.authority.source.settlement k = some a.request.usage :=
  Weaver.SettlementAnchorRecovery.application_has_original_settlement (Weaver.GateConsumptionPersistence.base_reachable (base_reachable h)) record

theorem held_unknown_keeps_original_reservation (h : Reachable c m p lineage root config owner store s)
    (sealed : s.base.seals k = some a) :
    (s.base.base.authority.source.base.base.control.journal.head.payload.messages k).reserved = true :=
  Weaver.GateConsumptionPersistence.sealed_unknown_retains_original_reservation (base_reachable h) sealed

#print axioms reachable_invariant
#print axioms qualified_prefix_is_single_valued
#print axioms actual_application_requires_qualified_original_dispatch
#print axioms one_canonical_grant_and_consumption
#print axioms qualified_burns_preserve_original_body
#print axioms no_duplicate_dispatch_or_application
#print axioms original_shared_budget_conserved
#print axioms change_leader_does_not_erase_original_execution
#print axioms root_term_monotone
#print axioms actual_writer_epoch_monotone
#print axioms actual_barrier_blocks_held_permission
#print axioms old_epoch_cannot_dispatch_after_reactivation
#print axioms application_has_original_usage
#print axioms held_unknown_keeps_original_reservation
end Weaver.AnchorBrokerCommit
