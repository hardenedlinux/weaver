import AnchorBrokerCommit
namespace Weaver.AnchorReconfiguration
open Weaver.LogicalMessageAuthority (update)
inductive Scope where
  | stable (configuration : Nat)
  | joint (old next : Nat)
  deriving DecidableEq
structure QuorumSystem where
  accepts : List Nat → Prop
  intersects : ∀ left right, accepts left → accepts right → ∃ voter, voter ∈ left ∧ voter ∈ right
abbrev Family := Nat → QuorumSystem

def Authorized (family : Family) (scope : Scope) (oldQ newQ : List Nat) : Prop := match scope with
  | .stable cfg => (family cfg).accepts oldQ
  | .joint old next => (family old).accepts oldQ ∧ (family next).accepts newQ
inductive Body where
  | data (entry : Weaver.AnchorBrokerCommit.Entry)
  | enter (old next : Nat)
  | finish (old next : Nat)
  deriving DecidableEq
structure Record where
  root : Nat
  index : Nat
  revision : Nat
  term : Nat
  scope : Scope
  oldQ : List Nat
  newQ : List Nat
  body : Body
  deriving DecidableEq
structure Image where
  history : List Record
  journal : Weaver.GateConsumptionPersistence.Journal
  source : Weaver.SettlementAnchorRecovery.Image
  scope : Scope
  revision : Nat
structure State where
  base : Weaver.AnchorBrokerCommit.State := Weaver.AnchorBrokerCommit.initial
  scope : Scope := .stable 0
  revision : Nat := 0
  history : List Record := []
  installed : Nat → Option Image := fun _ => none
  admitted : Bool := true
  barrierRevision : Option Nat := none
  fenceRevision : Option Nat := none
  readRevision : Option Nat := none
  readHead : Nat := 0
  readTerm : Nat := 0
structure Store where
  certificateValid : Record → Prop
  imageValid : Nat → Image → Prop
  barrierBound : Nat → Scope → Nat → Nat → Nat → Prop
  readValid : Nat → Nat → Nat → Image → Prop

def initial : State := {}
def image (s : State) : Image := ⟨s.history,Weaver.GateConsumptionPersistence.journal s.base.base,Weaver.SettlementAnchorRecovery.recoveryView s.base.base.base.authority,s.scope,s.revision⟩
def Copies (s : State) (oldQ newQ : List Nat) : Prop := ∀ voter, voter ∈ oldQ ++ newQ → s.installed voter = some (image s)
def Header (root : Nat) (s : State) (r : Record) : Prop := r.root = root ∧ r.index = s.history.length ∧ r.revision = s.revision ∧ r.term = s.base.term

def BaseEmbeds (s : State) : Prop := ∀ e, s.base.log e.index = some e → ∃ r ∈ s.history, r.body = .data e
variable {c : Weaver.FiniteDomainMigration.Config} {m : Weaver.FiniteStreamManifest.Manifest c}
  {p : Weaver.WriterSettlementClosure.Profile c m} {lineage root namespaceId : Nat}
  {owner : Weaver.GateConsumptionPersistence.EvidenceOwner} {projectionStore : Weaver.AnchorBrokerCommit.RootOwner} {family : Family} {store : Store}

