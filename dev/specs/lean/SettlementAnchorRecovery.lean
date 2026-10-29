import WriterSettlementClosure
namespace Weaver.SettlementAnchorRecovery
open Weaver.LogicalMessageAuthority (update)
structure Request where
  key : Nat
  usage : Weaver.WriterSettlementClosure.Usage
  lineage : Nat
  deriving DecidableEq
structure Permit where
  request : Request
  worker : Nat
  fence : Nat
  deriving DecidableEq
-- A logical product of protected authorities, not one cross-store transaction.
structure Image where
  source : Weaver.WriterSettlementClosure.State := Weaver.WriterSettlementClosure.initial
  intents : Nat → Option Request := fun _ => none
  permits : Nat → Option Permit := fun _ => none
  outcomes : Nat → Option Permit := fun _ => none
  confirmed : Nat → Option Permit := fun _ => none
  accepts : Nat → Nat := fun _ => 0
  writes : Nat → Nat := fun _ => 0
  sourceRevision : Nat := 0
  intentRevision : Nat := 0
  gateRevision : Nat := 0
  confirmRevision : Nat := 0
  worker : Nat := 0
  fence : Nat := 0
structure State where
  authority : Image := {}
  localImage : Image := {}
  online : Bool := true

def initial : State := {}
variable {c : Weaver.FiniteDomainMigration.Config} {m : Weaver.FiniteStreamManifest.Manifest c} {p : Weaver.WriterSettlementClosure.Profile c m} {lineage : Nat}
def recoveryView (image : Image) : Image :=
  { image with accepts := fun _ => 0, writes := fun _ => 0 }
def Recovered (s : State) : Prop := s.online = true ∧ recoveryView s.localImage = recoveryView s.authority

def CountSafe (rows : Nat → Option α) (counts : Nat → Nat) : Prop :=
  ∀ k, counts k ≤ 1 ∧ (rows k = none → counts k = 0)
theorem count_insert (safe : CountSafe rows counts) (fresh : rows k = none) :
    CountSafe (update rows k (some value)) (update counts k (counts k + 1)) := by
  intro j
  by_cases eq : j = k
  · subst j; simp [update,(safe k).2 fresh]
  · simpa [update,eq] using safe j

inductive Step (c : Weaver.FiniteDomainMigration.Config) (m : Weaver.FiniteStreamManifest.Manifest c) (p : Weaver.WriterSettlementClosure.Profile c m) (lineage : Nat) : State → State → Prop where
  | source (s next) (recovered : Recovered s) (event : Weaver.WriterSettlementClosure.Step c m p s.authority.source next)
      (charged : ∀ k, (next.base.base.control.journal.head.payload.messages k).charged = true →
        ∃ a, s.authority.outcomes k = some a ∧ s.authority.confirmed k = some a) :
      Step c m p lineage s { s with authority := { s.authority with source := next, sourceRevision := s.authority.sourceRevision + 1 }, online := false }
  | anchor (s k u) (recovered : Recovered s) (settled : s.authority.source.settlement k = some u)
      (fresh : s.authority.intents k = none) :
      Step c m p lineage s { s with authority := { s.authority with
        intents := update s.authority.intents k (some ⟨k,u,lineage⟩)
        intentRevision := s.authority.intentRevision + 1 }, online := false }
  | accept (s k q worker fence) (recovered : Recovered s) (intent : s.authority.intents k = some q)
      (current : worker = s.authority.worker ∧ fence = s.authority.fence)
      (fresh : s.authority.permits k = none) :
      Step c m p lineage s { s with authority := { s.authority with
        permits := update s.authority.permits k (some ⟨q,worker,fence⟩)
        accepts := update s.authority.accepts k (s.authority.accepts k + 1)
        gateRevision := s.authority.gateRevision + 1 }, online := false }
  -- Actual protected gate transaction: application and immutable receipt together.
  -- An already accepted original operation may complete after worker fencing.
  | apply (s k a) (accepted : s.authority.permits k = some a)
      (fresh : s.authority.outcomes k = none) :
      Step c m p lineage s { s with authority := { s.authority with
        outcomes := update s.authority.outcomes k (some a)
        writes := update s.authority.writes k (s.authority.writes k + 1)
        gateRevision := s.authority.gateRevision + 1 }, online := false }
  | confirm (s k a) (recovered : Recovered s) (outcome : s.authority.outcomes k = some a)
      (intent : s.authority.intents k = some a.request) (fresh : s.authority.confirmed k = none) :
      Step c m p lineage s { s with authority := { s.authority with
        confirmed := update s.authority.confirmed k (some a)
        confirmRevision := s.authority.confirmRevision + 1 }, online := false }
  -- Fence publication is independent of the restorable worker/account view.
  | rotate (s worker) : Step c m p lineage s { s with authority := { s.authority with
      worker := worker, fence := s.authority.fence + 1, gateRevision := s.authority.gateRevision + 1 }, online := false }
  | restore (s image) : Step c m p lineage s { s with localImage := image, online := false }
  | recover (s image) (complete : recoveryView image = recoveryView s.authority) : Step c m p lineage s { s with localImage := image, online := true }
  | lostReply (s) : Step c m p lineage s s

