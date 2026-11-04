-- SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
--
-- SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

import DriverCompletionRecovery

/-! Split-store refinement: evidence blobs precede canonical owner decisions;
local visibility follows decisions; final usage and settlement are separate.
Physical certificate authenticity and writer-universe completeness are inputs. -/
namespace Weaver.WriterSettlementClosure
abbrev Key := Weaver.FiniteStreamManifest.Key
abbrev Driver := Weaver.DriverCompletionRecovery.State
abbrev Request := Weaver.DriverCompletionRecovery.Request

structure Evidence where
  request : Request
  isolation : Bool
  writers : Nat
  buffers : Nat
  deriving DecidableEq

-- Separate immutable evidence slots permit isolation after an uncommitted finish.
def blobKey (key : Key) (isolation : Bool) : Key :=
  (2 * key.1 + if isolation then 1 else 0, key.2)

structure Usage where
  message : Nat
  manifest : Nat
  token : Nat
  stream : Nat
  account : Nat
  history : Nat
  closure : Nat
  unit : Nat
  amount : Nat
  final : Bool
  deriving DecidableEq

structure Profile (c : Weaver.FiniteDomainMigration.Config) (_m : Weaver.FiniteStreamManifest.Manifest c) where
  writers : Key → Nat
  buffers : Key → Nat
  closure : Nat → Nat
  unit : Nat → Nat
  evidenceAuthentic : Evidence → Prop
  usageAuthentic : Usage → Prop

structure State where
  base : Driver := Weaver.DriverCompletionRecovery.initial
  blobs : Key → Option Evidence := fun _ => none
  decisions : Key → Option Evidence := fun _ => none
  visible : Key → Bool := fun _ => false
  closed : Nat → Bool := fun _ => false
  usage : Nat → Option Usage := fun _ => none
  settlement : Nat → Option Usage := fun _ => none
  ready : Bool := true

def initial : State := {}
variable {c : Weaver.FiniteDomainMigration.Config} {m : Weaver.FiniteStreamManifest.Manifest c} {p : Profile c m}

def StreamPublished (m : Weaver.FiniteStreamManifest.Manifest c) (s : State) (key : Key) : Prop :=
  ∀ prior e, m.stream prior.1 = m.stream key.1 → s.decisions prior = some e → s.visible prior = true

def ClosureReady (_m : Weaver.FiniteStreamManifest.Manifest c) (s : State) (k : Nat) : Prop :=
  ∀ r d, (s.base.base.ranges (k,r)).admission = some d →
    (s.base.base.ranges (k,r)).active = false ∧
    ∃ e, s.decisions (k,r) = some e ∧ s.visible (k,r) = true

def EvidenceBound (p : Profile c m) (s : State) (e : Evidence) : Prop :=
  e.request.manifest = m.identity e.request.key.1 ∧
  e.writers = p.writers e.request.key ∧ e.buffers = p.buffers e.request.key ∧
  s.base.tails e.request.key = some e.request.generation ∧
  ∃ d, (s.base.base.ranges e.request.key).admission = some d ∧
    e.request.epoch = d.epoch ∧ e.request.incarnation = d.incarnation

def UsageBound (p : Profile c m) (s : State) (u : Usage) : Prop :=
  u.manifest = m.identity u.message ∧ u.account = c.budget (c.root u.message) ∧
  u.history = c.history (c.root u.message) ∧ u.closure = p.closure u.message ∧
  u.unit = p.unit u.message ∧ u.amount ≤ c.cost u.message ∧ u.final = true ∧
  ∃ binding, s.base.base.installed u.message = some binding