inductive Step (c : Weaver.FiniteDomainMigration.Config) (m : Weaver.FiniteStreamManifest.Manifest c)
    (p : Weaver.WriterSettlementClosure.Profile c m) (lineage root namespaceId : Nat)
    (owner : Weaver.GateConsumptionPersistence.EvidenceOwner) (projectionStore : Weaver.AnchorBrokerCommit.RootOwner) (family : Family) (store : Store) : State → State → Prop where
  | core (s next) (event : Weaver.AnchorBrokerCommit.Step c m p lineage root namespaceId owner projectionStore s.base next)
      (sameLog : next.log = s.base.log)
      (writer : next.gateOpen = s.base.gateOpen ∧ next.writerTerm = s.base.writerTerm ∧ next.writerEpoch = s.base.writerEpoch)
      (noOpen : next.active = true → s.base.active = true) :
      Step c m p lineage root namespaceId owner projectionStore family store s { s with
        base := next, admitted := s.admitted && next.active, readRevision := none
        barrierRevision := if next.term = s.base.term then s.barrierRevision else none
        fenceRevision := if next.term = s.base.term then s.fenceRevision else none }
  | commit (s next r e) (event : Weaver.AnchorBrokerCommit.Step c m p lineage root namespaceId owner projectionStore s.base next)
      (changed : next.log = update s.base.log s.base.head (some e))
      (index : e.index = s.base.head) (header : Header root s r) (body : r.body = .data e)
      (scope : r.scope = s.scope) (valid : store.certificateValid r)
      (quorums : Authorized family s.scope r.oldQ r.newQ) (copies : Copies s r.oldQ r.newQ)
      (admission : e.phase = .sealRoot ∨ e.phase = .grant ∨ e.phase = .burn → s.admitted = true ∧ ∃ cfg, s.scope = .stable cfg)
      (fence : e.phase = .fence → s.barrierRevision = some s.revision) :
      Step c m p lineage root namespaceId owner projectionStore family store s { s with
        base := next, history := s.history ++ [r], readRevision := none
        admitted := s.admitted && next.active
        fenceRevision := if e.phase = .fence then some s.revision else s.fenceRevision }
  | enterJoint (s r old) (current : s.scope = .stable old) (header : Header root s r)
      (scope : r.scope = .joint old (old+1)) (body : r.body = .enter old (old+1))
      (valid : store.certificateValid r) (quorums : Authorized family r.scope r.oldQ r.newQ)
      (copies : Copies s r.oldQ r.newQ) :
      Step c m p lineage root namespaceId owner projectionStore family store s { s with
        scope := .joint old (old+1), revision := s.revision+1, history := s.history ++ [r]
        admitted := false, barrierRevision := none, fenceRevision := none, readRevision := none }
  | finishJoint (s r old) (current : s.scope = .joint old (old+1)) (header : Header root s r)
      (scope : r.scope = s.scope) (body : r.body = .finish old (old+1))
      (valid : store.certificateValid r) (quorums : Authorized family r.scope r.oldQ r.newQ)
      (copies : Copies s r.oldQ r.newQ) :
      Step c m p lineage root namespaceId owner projectionStore family store s { s with
        scope := .stable (old+1), revision := s.revision+1, history := s.history ++ [r]
        admitted := false, barrierRevision := none, fenceRevision := none, readRevision := none }
  | install (s voter candidate) (same : candidate = image s) (valid : store.imageValid voter candidate) :
      Step c m p lineage root namespaceId owner projectionStore family store s { s with installed := update s.installed voter (some candidate) }
  | loseReplica (s voter) : Step c m p lineage root namespaceId owner projectionStore family store s { s with installed := update s.installed voter none }
  | isolate (s next) (event : Weaver.AnchorBrokerCommit.Step c m p lineage root namespaceId owner projectionStore s.base next)
      (sameLog : next.log = s.base.log) (closed : next.gateOpen = false)
      (actual : owner.barrierValid s.base.base.epoch)
      (bound : store.barrierBound root s.scope s.revision s.base.term next.writerEpoch)
      (writer : next.writerTerm = s.base.term ∧ next.writerEpoch = s.base.base.epoch + 1) :
      Step c m p lineage root namespaceId owner projectionStore family store s { s with
        base := next, admitted := false, barrierRevision := some s.revision, fenceRevision := none, readRevision := none }
  | readCurrent (s) (valid : projectionStore.currentReadValid root namespaceId s.base.term s.base.head)
      (bound : store.readValid root s.revision s.base.term (image s)) :
      Step c m p lineage root namespaceId owner projectionStore family store s { s with
        base := { s.base with readTerm := some s.base.term, readHead := s.base.head }
        readRevision := some s.revision, readHead := s.history.length, readTerm := s.base.term }
  | activate (s next cfg) (event : Weaver.AnchorBrokerCommit.Step c m p lineage root namespaceId owner projectionStore s.base next)
      (sameLog : next.log = s.base.log) (current : s.scope = .stable cfg)
      (barrier : s.barrierRevision = some s.revision) (fence : s.fenceRevision = some s.revision)
      (read : s.readRevision = some s.revision ∧ s.readHead = s.history.length ∧ s.readTerm = s.base.term)
      (opened : next.active = true ∧ next.gateOpen = true ∧ next.writerTerm = s.base.writerTerm ∧ next.writerEpoch = s.base.writerEpoch) :
      Step c m p lineage root namespaceId owner projectionStore family store s { s with base := next, admitted := true }

inductive Reachable (c : Weaver.FiniteDomainMigration.Config) (m : Weaver.FiniteStreamManifest.Manifest c)
    (p : Weaver.WriterSettlementClosure.Profile c m) (lineage root namespaceId : Nat)
    (owner : Weaver.GateConsumptionPersistence.EvidenceOwner) (projectionStore : Weaver.AnchorBrokerCommit.RootOwner) (family : Family) (store : Store) : State → Prop where
  | init : Reachable c m p lineage root namespaceId owner projectionStore family store initial
  | next : Reachable c m p lineage root namespaceId owner projectionStore family store s →
      Step c m p lineage root namespaceId owner projectionStore family store s t →
      Reachable c m p lineage root namespaceId owner projectionStore family store t

