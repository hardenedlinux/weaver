import SettlementAnchorRecovery
namespace Weaver.GateConsumptionPersistence
open Weaver.LogicalMessageAuthority (update)
abbrev Permit := Weaver.SettlementAnchorRecovery.Permit
structure Burn where
  permit : Permit
  epoch : Nat
  deriving DecidableEq
structure Journal where
  seals : Nat → Option Permit := fun _ => none
  grants : Nat → Option Nat := fun _ => none
  burns : Nat → Option Burn := fun _ => none
  results : Nat → Option Permit := fun _ => none
  epoch : Nat := 0
structure State where
  base : Weaver.SettlementAnchorRecovery.State := Weaver.SettlementAnchorRecovery.initial
  seals : Nat → Option Permit := fun _ => none
  grants : Nat → Option Nat := fun _ => none
  burns : Nat → Option Burn := fun _ => none
  results : Nat → Option Permit := fun _ => none
  caps : Nat → Option Nat := fun _ => none
  pending : Nat → Bool := fun _ => false
  grantCount : Nat → Nat := fun _ => 0
  burnCount : Nat → Nat := fun _ => 0
  epoch : Nat := 0
  needsFence : Bool := false
  disk : Journal := {}
structure EvidenceOwner where
  receiptValid : Nat → Permit → Prop
  barrierValid : Nat → Prop

def initial : State := {}
variable {c : Weaver.FiniteDomainMigration.Config} {m : Weaver.FiniteStreamManifest.Manifest c} {p : Weaver.WriterSettlementClosure.Profile c m} {lineage : Nat} {owner : EvidenceOwner}
def journal (s : State) : Journal := ⟨s.seals,s.grants,s.burns,s.results,s.epoch⟩
def Covered (s : State) : Prop := ∀ k b, s.burns k = some b → ∃ a, s.results k = some a

def Ready (s : State) : Prop := s.needsFence = false ∧ s.disk = journal s ∧ Covered s

inductive Step (c : Weaver.FiniteDomainMigration.Config) (m : Weaver.FiniteStreamManifest.Manifest c) (p : Weaver.WriterSettlementClosure.Profile c m) (lineage : Nat) (owner : EvidenceOwner) : State → State → Prop where
  | advance (s next) (ready : Ready s) (event : Weaver.SettlementAnchorRecovery.Step c m p lineage s.base next)
      (permits : next.authority.permits = s.base.authority.permits)
      (outcomes : next.authority.outcomes = s.base.authority.outcomes)
      (confirm : ∀ k a, next.authority.confirmed k = some a → s.results k = some a) :
      Step c m p lineage owner s { s with base := next }
  -- Independent durable root spends acceptance before any capability is exposed.
  | sealRoot (s k q worker fence) (ready : Ready s) (recovered : Weaver.SettlementAnchorRecovery.Recovered s.base)
      (intent : s.base.authority.intents k = some q)
      (current : worker = s.base.authority.worker ∧ fence = s.base.authority.fence)
      (fresh : s.base.authority.permits k = none) (rootFresh : s.seals k = none) :
      Step c m p lineage owner s { s with
        base := { s.base with authority := { s.base.authority with
          permits := update s.base.authority.permits k (some ⟨q,worker,fence⟩)
          accepts := update s.base.authority.accepts k (s.base.authority.accepts k + 1)
          gateRevision := s.base.authority.gateRevision + 1 }, online := false }
        seals := update s.seals k (some ⟨q,worker,fence⟩) }
  -- Tombstone precedes possibly delivered original affine capability. No regrant.
  | grant (s k a) (ready : Ready s) (recovered : Weaver.SettlementAnchorRecovery.Recovered s.base)
      (sealed : s.seals k = some a) (fresh : s.grants k = none) :
      Step c m p lineage owner s { s with
        grants := update s.grants k (some s.epoch)
        caps := update s.caps k (some s.epoch)
        grantCount := update s.grantCount k (s.grantCount k + 1) }
  -- Final broker checks the independent epoch and atomically spends the root key.
  | burn (s k a epoch) (unfenced : s.needsFence = false) (cap : s.caps k = some epoch)
      (current : epoch = s.epoch) (sealed : s.seals k = some a) (fresh : s.burns k = none) :
      Step c m p lineage owner s { s with
        burns := update s.burns k (some ⟨a,epoch⟩)
        caps := update s.caps k none
        pending := update s.pending k true
        burnCount := update s.burnCount k (s.burnCount k + 1) }
  -- The original already accepted I/O may finish after loss/fencing. Never replay it.
  | complete (s k b) (burned : s.burns k = some b) (pending : s.pending k = true)
      (accepted : s.base.authority.permits k = some b.permit)
      (fresh : s.base.authority.outcomes k = none) :
      Step c m p lineage owner s { s with
        base := { s.base with authority := { s.base.authority with
          outcomes := update s.base.authority.outcomes k (some b.permit)
          writes := update s.base.authority.writes k (s.base.authority.writes k + 1)
          gateRevision := s.base.authority.gateRevision + 1 }, online := false }
        pending := update s.pending k false
        disk := { s.disk with results := update s.disk.results k (some b.permit) } }
  -- Authenticated original receipt may arrive from a surviving owner/copy after loss.
  | archive (s k a b) (actual : s.base.authority.outcomes k = some a)
      (burned : s.burns k = some b) (same : b.permit = a)
      (valid : owner.receiptValid k a) (fresh : s.results k = none) :
      Step c m p lineage owner s { s with results := update s.results k (some a) }
  | loseJournal (s image) : Step c m p lineage owner s { s with
      base := { s.base with online := false }, disk := image, needsFence := true }
  -- Qualified external no-new-submission barrier, not mere process death/epoch text.
  | fence (s) (valid : owner.barrierValid s.epoch) : Step c m p lineage owner s { s with
      base := { s.base with online := false }, epoch := s.epoch + 1, needsFence := false }
  -- Unknown burns cannot be turned into an empty authoritative result set.
  | rebuild (s) (unfenced : s.needsFence = false) (covered : Covered s) :
      Step c m p lineage owner s { s with
        base := { s.base with localImage := s.base.authority, online := true }
        disk := journal s }
  | lostReply (s) : Step c m p lineage owner s s