inductive Step (c : Weaver.FiniteDomainMigration.Config) (m : Weaver.FiniteStreamManifest.Manifest c) (p : Profile c m) : State → State → Prop where
  -- Structural filters exclude bypasses of terminal evidence and finance joins.
  | advance (s next) (event : Weaver.DriverCompletionRecovery.Step c m s.base next)
      (results : next.results = s.base.results) (isolated : next.isolated = s.base.isolated)
      (blocked : next.base.blocked = s.base.base.blocked)
      (admit : ∀ key, (s.base.base.ranges key).admission = none →
        (next.base.ranges key).admission ≠ none → StreamPublished m s key)
      (closedAdmissions : ∀ key, s.closed key.1 = true → (next.base.ranges key).admission = (s.base.base.ranges key).admission)
      (retire : ∀ k, (next.base.control.journal.head.payload.messages k).retired = true → ClosureReady m s k)
      (finalCost : ∀ k, (next.base.control.journal.head.payload.messages k).finalCost = true → s.usage k ≠ none)
      (charged : ∀ k, (next.base.control.journal.head.payload.messages k).charged = true → s.settlement k ≠ none) :
      Step c m p s { s with base := next }
  -- Authentic event from the qualified writer evidence owner, not a byte comparison.
  | evidence (s e) (ready : s.ready = true) (fresh : s.blobs (blobKey e.request.key e.isolation) = none)
      (authentic : p.evidenceAuthentic e) (bound : EvidenceBound p s e) :
      Step c m p s { s with blobs := Weaver.FiniteStreamManifest.setAt s.blobs (blobKey e.request.key e.isolation) (some e) }
  | finish (s e d) (ready : s.ready = true) (blob : s.blobs (blobKey e.request.key e.isolation) = some e)
      (kind : e.isolation = false) (fresh : s.decisions e.request.key = none)
      (online : s.base.online = true) (exact : Weaver.DriverCompletionRecovery.Exact m s.base e.request d)
      (pending : s.base.pending e.request.key = some e.request)
      (freshResult : s.base.results e.request.key = none)
      (live : (s.base.base.ranges e.request.key).active = true) :
      Step c m p s { s with
        base := { s.base with
          base := { s.base.base with ranges := Weaver.FiniteStreamManifest.setAt s.base.base.ranges e.request.key { s.base.base.ranges e.request.key with active := false } }
          results := Weaver.FiniteStreamManifest.setAt s.base.results e.request.key (some e.request) }
        decisions := Weaver.FiniteStreamManifest.setAt s.decisions e.request.key (some e) }
  | fence (s e d) (ready : s.ready = true) (blob : s.blobs (blobKey e.request.key e.isolation) = some e)
      (kind : e.isolation = true) (stored : (s.base.base.ranges e.request.key).admission = some d)
      (live : (s.base.base.ranges e.request.key).active = true) :
      Step c m p s { s with base := { s.base with isolated := Weaver.FiniteStreamManifest.setAt s.base.isolated e.request.key true } }
  | quarantine (s e d) (ready : s.ready = true) (blob : s.blobs (blobKey e.request.key e.isolation) = some e)
      (kind : e.isolation = true) (fresh : s.decisions e.request.key = none)
      (isolated : s.base.isolated e.request.key = true)
      (stored : (s.base.base.ranges e.request.key).admission = some d)
      (live : (s.base.base.ranges e.request.key).active = true) :
      Step c m p s { s with
        base := { s.base with base := { s.base.base with
          ranges := Weaver.FiniteStreamManifest.setAt s.base.base.ranges e.request.key (Weaver.FiniteStreamManifest.closeRange (s.base.base.ranges e.request.key) (m.spec e.request.key.1 e.request.key.2).length)
          blocked := Weaver.LogicalMessageAuthority.update s.base.base.blocked (m.stream e.request.key.1) true } }
        decisions := Weaver.FiniteStreamManifest.setAt s.decisions e.request.key (some e) }
  | publish (s key e) (ready : s.ready = true) (decision : s.decisions key = some e)
      (blob : s.blobs (blobKey key e.isolation) = some e) :
      Step c m p s { s with visible := Weaver.FiniteStreamManifest.setAt s.visible key true }
  | close (s k) (ready : s.ready = true)
      (retired : (s.base.base.control.journal.head.payload.messages k).retired = true)
      (coverage : ClosureReady m s k) :
      Step c m p s { s with closed := Weaver.LogicalMessageAuthority.update s.closed k true }
  | usage (s u) (ready : s.ready = true) (closed : s.closed u.message = true)
      (authentic : p.usageAuthentic u) (bound : UsageBound p s u)
      (token : u.token = (s.base.base.control.journal.head.payload.messages u.message).claimToken)
      (stream : u.stream = (s.base.base.control.journal.head.payload.messages u.message).claimStream)
      (fresh : s.usage u.message = none) :
      Step c m p s { s with usage := Weaver.LogicalMessageAuthority.update s.usage u.message (some u) }
  | settle (s k u) (ready : s.ready = true) (usage : s.usage k = some u)
      (closed : s.closed k = true) (fresh : s.settlement k = none) :
      Step c m p s { s with settlement := Weaver.LogicalMessageAuthority.update s.settlement k (some u) }
  | ownerCrash (s) : Step c m p s { s with ready := false }
  | recover (s) : Step c m p s { s with ready := true }
  | lostReply (s) : Step c m p s s