theorem projection (event : Step c m p lineage root namespaceId owner projectionStore family store s t) :
    s.base = t.base ∨ Weaver.AnchorBrokerCommit.Step c m p lineage root namespaceId owner projectionStore s.base t.base := by
  cases event with
  | core next event => exact .inr event
  | commit next r e event => exact .inr event
  | isolate next event => exact .inr event
  | activate next cfg event => exact .inr event
  | readCurrent valid bound => exact .inr (.readCurrent _ valid)
  | _ => exact .inl rfl

theorem base_reachable (h : Reachable c m p lineage root namespaceId owner projectionStore family store s) :
    Weaver.AnchorBrokerCommit.Reachable c m p lineage root namespaceId owner projectionStore s.base := by
  induction h with
  | init => exact .init
  | next _ event ih =>
    rcases projection event with same | source
    · simpa [← same] using ih
    · exact .next ih source

def Extends (before after : List Record) : Prop := ∃ suffix, after = before ++ suffix
theorem prefix_step (event : Step c m p lineage root namespaceId owner projectionStore family store s t) : Extends s.history t.history := by
  cases event with
  | commit next r => exact ⟨[r],rfl⟩
  | enterJoint r => exact ⟨[r],rfl⟩
  | finishJoint r => exact ⟨[r],rfl⟩
  | _ => exact ⟨[],by simp⟩
theorem prefix_member_preserved (event : Step c m p lineage root namespaceId owner projectionStore family store s t) (old : r ∈ s.history) : r ∈ t.history := by
  obtain ⟨suffix,same⟩ := prefix_step event
  rw [same]; exact List.mem_append_left suffix old

theorem base_embeds_initial : BaseEmbeds initial := by simp [BaseEmbeds,initial,Weaver.AnchorBrokerCommit.initial]
theorem base_embeds_step (inv : BaseEmbeds s) (event : Step c m p lineage root namespaceId owner projectionStore family store s t) : BaseEmbeds t := by
  have old (e) (present : s.base.log e.index = some e) : ∃ r ∈ t.history, r.body = .data e := by
    obtain ⟨r,member,body⟩ := inv e present
    exact ⟨r,prefix_member_preserved event member,body⟩
  cases event with
  | commit next r e source changed index header body =>
    intro entry present
    rw [changed] at present
    by_cases eq : entry.index = s.base.head
    · have same : entry = e := by simpa [update,eq] using present.symm
      subst entry; exact ⟨r,by simp,body⟩
    · exact old entry (by simpa [update,eq] using present)
  | core next source sameLog => intro e present; exact old e (by simpa [sameLog] using present)
  | isolate next source sameLog => intro e present; exact old e (by simpa [sameLog] using present)
  | activate next cfg source sameLog => intro e present; exact old e (by simpa [sameLog] using present)
  | _ => exact old

theorem reachable_base_embeds (h : Reachable c m p lineage root namespaceId owner projectionStore family store s) : BaseEmbeds s := by
  induction h with
  | init => exact base_embeds_initial
  | next _ event ih => exact base_embeds_step ih event

def Certified (family : Family) (store : Store) (r : Record) : Prop :=
  store.certificateValid r ∧ Authorized family r.scope r.oldQ r.newQ

def CertifiedHistory (family : Family) (store : Store) (s : State) : Prop :=
  ∀ r ∈ s.history, Certified family store r

theorem certified_history_step (inv : CertifiedHistory family store s)
    (event : Step c m p lineage root namespaceId owner projectionStore family store s t) : CertifiedHistory family store t := by
  have append (r) (qualified : Certified family store r) : ∀ entry ∈ s.history ++ [r], Certified family store entry := by
    intro entry member
    rcases List.mem_append.mp member with old | added
    · exact inv entry old
    · have same : entry = r := by simpa using added
      simpa [same] using qualified
  cases event with
  | commit next r e source changed index header body scope valid quorums =>
    exact append r ⟨valid,by simpa [scope] using quorums⟩
  | enterJoint r old current header scope body valid quorums => exact append r ⟨valid,quorums⟩
  | finishJoint r old current header scope body valid quorums => exact append r ⟨valid,quorums⟩
  | _ => exact inv

theorem every_committed_record_has_its_historical_quorums
    (h : Reachable c m p lineage root namespaceId owner projectionStore family store s) : CertifiedHistory family store s := by
  induction h with
  | init => simp [CertifiedHistory,initial]
  | next _ event ih => exact certified_history_step ih event

def AdmissionSafe (s : State) : Prop := s.admitted = true → ∃ cfg, s.scope = .stable cfg