inductive Reachable (c : Weaver.FiniteDomainMigration.Config) (m : Weaver.FiniteStreamManifest.Manifest c) (p : Weaver.WriterSettlementClosure.Profile c m) (lineage : Nat) : State → Prop where
  | init : Reachable c m p lineage initial
  | next : Reachable c m p lineage s → Step c m p lineage s t → Reachable c m p lineage t

theorem projection (event : Step c m p lineage s t) : Weaver.WriterSettlementClosure.Step c m p s.authority.source t.authority.source := by
  cases event with
  | source next recovered event charged => exact event
  | _ => exact .lostReply _
theorem source_reachable (h : Reachable c m p lineage s) : Weaver.WriterSettlementClosure.Reachable c m p s.authority.source := by
  induction h with
  | init => exact .init
  | next _ event ih => exact .next ih (projection event)

-- Authority records are never reconstructed from restored local images.
theorem intent_immutable (event : Step c m p lineage s t) (old : s.authority.intents k = some q) : t.authority.intents k = some q := by
  cases event with
  | anchor j => by_cases eq : k = j <;> simp_all [update]
  | _ => exact old
theorem permit_immutable (event : Step c m p lineage s t) (old : s.authority.permits k = some a) : t.authority.permits k = some a := by
  cases event with
  | accept j => by_cases eq : k = j <;> simp_all [update]
  | _ => exact old
theorem outcome_immutable (event : Step c m p lineage s t) (old : s.authority.outcomes k = some a) : t.authority.outcomes k = some a := by
  cases event with
  | apply j => by_cases eq : k = j <;> simp_all [update]
  | _ => exact old
theorem confirmation_immutable (event : Step c m p lineage s t) (old : s.authority.confirmed k = some a) : t.authority.confirmed k = some a := by
  cases event with
  | confirm j => by_cases eq : k = j <;> simp_all [update]
  | _ => exact old

structure Invariant (lineage : Nat) (s : State) : Prop where
  intents : ∀ k q, s.authority.intents k = some q → q.key = k ∧ q.lineage = lineage ∧ s.authority.source.settlement k = some q.usage
  permits : ∀ k a, s.authority.permits k = some a → s.authority.intents k = some a.request
  outcomes : ∀ k a, s.authority.outcomes k = some a → s.authority.permits k = some a
  confirmed : ∀ k a, s.authority.confirmed k = some a → s.authority.outcomes k = some a
  accepts : CountSafe s.authority.permits s.authority.accepts
  writes : CountSafe s.authority.outcomes s.authority.writes

theorem initial_invariant : Invariant lineage initial := by
  refine ⟨?_,?_,?_,?_,?_,?_⟩ <;> simp [initial,CountSafe]