inductive Reachable (c : Weaver.FiniteDomainMigration.Config) (m : Weaver.FiniteStreamManifest.Manifest c) (p : Weaver.WriterSettlementClosure.Profile c m) (lineage : Nat) (owner : EvidenceOwner) : State → Prop where
  | init : Reachable c m p lineage owner initial
  | next : Reachable c m p lineage owner s → Step c m p lineage owner s t → Reachable c m p lineage owner t

theorem projection (event : Step c m p lineage owner s t) : Weaver.SettlementAnchorRecovery.Step c m p lineage s.base t.base := by
  cases event with
  | advance next ready event => exact event
  | sealRoot k q worker fence ready recovered intent current fresh rootFresh => exact .accept _ _ _ _ _ recovered intent current fresh
  | complete k b burned pending accepted fresh => exact .apply _ _ _ accepted fresh
  | loseJournal image => exact .restore _ _
  | fence valid => exact .restore _ _
  | rebuild unfenced covered => exact .recover _ _ rfl
  | _ => exact .lostReply _
theorem base_reachable (h : Reachable c m p lineage owner s) : Weaver.SettlementAnchorRecovery.Reachable c m p lineage s.base := by
  induction h with
  | init => exact .init
  | next _ event ih => exact .next ih (projection event)

theorem seal_immutable (event : Step c m p lineage owner s t) (old : s.seals k = some a) : t.seals k = some a := by
  cases event with
  | sealRoot j => by_cases eq : k = j <;> simp_all [update]
  | _ => exact old
theorem burn_immutable (event : Step c m p lineage owner s t) (old : s.burns k = some b) : t.burns k = some b := by
  cases event with
  | burn j => by_cases eq : k = j <;> simp_all [update]
  | _ => exact old
theorem grant_immutable (event : Step c m p lineage owner s t) (old : s.grants k = some epoch) : t.grants k = some epoch := by
  cases event with
  | grant j => by_cases eq : k = j <;> simp_all [update]
  | _ => exact old
theorem result_immutable (event : Step c m p lineage owner s t) (old : s.results k = some a) : t.results k = some a := by
  cases event with
  | archive j => by_cases eq : k = j <;> simp_all [update]
  | _ => exact old

structure Invariant (s : State) : Prop where
  seals : s.seals = s.base.authority.permits
  burns : ∀ k b, s.burns k = some b → s.seals k = some b.permit
  outcomes : ∀ k a, s.base.authority.outcomes k = some a → ∃ b, s.burns k = some b ∧ b.permit = a
  results : ∀ k a, s.results k = some a → s.base.authority.outcomes k = some a ∧ owner.receiptValid k a
  grants : Weaver.SettlementAnchorRecovery.CountSafe s.grants s.grantCount
  counts : Weaver.SettlementAnchorRecovery.CountSafe s.burns s.burnCount