inductive Reachable (c : Weaver.FiniteDomainMigration.Config) (m : Weaver.FiniteStreamManifest.Manifest c) (p : Profile c m) : State → Prop where
  | init : Reachable c m p initial
  | next : Reachable c m p s → Step c m p s t → Reachable c m p t

theorem projection (event : Step c m p s t) : Weaver.DriverCompletionRecovery.Step c m s.base t.base := by
  cases event with
  | advance next event => exact event
  | finish e d ready blob kind fresh online exact pending freshResult live => exact .finish _ _ _ online exact pending freshResult live
  | fence e d ready blob kind stored live => exact .fence _ _ _ stored live
  | quarantine e d ready blob kind fresh isolated stored live => exact .quarantine _ _ _ isolated stored live
  | _ => exact .loseReply _

theorem reachable_projection (h : Reachable c m p s) : Weaver.DriverCompletionRecovery.Reachable c m s.base := by
  induction h with
  | init => exact .init
  | next _ event ih => exact .next ih (projection event)

theorem blob_immutable (event : Step c m p s t) (old : s.blobs key = some e) : t.blobs key = some e := by
  cases event with
  | evidence incoming ready fresh authentic bound =>
    by_cases eq : key = blobKey incoming.request.key incoming.isolation
    · subst key; simp_all
    · simpa [Weaver.FiniteStreamManifest.setAt,eq] using old
  | _ => exact old

theorem decision_immutable (event : Step c m p s t) (old : s.decisions key = some e) : t.decisions key = some e := by
  cases event with
  | finish incoming d ready blob kind fresh online exact pending freshResult live =>
    by_cases eq : key = incoming.request.key
    · subst key; simp_all
    · simpa [Weaver.FiniteStreamManifest.setAt,eq] using old
  | quarantine incoming d ready blob kind fresh isolated stored live =>
    by_cases eq : key = incoming.request.key
    · subst key; simp_all
    · simpa [Weaver.FiniteStreamManifest.setAt,eq] using old
  | _ => exact old

def VisibleSafe (s : State) : Prop :=
  ∀ key, s.visible key = true → ∃ e, s.decisions key = some e ∧ s.blobs (blobKey key e.isolation) = some e

theorem visible_step (safe : VisibleSafe s) (event : Step c m p s t) : VisibleSafe t := by
  have keep (key) (visible : s.visible key = true) : ∃ e, t.decisions key = some e ∧ t.blobs (blobKey key e.isolation) = some e := by
    obtain ⟨e,decision,blob⟩ := safe key visible
    exact ⟨e,decision_immutable event decision,blob_immutable event blob⟩
  cases event with
  | publish key e ready decision blob =>
    intro j visible
    by_cases eq : j = key
    · subst j; exact ⟨e,decision,blob⟩
    · exact keep j (by simpa [Weaver.FiniteStreamManifest.setAt,eq] using visible)
  | _ => exact keep

theorem no_visibility_from_prepared_blob (h : Reachable c m p s) : VisibleSafe s := by
  induction h with
  | init => simp [VisibleSafe,initial]
  | next _ event ih => exact visible_step ih event

