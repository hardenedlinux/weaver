import DeviceIsolationRecovery
namespace Weaver.FloorIntentDecision

abbrev DeviceState := Weaver.DeviceIsolationRecovery.State
structure Intent where
  id : Nat
  cut : Weaver.DeviceIsolationRecovery.Cut
  worker : Nat
  fence : Nat
  deriving DecidableEq
inductive Outcome where | committed | fenced deriving DecidableEq
structure Resolution where
  intent : Intent
  outcome : Outcome
  deriving DecidableEq
structure DecisionOwner where
  readValid : List Resolution → Nat → Resolution → Prop

structure State where
  base : DeviceState := Weaver.DeviceIsolationRecovery.initial
  worker : Nat := 0
  fence : Nat := 0
  accepted : List Intent := []
  decisions : List Resolution := []
  slot : Option Intent := none
  observed : Option Resolution := none

def initial : State := {}
def Committed (s : State) (i : Intent) : Prop := ⟨i,.committed⟩ ∈ s.decisions
def Conserved (s : State) : Prop := ∀ i ∈ s.accepted, Committed s i ∨ s.slot = some i
def Unique (s : State) : Prop := ∀ a ∈ s.decisions, ∀ b ∈ s.decisions, a.intent = b.intent → a = b
-- Delegation cannot hide a new cut, floor decision, reset or physical requalification.
def Frame (s t : DeviceState) : Prop :=
  t.pendingFloor = s.pendingFloor ∧ t.journal = s.journal ∧ t.captured = s.captured ∧
  t.serial = s.serial ∧ t.device = s.device ∧ t.driver = s.driver ∧ t.profile = s.profile ∧ t.base.epoch = s.base.epoch

inductive Step (baseStep : DeviceState → DeviceState → Prop) (decisionOwner : DecisionOwner) : State → State → Prop where
  | delegate (s next) (source : baseStep s.base next) (frame : Frame s.base next)
      (gate : next.base.enabled = true → s.slot = none) : Step baseStep decisionOwner s {s with base := next}
  | sealCut (s next) (source : baseStep s.base next) (free : s.slot = none)
      (journal : next.journal = s.base.journal) (pending : next.pendingFloor = s.base.pendingFloor)
      (cut : ∃ cut, next.captured = some cut ∧ cut.serial = s.base.serial + 1)
      (sameHardware : next.device = s.base.device ∧ next.driver = s.base.driver ∧ next.profile = s.base.profile ∧ next.base.epoch = s.base.base.epoch) :
      Step baseStep decisionOwner s {s with base := next}
  | accept (s next i) (source : baseStep s.base next) (free : s.slot = none)
      (identity : i.id = s.accepted.length ∧ i.worker = s.worker ∧ i.fence = s.fence)
      (fresh : i ∉ s.accepted) (undecided : ∀ r ∈ s.decisions, r.intent ≠ i)
      (effect : next.pendingFloor = some i.cut ∧ next.journal = s.base.journal ∧ next.base.enabled = false) :
      Step baseStep decisionOwner s {s with base := next, accepted := s.accepted ++ [i], slot := some i, observed := none}
  | commit (s next i) (source : baseStep s.base next) (held : s.slot = some i)
      (current : i.worker = s.worker ∧ i.fence = s.fence)
      (undecided : ∀ r ∈ s.decisions, r.intent ≠ i)
      (effect : next.journal = s.base.journal ++ [i.cut] ∧ next.pendingFloor = none ∧ next.base.enabled = false) :
      Step baseStep decisionOwner s {s with base := next, decisions := s.decisions ++ [⟨i,.committed⟩], observed := none}
  | fencePending (s next i) (source : baseStep s.base next) (held : s.slot = some i)
      (undecided : ∀ r ∈ s.decisions, r.intent ≠ i)
      (effect : next.journal = s.base.journal ∧ next.pendingFloor = s.base.pendingFloor ∧ next.base.enabled = false ∧ next.certified = none ∧ next.captured = none ∧ next.serial = s.base.serial + 1) :
      Step baseStep decisionOwner s {s with
        base := next, worker := s.worker + 1, fence := s.fence + 1, decisions := s.decisions ++ [⟨i,.fenced⟩], observed := none}
  | fenceResolved (s next) (source : baseStep s.base next)
      (resolved : ∀ i, s.slot = some i → ∃ r ∈ s.decisions, r.intent = i)
      (effect : next.journal = s.base.journal ∧ next.pendingFloor = s.base.pendingFloor ∧ next.base.enabled = false ∧ next.certified = none ∧ next.captured = none ∧ next.serial = s.base.serial + 1) :
      Step baseStep decisionOwner s {s with base := next, worker := s.worker + 1, fence := s.fence + 1, observed := none}
  | observe (s r history worker) (held : s.slot = some r.intent) (member : r ∈ s.decisions)
      (fullPrefix : history = s.decisions) (session : worker = s.worker)
      (authentic : decisionOwner.readValid history worker r) :
      Step baseStep decisionOwner s {s with observed := some r}
  | acknowledge (s i) (held : s.slot = some i) (seen : s.observed = some ⟨i,.committed⟩)
      (durable : Committed s i) : Step baseStep decisionOwner s {s with slot := none, observed := none}
  | loseResponse (s) : Step baseStep decisionOwner s s