theorem initial_invariant : Invariant (owner := owner) initial := by
  refine ⟨rfl,?_,?_,?_,?_,?_⟩ <;> simp [initial,Weaver.SettlementAnchorRecovery.initial,Weaver.SettlementAnchorRecovery.CountSafe]

theorem invariant_step (inv : Invariant (owner := owner) s) (event : Step c m p lineage owner s t) : Invariant (owner := owner) t := by
  have burns (k b) (old : s.burns k = some b) : t.seals k = some b.permit := seal_immutable event (inv.burns k b old)
  have outcomes (k a) (old : s.base.authority.outcomes k = some a) : ∃ b, t.burns k = some b ∧ b.permit = a := by
    obtain ⟨b,burned,same⟩ := inv.outcomes k a old
    exact ⟨b,burn_immutable event burned,same⟩
  have results (k a) (old : s.results k = some a) : t.base.authority.outcomes k = some a ∧ owner.receiptValid k a :=
    ⟨Weaver.SettlementAnchorRecovery.outcome_immutable (projection event) (inv.results k a old).1,(inv.results k a old).2⟩
  cases event with
  | advance next ready event permits sameOutcomes confirm =>
    exact ⟨inv.seals.trans permits.symm,burns,by simpa [sameOutcomes] using outcomes,results,inv.grants,inv.counts⟩
  | sealRoot k q worker fence ready recovered intent current fresh rootFresh =>
    refine ⟨?_,burns,outcomes,results,inv.grants,inv.counts⟩
    simp only; rw [inv.seals]
  | grant k a ready recovered sealed fresh => exact ⟨inv.seals,burns,outcomes,results,Weaver.SettlementAnchorRecovery.count_insert inv.grants fresh,inv.counts⟩
  | burn k a epoch unfenced cap current sealed fresh =>
    refine ⟨inv.seals,?_,outcomes,results,inv.grants,Weaver.SettlementAnchorRecovery.count_insert inv.counts fresh⟩
    intro j b record; by_cases eq : j = k
    · subst j; have same : b = ⟨a,epoch⟩ := by simpa [update] using record.symm
      subst b; exact sealed
    · exact burns j b (by simpa [update,eq] using record)
  | complete k b burned pending accepted fresh =>
    refine ⟨inv.seals,burns,?_,results,inv.grants,inv.counts⟩
    intro j a record; by_cases eq : j = k
    · subst j; have same : a = b.permit := by simpa [update] using record.symm
      subst a; exact ⟨b,burned,rfl⟩
    · exact outcomes j a (by simpa [update,eq] using record)
  | archive k a b actual burned same valid fresh =>
    refine ⟨inv.seals,burns,outcomes,?_,inv.grants,inv.counts⟩
    intro j receipt record; by_cases eq : j = k
    · subst j; have equal : receipt = a := by simpa [update] using record.symm
      subst receipt; exact ⟨actual,valid⟩
    · exact results j receipt (by simpa [update,eq] using record)
  | _ => exact ⟨inv.seals,burns,outcomes,results,inv.grants,inv.counts⟩

theorem reachable_invariant (h : Reachable c m p lineage owner s) : Invariant (owner := owner) s := by
  induction h with
  | init => exact initial_invariant
  | next _ event ih => exact invariant_step ih event

-- Complete archived coverage makes every outcome reconstructible from the root.
theorem covered_root_equals_actual_outcomes (h : Reachable c m p lineage owner s) (covered : Covered s) :
    s.results = s.base.authority.outcomes := by
  funext k
  have inv := reachable_invariant h
  cases actual : s.base.authority.outcomes k with
  | none =>
    cases archived : s.results k with
    | none => rfl
    | some a => have present := (inv.results k a archived).1; simp [actual] at present
  | some a =>
    obtain ⟨b,burned,same⟩ := inv.outcomes k a actual
    obtain ⟨receipt,stored⟩ := covered k b burned
    have present := (inv.results k receipt stored).1
    have eq : receipt = a := Option.some.inj (present.symm.trans actual)
    simpa [eq] using stored

theorem no_regrant_or_reburn (h : Reachable c m p lineage owner s) (k) : s.grantCount k ≤ 1 ∧ s.burnCount k ≤ 1 :=
  ⟨(reachable_invariant h).grants k |>.1,(reachable_invariant h).counts k |>.1⟩