theorem usage_immutable (event : Step c m p s t) (old : s.usage k = some u) : t.usage k = some u := by
  cases event with
  | usage incoming ready closed authentic bound token stream fresh =>
    by_cases eq : k = incoming.message
    · subst k; simp_all
    · simpa [Weaver.LogicalMessageAuthority.update,eq] using old
  | _ => exact old

theorem settlement_immutable (event : Step c m p s t) (old : s.settlement k = some u) : t.settlement k = some u := by
  cases event with
  | settle j incoming ready usage closed fresh =>
    by_cases eq : k = j
    · subst k; simp_all
    · simpa [Weaver.LogicalMessageAuthority.update,eq] using old
  | _ => exact old

theorem closed_monotone (event : Step c m p s t) (old : s.closed k = true) : t.closed k = true := by
  cases event with
  | close j => by_cases eq : k = j <;> simp_all [Weaver.LogicalMessageAuthority.update]
  | _ => exact old

def SettlementSafe (s : State) : Prop :=
  ∀ k u, s.settlement k = some u → s.usage k = some u ∧ s.closed k = true

theorem settlement_step (safe : SettlementSafe s) (event : Step c m p s t) : SettlementSafe t := by
  have keep (k u) (old : s.settlement k = some u) : t.usage k = some u ∧ t.closed k = true :=
    ⟨usage_immutable event (safe k u old).1,closed_monotone event (safe k u old).2⟩
  cases event with
  | settle k incoming ready usage closed fresh =>
    intro j u record
    by_cases eq : j = k
    · subst j
      have same : u = incoming := by simpa [Weaver.LogicalMessageAuthority.update] using record.symm
      subst u; exact ⟨usage,closed⟩
    · exact keep j u (by simpa [Weaver.LogicalMessageAuthority.update,eq] using record)
  | _ => exact keep

theorem settlement_requires_same_usage_and_closure (h : Reachable c m p s) : SettlementSafe s := by
  induction h with
  | init => simp [SettlementSafe,initial]
  | next _ event ih => exact settlement_step ih event

def AllUsageBound (p : Profile c m) (s : State) : Prop :=
  ∀ k u, s.usage k = some u → u.message = k ∧ UsageBound p s u

theorem bound_survives (event : Step c m p s t) (bound : UsageBound p s u) : UsageBound p t u := by
  obtain ⟨manifest,account,history,closure,unit,amount,final,binding,installed⟩ := bound
  exact ⟨manifest,account,history,closure,unit,amount,final,binding,
    Weaver.FiniteStreamManifest.original_manifest_is_immutable (Weaver.DriverCompletionRecovery.projection (projection event)) installed⟩

theorem usage_bound_step (safe : AllUsageBound p s) (event : Step c m p s t) : AllUsageBound p t := by
  have keep (k u) (old : s.usage k = some u) : u.message = k ∧ UsageBound p t u :=
    ⟨(safe k u old).1,bound_survives event (safe k u old).2⟩
  cases event with
  | usage incoming ready closed authentic bound token stream fresh =>
    intro k u record
    by_cases eq : k = incoming.message
    · subst k
      have same : u = incoming := by simpa [Weaver.LogicalMessageAuthority.update] using record.symm
      subst u; exact ⟨rfl,bound⟩
    · exact keep k u (by simpa [Weaver.LogicalMessageAuthority.update,eq] using record)
  | _ => exact keep

theorem usage_bound (h : Reachable c m p s) : AllUsageBound p s := by
  induction h with
  | init => simp [AllUsageBound,initial]
  | next _ event ih => exact usage_bound_step ih event

def settledAmount (s : State) (k : Nat) : Nat :=
  match s.settlement k with | none => 0 | some u => u.amount

def accountSettled (c : Weaver.FiniteDomainMigration.Config) (s : State) (b : Nat) : Nat :=
  Weaver.FiniteDomainMigration.sumKeys c.keys (fun k => if c.budget (c.root k) = b then settledAmount s k else 0)