theorem invariant_step (safe : Invariant lineage s) (event : Step c m p lineage s t) : Invariant lineage t := by
  have intents (k q) (old : s.authority.intents k = some q) : q.key = k ∧ q.lineage = lineage ∧ t.authority.source.settlement k = some q.usage :=
    ⟨(safe.intents k q old).1,(safe.intents k q old).2.1,Weaver.WriterSettlementClosure.settlement_immutable (projection event) (safe.intents k q old).2.2⟩
  have permits (k a) (old : s.authority.permits k = some a) : t.authority.intents k = some a.request := intent_immutable event (safe.permits k a old)
  have outcomes (k a) (old : s.authority.outcomes k = some a) : t.authority.permits k = some a := permit_immutable event (safe.outcomes k a old)
  have confirmed (k a) (old : s.authority.confirmed k = some a) : t.authority.outcomes k = some a := outcome_immutable event (safe.confirmed k a old)
  cases event with
  | anchor k u recovered settled fresh =>
    refine ⟨?_,permits,outcomes,confirmed,safe.accepts,safe.writes⟩
    intro j q record; by_cases eq : j = k
    · subst j; have same : q = ⟨k,u,lineage⟩ := by simpa [update] using record.symm
      subst q; exact ⟨rfl,rfl,settled⟩
    · exact intents j q (by simpa [update,eq] using record)
  | accept k q worker fence recovered intent current fresh =>
    refine ⟨intents,?_,outcomes,confirmed,count_insert safe.accepts fresh,safe.writes⟩
    intro j a record; by_cases eq : j = k
    · subst j; have same : a = ⟨q,worker,fence⟩ := by simpa [update] using record.symm
      subst a; exact intent
    · exact permits j a (by simpa [update,eq] using record)
  | apply k a accepted fresh =>
    refine ⟨intents,permits,?_,confirmed,safe.accepts,count_insert safe.writes fresh⟩
    intro j b record; by_cases eq : j = k
    · subst j; have same : b = a := by simpa [update] using record.symm
      subst b; exact accepted
    · exact outcomes j b (by simpa [update,eq] using record)
  | confirm k a recovered outcome intent fresh =>
    refine ⟨intents,permits,outcomes,?_,safe.accepts,safe.writes⟩
    intro j b record; by_cases eq : j = k
    · subst j; have same : b = a := by simpa [update] using record.symm
      subst b; exact outcome
    · exact confirmed j b (by simpa [update,eq] using record)
  | _ => exact ⟨intents,permits,outcomes,confirmed,safe.accepts,safe.writes⟩

theorem reachable_invariant (h : Reachable c m p lineage s) : Invariant lineage s := by
  induction h with
  | init => exact initial_invariant
  | next _ event ih => exact invariant_step ih event

theorem accepted_and_applied_at_most_once (h : Reachable c m p lineage s) (k) : s.authority.accepts k ≤ 1 ∧ s.authority.writes k ≤ 1 :=
  ⟨(reachable_invariant h).accepts k |>.1,(reachable_invariant h).writes k |>.1⟩

theorem application_has_original_settlement (h : Reachable c m p lineage s) (record : s.authority.outcomes k = some a) :
    a.request.key = k ∧ a.request.lineage = lineage ∧ s.authority.source.settlement k = some a.request.usage := by
  have inv := reachable_invariant h
  exact inv.intents k a.request (inv.permits k a (inv.outcomes k a record))

def materialized (s : State) (k : Nat) : Nat := match s.authority.outcomes k with | none => 0 | some a => a.request.usage.amount
def accountMaterialized (c : Weaver.FiniteDomainMigration.Config) (s : State) (b : Nat) : Nat :=
  Weaver.FiniteDomainMigration.sumKeys c.keys (fun k => if c.budget (c.root k) = b then materialized s k else 0)

theorem materialization_covered (h : Reachable c m p lineage s) (b) :
    accountMaterialized c s b ≤ Weaver.FiniteDomainMigration.booked c s.authority.source.base.base.control.journal.head.payload b := by
  apply Nat.le_trans (m := Weaver.WriterSettlementClosure.accountSettled c s.authority.source b) ?_ (Weaver.WriterSettlementClosure.settlement_covered_by_original_reservations (source_reachable h) b)
  apply Weaver.FiniteStreamManifest.sum_mono
  intro k member
  by_cases account : c.budget (c.root k) = b
  · cases record : s.authority.outcomes k with
    | none => simp [materialized,account,record]
    | some a =>
      have original := (application_has_original_settlement h record).2.2
      simp [materialized,Weaver.WriterSettlementClosure.settledAmount,account,record,original]
  · simp [account]

theorem materialization_within_capacity (h : Reachable c m p lineage s) (b) : accountMaterialized c s b ≤ c.capacity b := by
  have control := (Weaver.FiniteStreamManifest.reachable_invariant (Weaver.DriverCompletionRecovery.reachable_projection (Weaver.WriterSettlementClosure.reachable_projection (source_reachable h)))).control
  exact Nat.le_trans (materialization_covered h b) (Weaver.ComposedGatewayLifecycle.end_to_end_conservation control b)