theorem actual_account_application_at_most_once (h : Reachable c m p lineage owner s) (k) : s.base.authority.writes k ≤ 1 :=
  (Weaver.SettlementAnchorRecovery.accepted_and_applied_at_most_once (base_reachable h) k).2

theorem sealed_unknown_retains_original_reservation (h : Reachable c m p lineage owner s) (sealed : s.seals k = some a) :
    (s.base.authority.source.base.base.control.journal.head.payload.messages k).reserved = true := by
  have stored : s.base.authority.permits k = some a := by rw [← (reachable_invariant h).seals]; exact sealed
  have intent := (Weaver.SettlementAnchorRecovery.reachable_invariant (base_reachable h)).permits k a stored
  exact Weaver.SettlementAnchorRecovery.unknown_application_retains_reservation (base_reachable h) intent

theorem confirmation_requires_archived_actual_result (h : Reachable c m p lineage owner s) :
    ∀ k a, s.base.authority.confirmed k = some a → s.results k = some a := by
  induction h with
  | init => simp [initial,Weaver.SettlementAnchorRecovery.initial]
  | next prior event ih =>
    intro k a stored
    cases event with
    | advance next ready source permits outcomes confirm => exact confirm k a stored
    | archive j receipt b actual burned same valid fresh =>
      have old := ih k a stored
      by_cases eq : k = j
      · subst k; simp_all
      · simpa [update,eq] using old
    | _ => exact ih k a stored

-- The real transition cannot lower the independent writer epoch.
theorem epoch_monotone (event : Step c m p lineage owner s t) : s.epoch ≤ t.epoch := by
  cases event <;> simp

def BurnAdmissible (s : State) (k epoch : Nat) : Prop :=
  s.needsFence = false ∧ s.caps k = some epoch ∧ epoch = s.epoch ∧ s.burns k = none

theorem fence_rejects_previously_current_cap (s : State) (k : Nat) :
    ¬ BurnAdmissible { s with epoch := s.epoch + 1, needsFence := false } k s.epoch := by
  intro admissible
  have equal : s.epoch = s.epoch + 1 := admissible.2.2.1
  exact Nat.ne_of_lt (Nat.lt_succ_self s.epoch) equal

theorem unresolved_burn_prevents_rebuild (s : State) (missing : s.burns k = some b)
    (unknown : s.results k = none) : ¬ Covered s := by
  intro covered
  obtain ⟨a,stored⟩ := covered k b missing
  simp [unknown] at stored

-- Rebuilding the disk image is neither capability creation nor original I/O replay.
theorem rebuild_preserves_execution_state (s : State) :
    let t := { s with base := { s.base with localImage := s.base.authority, online := true }, disk := journal s }
    t.grants = s.grants ∧ t.burns = s.burns ∧ t.caps = s.caps ∧ t.pending = s.pending := by
  exact ⟨rfl,rfl,rfl,rfl⟩

theorem archived_result_has_original_settlement (h : Reachable c m p lineage owner s) (record : s.results k = some a) :
    a.request.key = k ∧ a.request.lineage = lineage ∧ s.base.authority.source.settlement k = some a.request.usage :=
  Weaver.SettlementAnchorRecovery.application_has_original_settlement (base_reachable h) ((reachable_invariant h).results k a record).1

theorem end_to_end_account_conservation (h : Reachable c m p lineage owner s) (b : Nat) :
    Weaver.SettlementAnchorRecovery.accountMaterialized c s.base b ≤
      Weaver.FiniteDomainMigration.booked c s.base.authority.source.base.base.control.journal.head.payload b ∧
    Weaver.SettlementAnchorRecovery.accountMaterialized c s.base b ≤ c.capacity b :=
  ⟨Weaver.SettlementAnchorRecovery.materialization_covered (base_reachable h) b,
   Weaver.SettlementAnchorRecovery.materialization_within_capacity (base_reachable h) b⟩

#print axioms reachable_invariant
#print axioms covered_root_equals_actual_outcomes
#print axioms no_regrant_or_reburn
#print axioms actual_account_application_at_most_once
#print axioms sealed_unknown_retains_original_reservation
#print axioms confirmation_requires_archived_actual_result
#print axioms epoch_monotone
#print axioms fence_rejects_previously_current_cap
#print axioms unresolved_burn_prevents_rebuild
#print axioms rebuild_preserves_execution_state
#print axioms archived_result_has_original_settlement
#print axioms end_to_end_account_conservation
end Weaver.GateConsumptionPersistence