theorem settlement_covered_by_original_reservations (h : Reachable c m p s) (b) :
    accountSettled c s b ≤ Weaver.FiniteDomainMigration.booked c s.base.base.control.journal.head.payload b := by
  apply Weaver.FiniteStreamManifest.sum_mono
  intro k member
  by_cases account : c.budget (c.root k) = b
  · cases record : s.settlement k with
    | none => simp [settledAmount,Weaver.FiniteDomainMigration.allocation,account,record]
    | some u =>
      have same := (settlement_requires_same_usage_and_closure h) k u record
      have bound := (usage_bound h) k u same.1
      obtain ⟨manifest,acct,hist,cut,unit,amount,final,binding,installed⟩ := bound.2
      have inv := Weaver.FiniteStreamManifest.reachable_invariant (Weaver.DriverCompletionRecovery.reachable_projection (reachable_projection h))
      have retained := inv.manifests u.message binding installed
      have reserved := retained.2.2.2.2.2
      rw [retained.1,bound.1] at reserved
      simpa [settledAmount,Weaver.FiniteDomainMigration.allocation,account,record,reserved,bound.1] using amount
  · simp [Weaver.FiniteDomainMigration.allocation,account]

theorem account_settlement_never_exceeds_capacity (h : Reachable c m p s) (b) : accountSettled c s b ≤ c.capacity b := by
  have driver := reachable_projection h
  have finite := Weaver.DriverCompletionRecovery.reachable_projection driver
  have control := (Weaver.FiniteStreamManifest.reachable_invariant finite).control
  exact Nat.le_trans (settlement_covered_by_original_reservations h b)
    (Weaver.ComposedGatewayLifecycle.end_to_end_conservation control b)

theorem byte_affinity_survives_split_stores (h : Reachable c m p s) (key b) :
    (s.base.base.ranges key).offered b ≤ 1 := Weaver.DriverCompletionRecovery.no_duplicate_bytes (reachable_projection h) key b

theorem visible_monotone (event : Step c m p s t) (old : s.visible key = true) : t.visible key = true := by
  cases event with
  | publish j => by_cases eq : key = j <;> simp_all [Weaver.FiniteStreamManifest.setAt]
  | _ => exact old

theorem retired_monotone (event : Step c m p s t)
    (old : (s.base.base.control.journal.head.payload.messages k).retired = true) :
    (t.base.base.control.journal.head.payload.messages k).retired = true := by
  have step := Weaver.FiniteStreamManifest.range_step_projects (Weaver.DriverCompletionRecovery.projection (projection event))
  rcases Weaver.FiniteDomainMigration.local_step_or_stutter step k with localEvent | same
  · exact Weaver.LogicalMessageAuthority.retirement_is_monotone localEvent old
  · simpa [same] using old

theorem closed_admissions_sticky (event : Step c m p s t) (closed : s.closed key.1 = true) :
    (t.base.base.ranges key).admission = (s.base.base.ranges key).admission := by
  cases event with
  | advance next event results isolated blocked admit closedAdmissions => exact closedAdmissions key closed
  | finish e => by_cases eq : key = e.request.key <;> simp [Weaver.FiniteStreamManifest.setAt,eq]
  | quarantine e => by_cases eq : key = e.request.key <;> simp [Weaver.FiniteStreamManifest.setAt,Weaver.FiniteStreamManifest.closeRange,Weaver.FiniteStreamManifest.advanceRange,eq]
  | _ => rfl

def ClosedSafe (m : Weaver.FiniteStreamManifest.Manifest c) (s : State) : Prop :=
  ∀ k, s.closed k = true → (s.base.base.control.journal.head.payload.messages k).retired = true ∧ ClosureReady m s k