theorem admission_initial : AdmissionSafe initial := by intro _; exact ⟨0,rfl⟩
theorem admission_step (inv : AdmissionSafe s) (event : Step c m p lineage root namespaceId owner projectionStore family store s t) : AdmissionSafe t := by
  cases event with
  | core =>
    intro admitted
    apply inv
    cases eq : s.admitted with
    | false => simp [eq] at admitted
    | true => rfl
  | commit =>
    intro admitted
    apply inv
    cases eq : s.admitted with
    | false => simp [eq] at admitted
    | true => rfl
  | enterJoint => simp [AdmissionSafe]
  | finishJoint => simp [AdmissionSafe]
  | isolate => simp [AdmissionSafe]
  | activate next cfg source same current => intro _; exact ⟨cfg,current⟩
  | _ => exact inv

theorem joint_configuration_cannot_open_new_admission (h : Reachable c m p lineage root namespaceId owner projectionStore family store s) : AdmissionSafe s := by
  induction h with
  | init => exact admission_initial
  | next _ event ih => exact admission_step ih event

def configurationFloor : Scope → Nat | .stable cfg => cfg | .joint old _ => old
theorem configuration_identity_never_rolls_back (event : Step c m p lineage root namespaceId owner projectionStore family store s t) :
    configurationFloor s.scope ≤ configurationFloor t.scope := by
  cases event with
  | enterJoint r old current => simp [current,configurationFloor]
  | finishJoint r old current => simp [current,configurationFloor]
  | _ => exact Nat.le_refl _

theorem old_and_joint_quorums_intersect (stable : Authorized family (.stable old) left [])
    (joint : Authorized family (.joint old next) oldQ newQ) : ∃ voter, voter ∈ left ∧ voter ∈ oldQ :=
  (family old).intersects left oldQ stable joint.1
theorem joint_and_new_quorums_intersect (joint : Authorized family (.joint old next) oldQ newQ)
    (stable : Authorized family (.stable next) right []) : ∃ voter, voter ∈ newQ ∧ voter ∈ right :=
  (family next).intersects newQ right joint.2 stable

theorem replacement_voters_copy_complete_deciding_image (copies : Copies s oldQ newQ) (member : voter ∈ newQ) :
    s.installed voter = some (image s) := copies voter (List.mem_append.mpr (.inr member))
theorem image_contains_deciding_projection (s : State) :
    (image s).history = s.history ∧ (image s).journal = Weaver.GateConsumptionPersistence.journal s.base.base ∧
    (image s).source = Weaver.SettlementAnchorRecovery.recoveryView s.base.base.base.authority := ⟨rfl,rfl,rfl⟩

theorem membership_revision_monotone (event : Step c m p lineage root namespaceId owner projectionStore family store s t) : s.revision ≤ t.revision := by
  cases event <;> simp

theorem one_original_consumption_and_application (h : Reachable c m p lineage root namespaceId owner projectionStore family store s) (k) :
    s.base.base.burnCount k ≤ 1 ∧ s.base.dispatchCount k ≤ 1 ∧ s.base.base.base.authority.writes k ≤ 1 :=
  ⟨(Weaver.AnchorBrokerCommit.one_canonical_grant_and_consumption (base_reachable h) k).2,Weaver.AnchorBrokerCommit.no_duplicate_dispatch_or_application (base_reachable h) k⟩
theorem original_shared_budget_conserved (h : Reachable c m p lineage root namespaceId owner projectionStore family store s) (b) :
    Weaver.SettlementAnchorRecovery.accountMaterialized c s.base.base.base b ≤ Weaver.FiniteDomainMigration.booked c s.base.base.base.authority.source.base.base.control.journal.head.payload b ∧
    Weaver.SettlementAnchorRecovery.accountMaterialized c s.base.base.base b ≤ c.capacity b := Weaver.AnchorBrokerCommit.original_shared_budget_conserved (base_reachable h) b
theorem original_unknown_reservation_retained (h : Reachable c m p lineage root namespaceId owner projectionStore family store s) (sealed : s.base.base.seals k = some a) :
    (s.base.base.base.authority.source.base.base.control.journal.head.payload.messages k).reserved = true := Weaver.AnchorBrokerCommit.held_unknown_keeps_original_reservation (base_reachable h) sealed

#print axioms base_reachable
#print axioms reachable_base_embeds
#print axioms every_committed_record_has_its_historical_quorums
#print axioms joint_configuration_cannot_open_new_admission
#print axioms configuration_identity_never_rolls_back
#print axioms old_and_joint_quorums_intersect
#print axioms joint_and_new_quorums_intersect
#print axioms replacement_voters_copy_complete_deciding_image
#print axioms image_contains_deciding_projection
#print axioms membership_revision_monotone
#print axioms one_original_consumption_and_application
#print axioms original_shared_budget_conserved
#print axioms original_unknown_reservation_retained
end Weaver.AnchorReconfiguration