inductive Run (baseStep : DeviceState → DeviceState → Prop) (decisionOwner : DecisionOwner) : State → State → Prop where
  | refl (s) : Run baseStep decisionOwner s s
  | next : Run baseStep decisionOwner a b → Step baseStep decisionOwner b c → Run baseStep decisionOwner a c

variable {decisionOwner : DecisionOwner}

theorem decisions_never_roll_back (e : Step baseStep decisionOwner s t) : s.decisions <+: t.decisions := by
  cases e with
  | commit => exact List.prefix_append _ _
  | fencePending => exact List.prefix_append _ _
  | _ => exact List.prefix_refl _

theorem accepted_intents_never_disappear (e : Step baseStep decisionOwner s t) : s.accepted <+: t.accepted := by
  cases e with
  | accept => exact List.prefix_append _ _
  | _ => exact List.prefix_refl _

theorem commitment_survives (e : Step baseStep decisionOwner s t) (old : Committed s i) : Committed t i :=
  (decisions_never_roll_back e).subset old

theorem conservation_step (h : Conserved s) (e : Step baseStep decisionOwner s t) : Conserved t := by
  have persists : ∀ {j}, Committed s j → Committed t j := fun old => commitment_survives e old
  cases e with
  | accept next i source free identity fresh undecided effect =>
    intro j member
    rcases List.mem_append.mp member with old | new
    · rcases h j old with done | held
      · exact .inl done
      · rw [free] at held; contradiction
    · have same : j = i := by simpa using new
      subst j; exact .inr rfl
  | commit next i source held current undecided effect =>
    intro j member
    rcases h j member with done | pending
    · exact .inl (persists done)
    · have same : j = i := Option.some.inj (pending.symm.trans held)
      subst j
      exact .inl (by simp [Committed])
  | acknowledge i held seen durable =>
    intro j member
    rcases h j member with done | pending
    · exact .inl done
    · have same : j = i := Option.some.inj (pending.symm.trans held)
      subst j; exact .inl durable
  | fencePending next i source held undecided effect =>
    intro j member
    rcases h j member with done | pending
    · exact .inl (persists done)
    · exact .inr pending
  | _ => exact h

theorem append_fresh_decision_unique (h : Unique s) (fresh : ∀ r ∈ s.decisions, r.intent ≠ i) (outcome : Outcome) :
    Unique {s with decisions := s.decisions ++ [⟨i,outcome⟩]} := by
  intro a ha b hb eq
  rcases List.mem_append.mp ha with ha | ha
  · rcases List.mem_append.mp hb with hb | hb
    · exact h a ha b hb eq
    · have same : b = ⟨i,outcome⟩ := by simpa using hb
      subst b; exact False.elim (fresh a ha eq)
  · have same : a = ⟨i,outcome⟩ := by simpa using ha
    subst a
    rcases List.mem_append.mp hb with hb | hb
    · exact False.elim (fresh b hb eq.symm)
    · have same : b = ⟨i,outcome⟩ := by simpa using hb
      exact same.symm

theorem unique_step (h : Unique s) (e : Step baseStep decisionOwner s t) : Unique t := by
  cases e with
  | commit next i source held current undecided effect => exact append_fresh_decision_unique h undecided .committed
  | fencePending next i source held undecided effect => exact append_fresh_decision_unique h undecided .fenced
  | _ => exact h

theorem initialized_conservation (events : Run baseStep decisionOwner initial s) : Conserved s := by
  induction events with
  | refl => simp [Conserved,initial]
  | next prior e ih => exact conservation_step ih e

theorem initialized_unique_decision (events : Run baseStep decisionOwner initial s) : Unique s := by
  induction events with
  | refl => simp [Unique,initial]
  | next prior e ih => exact unique_step ih e