theorem closed_step (safe : ClosedSafe m s) (event : Step c m p s t) : ClosedSafe m t := by
  have keep (k) (closed : s.closed k = true) : (t.base.base.control.journal.head.payload.messages k).retired = true ∧ ClosureReady m t k := by
    have prior := safe k closed
    refine ⟨retired_monotone event prior.1,?_⟩
    intro r d record
    have same := closed_admissions_sticky event (key := (k,r)) closed
    have old : (s.base.base.ranges (k,r)).admission = some d := same.symm.trans record
    obtain ⟨inactive,e,decision,visible⟩ := prior.2 r d old
    exact ⟨Weaver.DriverCompletionRecovery.admitted_inactive_stays_inactive (Weaver.DriverCompletionRecovery.projection (projection event)) old inactive,
      e,decision_immutable event decision,visible_monotone event visible⟩
  cases event with
  | close k ready retired coverage =>
    intro j closed
    by_cases eq : j = k
    · subst j; exact ⟨retired,coverage⟩
    · exact keep j (by simpa [Weaver.LogicalMessageAuthority.update,eq] using closed)
  | _ => exact keep

theorem closed_means_retired_and_published (h : Reachable c m p s) : ClosedSafe m s := by
  induction h with
  | init => simp [ClosedSafe,initial]
  | next _ event ih => exact closed_step ih event

theorem settlement_has_published_terminal_coverage (h : Reachable c m p s)
    (record : s.settlement k = some u) : s.usage k = some u ∧
    (s.base.base.control.journal.head.payload.messages k).retired = true ∧ ClosureReady m s k := by
  have join := settlement_requires_same_usage_and_closure h k u record
  exact ⟨join.1,closed_means_retired_and_published h k join.2⟩

def DecisionSafe (s : State) : Prop :=
  ∀ key e, s.decisions key = some e → s.blobs (blobKey key e.isolation) = some e ∧
    ∃ d, (s.base.base.ranges key).admission = some d ∧ (s.base.base.ranges key).active = false

theorem decision_step (safe : DecisionSafe s) (event : Step c m p s t) : DecisionSafe t := by
  have keep (key e) (old : s.decisions key = some e) : t.blobs (blobKey key e.isolation) = some e ∧
      ∃ d, (t.base.base.ranges key).admission = some d ∧ (t.base.base.ranges key).active = false := by
    obtain ⟨blob,d,stored,inactive⟩ := safe key e old
    exact ⟨blob_immutable event blob,d,Weaver.FiniteStreamManifest.range_admission_is_immutable (Weaver.DriverCompletionRecovery.projection (projection event)) stored,
      Weaver.DriverCompletionRecovery.admitted_inactive_stays_inactive (Weaver.DriverCompletionRecovery.projection (projection event)) stored inactive⟩
  cases event with
  | finish incoming d ready blob kind fresh online exact pending freshResult live =>
    intro key e record
    by_cases eq : key = incoming.request.key
    · subst key
      have same : e = incoming := by simpa [Weaver.FiniteStreamManifest.setAt] using record.symm
      subst e
      exact ⟨blob,d,by simpa [Weaver.FiniteStreamManifest.setAt] using exact.2.2.2.1,by simp [Weaver.FiniteStreamManifest.setAt]⟩
    · exact keep key e (by simpa [Weaver.FiniteStreamManifest.setAt,eq] using record)
  | quarantine incoming d ready blob kind fresh isolated stored live =>
    intro key e record
    by_cases eq : key = incoming.request.key
    · subst key
      have same : e = incoming := by simpa [Weaver.FiniteStreamManifest.setAt] using record.symm
      subst e
      exact ⟨blob,d,by simpa [Weaver.FiniteStreamManifest.setAt,Weaver.FiniteStreamManifest.closeRange,Weaver.FiniteStreamManifest.advanceRange] using stored,by simp [Weaver.FiniteStreamManifest.setAt,Weaver.FiniteStreamManifest.closeRange]⟩
    · exact keep key e (by simpa [Weaver.FiniteStreamManifest.setAt,eq] using record)
  | _ => exact keep

theorem every_decision_has_durable_evidence_and_closed_original_slot (h : Reachable c m p s) : DecisionSafe s := by
  induction h with
  | init => simp [DecisionSafe,initial]
  | next _ event ih => exact decision_step ih event