theorem unknown_application_retains_reservation (h : Reachable c m p lineage s) (intent : s.authority.intents k = some q) :
    (s.authority.source.base.base.control.journal.head.payload.messages k).reserved = true := by
  have original := (reachable_invariant h).intents k q intent
  have join := Weaver.WriterSettlementClosure.settlement_requires_same_usage_and_closure (source_reachable h) k q.usage original.2.2
  have bound := Weaver.WriterSettlementClosure.usage_bound (source_reachable h) k q.usage join.1
  obtain ⟨manifest,account,history,closure,unit,amount,final,binding,installed⟩ := bound.2
  have inv := Weaver.FiniteStreamManifest.reachable_invariant (Weaver.DriverCompletionRecovery.reachable_projection (Weaver.WriterSettlementClosure.reachable_projection (source_reachable h)))
  have retained := inv.manifests q.usage.message binding installed
  have reserved := retained.2.2.2.2.2
  simpa [retained.1,bound.1] using reserved

theorem mixed_image_cannot_recover (s : State) (image : Image) (different : recoveryView image ≠ recoveryView s.authority) : ¬ recoveryView image = recoveryView s.authority := different
theorem old_worker_cannot_accept (s : State) (worker fence : Nat) (old : fence ≠ s.authority.fence) : ¬ (worker = s.authority.worker ∧ fence = s.authority.fence) := by
  intro current; exact old current.2

theorem restore_never_changes_authority (s : State) (image : Image) :
    ({ s with localImage := image, online := false } : State).authority = s.authority := rfl

def RecoverySafe (s : State) : Prop := s.online = true → recoveryView s.localImage = recoveryView s.authority

theorem recovery_step (safe : RecoverySafe s) (event : Step c m p lineage s t) : RecoverySafe t := by
  cases event with
  | recover image complete => exact fun _ => complete
  | lostReply => exact safe
  | _ => simp [RecoverySafe]

theorem online_requires_complete_current_image (h : Reachable c m p lineage s) : RecoverySafe s := by
  induction h with
  | init => simp [RecoverySafe,initial]
  | next _ event ih => exact recovery_step ih event

def ChargedSafe (s : State) : Prop :=
  ∀ k, (s.authority.source.base.base.control.journal.head.payload.messages k).charged = true →
    ∃ a, s.authority.outcomes k = some a ∧ s.authority.confirmed k = some a

theorem charged_step (safe : ChargedSafe s) (event : Step c m p lineage s t) : ChargedSafe t := by
  have keep (k) (old : (s.authority.source.base.base.control.journal.head.payload.messages k).charged = true) :
      ∃ a, t.authority.outcomes k = some a ∧ t.authority.confirmed k = some a := by
    obtain ⟨a,outcome,confirmed⟩ := safe k old
    exact ⟨a,outcome_immutable event outcome,confirmation_immutable event confirmed⟩
  cases event with
  | source next recovered event charged => exact charged
  | _ => exact keep

theorem charged_has_exact_anchor_and_gate_receipt (h : Reachable c m p lineage s) : ChargedSafe s := by
  induction h with
  | init => simp [ChargedSafe,initial,Weaver.WriterSettlementClosure.initial,Weaver.DriverCompletionRecovery.initial,Weaver.FiniteStreamManifest.initial,
      Weaver.ComposedGatewayLifecycle.initial,Weaver.AnchoredRecoveryAndEgress.Journal.initial,
      Weaver.FiniteDomainMigration.empty,Weaver.LogicalMessageAuthority.initial]
  | next _ event ih => exact charged_step ih event

theorem ghost_counts_do_not_grant_recovery (image : Image) (accepts writes : Nat → Nat) :
    recoveryView { image with accepts := accepts, writes := writes } = recoveryView image := rfl

#print axioms online_requires_complete_current_image
#print axioms charged_has_exact_anchor_and_gate_receipt
#print axioms ghost_counts_do_not_grant_recovery
#print axioms reachable_invariant
#print axioms accepted_and_applied_at_most_once
#print axioms application_has_original_settlement
#print axioms materialization_covered
#print axioms materialization_within_capacity
#print axioms unknown_application_retains_reservation
#print axioms restore_never_changes_authority
end Weaver.SettlementAnchorRecovery