theorem only_original_commit_unlocks (e : Step baseStep decisionOwner s t) (held : s.slot = some i) (free : t.slot = none) :
    s.observed = some ⟨i,.committed⟩ ∧ Committed s i := by
  cases e with
  | acknowledge j slot seen durable =>
    have same : j = i := Option.some.inj (slot.symm.trans held)
    subst j; exact ⟨seen,durable⟩
  | accept => simp at free
  | _ => rw [held] at free; contradiction

theorem fence_is_not_a_commit (unique : Unique s) (fenced : ⟨i,.fenced⟩ ∈ s.decisions) : ¬ Committed s i := by
  intro committed
  have bad := unique ⟨i,.fenced⟩ fenced ⟨i,.committed⟩ committed rfl
  cases bad

theorem fenced_accepted_intent_stays_locked (events : Run baseStep decisionOwner initial s)
    (accepted : i ∈ s.accepted) (fenced : ⟨i,.fenced⟩ ∈ s.decisions) : s.slot = some i := by
  rcases initialized_conservation events i accepted with committed | held
  · exact False.elim (fence_is_not_a_commit (initialized_unique_decision events) fenced committed)
  · exact held

theorem old_worker_cannot_newly_commit (e : Step baseStep decisionOwner s t) (changed : t.decisions ≠ s.decisions)
    (newCommit : ∃ i, t.decisions = s.decisions ++ [⟨i,.committed⟩]) :
    ∃ i, s.slot = some i ∧ i.worker = s.worker ∧ i.fence = s.fence := by
  cases e with
  | commit next i source held current => exact ⟨i,held,current⟩
  | fencePending next i source held undecided effect =>
    rcases newCommit with ⟨j,eq⟩
    have tailEq : [Resolution.mk i .fenced] = [Resolution.mk j .committed] := List.append_cancel_left eq
    simp at tailEq
  | _ => exact False.elim (changed rfl)

theorem observation_is_exact (e : Step baseStep decisionOwner s t) (new : t.observed ≠ s.observed) (seen : t.observed = some r) :
    s.slot = some r.intent ∧ r ∈ s.decisions := by
  cases e with
  | observe actual history worker held member =>
    have same : actual = r := Option.some.inj seen
    subst r; exact ⟨held,member⟩
  | accept => simp at seen
  | commit => simp at seen
  | fencePending => simp at seen
  | fenceResolved => simp at seen
  | acknowledge => simp at seen
  | _ => exact False.elim (new rfl)

theorem observed_reads_require_owner_evidence (e : Step baseStep decisionOwner s t)
    (new : t.observed ≠ s.observed) (seen : t.observed = some r) :
    decisionOwner.readValid s.decisions s.worker r := by
  cases e with
  | observe actual history worker held member fullPrefix session authentic =>
    have same : actual = r := Option.some.inj seen
    subst r
    simpa [fullPrefix,session] using authentic
  | accept => simp at seen
  | commit => simp at seen
  | fencePending => simp at seen
  | fenceResolved => simp at seen
  | acknowledge => simp at seen
  | _ => exact False.elim (new rfl)

theorem context_fence_invalidates_observation (e : Step baseStep decisionOwner s t) (changed : t.fence ≠ s.fence) :
    t.fence = s.fence + 1 ∧ t.worker = s.worker + 1 ∧ t.observed = none ∧ t.slot = s.slot := by
  cases e with
  | fencePending => exact ⟨rfl,rfl,rfl,rfl⟩
  | fenceResolved => exact ⟨rfl,rfl,rfl,rfl⟩
  | _ => exact False.elim (changed rfl)

theorem new_acceptance_requires_free_slot (e : Step baseStep decisionOwner s t) (changed : t.accepted ≠ s.accepted) : s.slot = none := by
  cases e with
  | accept next i source free => exact free
  | _ => exact False.elim (changed rfl)

def exampleIntent (cut : Weaver.DeviceIsolationRecovery.Cut) : Intent := ⟨0,cut,0,0⟩
def pendingExample (cut : Weaver.DeviceIsolationRecovery.Cut) : State :=
  {accepted := [exampleIntent cut], slot := some (exampleIntent cut)}

theorem timeout_unlock_is_a_counterexample (cut : Weaver.DeviceIsolationRecovery.Cut) :
    Conserved (pendingExample cut) ∧ ¬ Conserved {pendingExample cut with slot := none} := by
  simp [Conserved,Committed,pendingExample]

theorem commit_after_fence_is_a_counterexample (cut : Weaver.DeviceIsolationRecovery.Cut) :
    ¬ Unique {pendingExample cut with decisions := [⟨exampleIntent cut,.fenced⟩,⟨exampleIntent cut,.committed⟩]} := by
  intro unique
  have bad := unique ⟨exampleIntent cut,.fenced⟩ (by simp) ⟨exampleIntent cut,.committed⟩ (by simp) rfl
  cases bad