theorem unpublished_decision_blocks_stream
    (decision : s.decisions prior = some e) (unpublished : s.visible prior = false)
    (same : m.stream prior.1 = m.stream key.1) : ¬ StreamPublished m s key := by
  intro all
  have shown := all prior e same decision
  simp_all

theorem evidence_bound_survives (event : Step c m p s t) (bound : EvidenceBound p s e) : EvidenceBound p t e := by
  obtain ⟨manifest,writers,buffers,tail,d,stored,epoch,incarnation⟩ := bound
  exact ⟨manifest,writers,buffers,(Weaver.DriverCompletionRecovery.original_tail_is_immutable (projection event) stored).trans tail,d,
    Weaver.FiniteStreamManifest.range_admission_is_immutable (Weaver.DriverCompletionRecovery.projection (projection event)) stored,epoch,incarnation⟩

def AllEvidenceBound (p : Profile c m) (s : State) : Prop :=
  ∀ key e, s.blobs key = some e → p.evidenceAuthentic e ∧
    key = blobKey e.request.key e.isolation ∧ EvidenceBound p s e

theorem evidence_binding_step (safe : AllEvidenceBound p s) (event : Step c m p s t) : AllEvidenceBound p t := by
  have keep (key e) (old : s.blobs key = some e) : p.evidenceAuthentic e ∧
      key = blobKey e.request.key e.isolation ∧ EvidenceBound p t e :=
    ⟨(safe key e old).1,(safe key e old).2.1,evidence_bound_survives event (safe key e old).2.2⟩
  cases event with
  | evidence incoming ready fresh authentic bound =>
    intro key e record
    by_cases eq : key = blobKey incoming.request.key incoming.isolation
    · subst key
      have same : e = incoming := by simpa [Weaver.FiniteStreamManifest.setAt] using record.symm
      subst e; exact ⟨authentic,rfl,bound⟩
    · exact keep key e (by simpa [Weaver.FiniteStreamManifest.setAt,eq] using record)
  | _ => exact keep

theorem evidence_stays_original_bound (h : Reachable c m p s) : AllEvidenceBound p s := by
  induction h with
  | init => simp [AllEvidenceBound,initial]
  | next _ event ih => exact evidence_binding_step ih event

theorem terminal_decision_has_authentic_original_evidence (h : Reachable c m p s)
    (decision : s.decisions key = some e) : p.evidenceAuthentic e ∧ EvidenceBound p s e := by
  have blob := (every_decision_has_durable_evidence_and_closed_original_slot h) key e decision
  have auth := evidence_stays_original_bound h _ e blob.1
  exact ⟨auth.1,auth.2.2⟩

def UsageAuthentic (p : Profile c m) (s : State) : Prop :=
  ∀ k u, s.usage k = some u → p.usageAuthentic u

theorem usage_authentic_step (safe : UsageAuthentic p s) (event : Step c m p s t) : UsageAuthentic p t := by
  cases event with
  | usage incoming ready closed authentic bound token stream fresh =>
    intro k u record
    by_cases eq : k = incoming.message
    · subst k
      have same : u = incoming := by simpa [Weaver.LogicalMessageAuthority.update] using record.symm
      subst u; exact authentic
    · exact safe k u (by simpa [Weaver.LogicalMessageAuthority.update,eq] using record)
  | _ => exact safe

theorem usage_is_authentic (h : Reachable c m p s) : UsageAuthentic p s := by
  induction h with
  | init => simp [UsageAuthentic,initial]
  | next _ event ih => exact usage_authentic_step ih event

theorem settlement_joins_authentic_final_usage (h : Reachable c m p s)
    (record : s.settlement k = some u) : p.usageAuthentic u ∧ u.message = k ∧ UsageBound p s u ∧
    (s.base.base.control.journal.head.payload.messages k).retired = true ∧ ClosureReady m s k := by
  have joined := settlement_has_published_terminal_coverage h record
  exact ⟨usage_is_authentic h k u joined.1,(usage_bound h k u joined.1).1,
    (usage_bound h k u joined.1).2,joined.2⟩

def ChargedSafe (s : State) : Prop :=
  ∀ k, (s.base.base.control.journal.head.payload.messages k).charged = true → ∃ u, s.settlement k = some u

theorem charged_step (safe : ChargedSafe s) (event : Step c m p s t) : ChargedSafe t := by
  have keep (k) (old : (s.base.base.control.journal.head.payload.messages k).charged = true) : ∃ u, t.settlement k = some u := by
    obtain ⟨u,record⟩ := safe k old
    exact ⟨u,settlement_immutable event record⟩
  cases event with
  | advance next event results isolated blocked admit closedAdmissions retire finalCost charged =>
    intro k hc
    have present := charged k hc
    cases record : s.settlement k with
    | none => exact False.elim (present record)
    | some u => exact ⟨u,rfl⟩
  | _ => exact keep

theorem charged_ledger_has_canonical_settlement (h : Reachable c m p s) : ChargedSafe s := by
  induction h with
  | init => simp [ChargedSafe,initial,Weaver.DriverCompletionRecovery.initial,Weaver.FiniteStreamManifest.initial,Weaver.ComposedGatewayLifecycle.initial,
      Weaver.AnchoredRecoveryAndEgress.Journal.initial,Weaver.FiniteDomainMigration.empty,Weaver.LogicalMessageAuthority.initial]
  | next _ event ih => exact charged_step ih event

theorem late_usage_never_changes_driver (s : State) (u : Usage) :
    ({ s with usage := Weaver.LogicalMessageAuthority.update s.usage u.message (some u) } : State).base = s.base := rfl

def DecisionIndexed (s : State) : Prop :=
  ∀ key e, s.decisions key = some e → e.request.key = key

theorem decision_index_step (safe : DecisionIndexed s) (event : Step c m p s t) : DecisionIndexed t := by
  cases event with
  | finish incoming =>
    intro key e record
    by_cases eq : key = incoming.request.key
    · subst key
      have same : e = incoming := by simpa [Weaver.FiniteStreamManifest.setAt] using record.symm
      subst e; rfl
    · exact safe key e (by simpa [Weaver.FiniteStreamManifest.setAt,eq] using record)
  | quarantine incoming =>
    intro key e record
    by_cases eq : key = incoming.request.key
    · subst key
      have same : e = incoming := by simpa [Weaver.FiniteStreamManifest.setAt] using record.symm
      subst e; rfl
    · exact safe key e (by simpa [Weaver.FiniteStreamManifest.setAt,eq] using record)
  | _ => exact safe

theorem decision_addresses_only_original_range (h : Reachable c m p s) : DecisionIndexed s := by
  induction h with
  | init => simp [DecisionIndexed,initial]
  | next _ event ih => exact decision_index_step ih event

theorem typed_evidence_key_is_injective (a b : Key) (x y : Bool)
    (same : blobKey a x = blobKey b y) : a = b ∧ x = y := by
  have first := congrArg Prod.fst same
  have second := congrArg Prod.snd same
  simp only [blobKey] at first second
  cases x <;> cases y <;> simp_all <;> try omega
  all_goals apply Prod.ext <;> omega

#print axioms decision_addresses_only_original_range
#print axioms typed_evidence_key_is_injective
#print axioms charged_ledger_has_canonical_settlement
#print axioms late_usage_never_changes_driver
#print axioms terminal_decision_has_authentic_original_evidence
#print axioms settlement_joins_authentic_final_usage
#print axioms settlement_has_published_terminal_coverage
#print axioms every_decision_has_durable_evidence_and_closed_original_slot
#print axioms unpublished_decision_blocks_stream
#print axioms no_visibility_from_prepared_blob
#print axioms settlement_requires_same_usage_and_closure
#print axioms decision_immutable
#print axioms usage_immutable
#print axioms settlement_immutable
#print axioms settlement_covered_by_original_reservations
#print axioms account_settlement_never_exceeds_capacity
#print axioms byte_affinity_survives_split_stores
end Weaver.WriterSettlementClosure