theorem parent_step_or_stutter (e : Step baseStep decisionOwner s t) : t.base = s.base ∨ baseStep s.base t.base := by
  cases e with
  | delegate next source => exact .inr source
  | sealCut next source => exact .inr source
  | accept next i source => exact .inr source
  | commit next i source => exact .inr source
  | fencePending next i source => exact .inr source
  | fenceResolved next source => exact .inr source
  | _ => exact .inl rfl

variable {c : Weaver.FiniteDomainMigration.Config} {m : Weaver.FiniteStreamManifest.Manifest c}
  {p : Weaver.WriterSettlementClosure.Profile c m} {lineage root namespaceId : Nat}
  {owner : Weaver.GateConsumptionPersistence.EvidenceOwner} {projectionStore : Weaver.AnchorBrokerCommit.RootOwner}
  {family : Weaver.AnchorReconfiguration.Family} {store : Weaver.AnchorReconfiguration.Store} {signerOwner : Weaver.ProtectedSignerRelease.SignerOwner}
  {keyOwner : Weaver.KeyBoundaryQueue.KeyOwner} {nativeOwner : Weaver.DeviceIsolationRecovery.NativeOwner} {eligible : Weaver.AnchorReconfiguration.Scope → Nat → Prop}
local notation "DeviceStep" => Weaver.DeviceIsolationRecovery.Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner nativeOwner eligible

theorem initialized_product_refines_device (events : Run DeviceStep decisionOwner initial s) :
    Weaver.DeviceIsolationRecovery.Run (c := c) (m := m) (p := p) (lineage := lineage) (root := root) (namespaceId := namespaceId)
      (owner := owner) (projectionStore := projectionStore) (family := family) (store := store) (signerOwner := signerOwner) (keyOwner := keyOwner) (nativeOwner := nativeOwner) (eligible := eligible) Weaver.DeviceIsolationRecovery.initial s.base := by
  induction events with
  | refl => exact .refl _
  | next prior e ih =>
    rcases parent_step_or_stutter e with same | source
    · simpa [← same] using ih
    · exact .next ih source

theorem original_consumption_and_settlement_remain_unique (events : Run DeviceStep decisionOwner initial s) (k) :
    s.base.base.base.base.base.base.base.burnCount k ≤ 1 ∧ s.base.base.base.base.base.base.dispatchCount k ≤ 1 ∧ s.base.base.base.base.base.base.base.base.authority.writes k ≤ 1 :=
  Weaver.DeviceIsolationRecovery.original_consumption_and_settlement_remain_unique (initialized_product_refines_device events) k

theorem original_budget_remains_conserved (events : Run DeviceStep decisionOwner initial s) (b) :
    Weaver.SettlementAnchorRecovery.accountMaterialized c s.base.base.base.base.base.base.base.base b ≤ Weaver.FiniteDomainMigration.booked c s.base.base.base.base.base.base.base.base.authority.source.base.base.control.journal.head.payload b ∧
    Weaver.SettlementAnchorRecovery.accountMaterialized c s.base.base.base.base.base.base.base.base b ≤ c.capacity b :=
  Weaver.DeviceIsolationRecovery.original_budget_remains_conserved (initialized_product_refines_device events) b

theorem unknown_original_reservation_stays_held (events : Run DeviceStep decisionOwner initial s)
    (sealed : s.base.base.base.base.base.base.base.seals k = some a) :
    (s.base.base.base.base.base.base.base.base.authority.source.base.base.control.journal.head.payload.messages k).reserved = true :=
  Weaver.DeviceIsolationRecovery.unknown_original_reservation_stays_held (initialized_product_refines_device events) sealed

#print axioms observed_reads_require_owner_evidence
#print axioms context_fence_invalidates_observation
#print axioms new_acceptance_requires_free_slot
#print axioms timeout_unlock_is_a_counterexample
#print axioms commit_after_fence_is_a_counterexample
#print axioms decisions_never_roll_back
#print axioms accepted_intents_never_disappear
#print axioms commitment_survives
#print axioms initialized_conservation
#print axioms initialized_unique_decision
#print axioms only_original_commit_unlocks
#print axioms fenced_accepted_intent_stays_locked
#print axioms fence_is_not_a_commit
#print axioms old_worker_cannot_newly_commit
#print axioms observation_is_exact
#print axioms initialized_product_refines_device
#print axioms original_consumption_and_settlement_remain_unique
#print axioms original_budget_remains_conserved
#print axioms unknown_original_reservation_stays_held
end Weaver.FloorIntentDecision
