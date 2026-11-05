-- SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
--
-- SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

import LogicalRangeRecovery
namespace Weaver.LlmRouting

structure View where
  catalog : Nat
  policy : Nat
  history : Nat
  endpoint : Nat
  deriving DecidableEq
structure Plan where
  root : Nat
  payload : Nat
  target : Nat
  view : View
  ranking : Nat
  manifest : Nat
  advised : Bool
  deriving DecidableEq
structure Dispatch where
  plan : Plan
  snapshot : View
  deriving DecidableEq
structure Config where
  root : Nat
  payload : Nat
  requirements : List Nat
  contextNeeded : Nat
  regionNeeded : Nat
  escrow : Nat
  catalog : Nat → List Nat
  supports : Nat → Nat → Nat → Prop
  contextLimit : Nat → Nat → Nat
  region : Nat → Nat → Nat
  costBound : Nat → Nat → Nat
  permits : Nat → Nat → Prop
  historyAllows : Nat → Nat → Prop
  historyRestricts : ∀ h m, historyAllows (h+1) m → historyAllows h m
  score : Nat → Nat → Nat
structure Owner where
  wireValid : Plan → Prop
  finalPolicyValid : Plan → View → Prop
  responseValid : Plan → Prop
structure State where
  catalog : Nat := 0
  policy : Nat := 0
  history : Nat := 0
  endpoint : Nat := 0
  metrics : Nat := 0
  unavailable : List Nat := []
  plans : List Plan := []
  dispatches : List Dispatch := []
  responses : List Plan := []
  unknown : Bool := false

def initial : State := {}
def view (s : State) : View := ⟨s.catalog,s.policy,s.history,s.endpoint⟩
def Eligible (c : Config) (s : State) (m : Nat) : Prop :=
  m ∈ c.catalog s.catalog ∧
  (∀ capability ∈ c.requirements, c.supports s.catalog m capability) ∧
  c.contextNeeded ≤ c.contextLimit s.catalog m ∧ c.region s.catalog m = c.regionNeeded ∧
  c.permits s.policy m ∧ c.historyAllows s.history m ∧
  c.costBound s.catalog m ≤ c.escrow ∧ m ∉ s.unavailable

def Best (c : Config) (s : State) (m : Nat) : Prop := Eligible c s m ∧
  ∀ n, Eligible c s n → c.score s.metrics m ≤ c.score s.metrics n

def Bound (c : Config) (p : Plan) : Prop := p.root = c.root ∧ p.payload = c.payload

def Audit (c : Config) (owner : Owner) (s : State) : Prop :=
  s.dispatches.length ≤ 1 ∧
  (∀ d ∈ s.dispatches, Bound c d.plan ∧ d.plan.view = d.snapshot ∧
    owner.wireValid d.plan ∧ owner.finalPolicyValid d.plan d.snapshot) ∧
  s.responses.length ≤ 1 ∧
  (∀ p ∈ s.responses, ∃ d ∈ s.dispatches, d.plan = p ∧ owner.responseValid p)

inductive Step (c : Config) (owner : Owner) : State → State → Prop where
  | propose (s m manifest) (best : Best c s m) : Step c owner s {s with
      plans := s.plans ++ [⟨c.root,c.payload,m,view s,s.metrics,manifest,false⟩]}
  | proposeAdvised (s m manifest) (eligible : Eligible c s m) : Step c owner s {s with
      plans := s.plans ++ [⟨c.root,c.payload,m,view s,s.metrics,manifest,true⟩]}
  | dispatch (s p) (stored : p ∈ s.plans) (bound : Bound c p) (current : p.view = view s)
      (eligible : Eligible c s p.target) (wire : owner.wireValid p)
      (policy : owner.finalPolicyValid p (view s)) (fresh : s.dispatches = []) :
      Step c owner s {s with dispatches := s.dispatches ++ [⟨p,view s⟩], unknown := true}
  | commitResponse (s p d) (emitted : d ∈ s.dispatches) (same : d.plan = p)
      (release : owner.responseValid p) (fresh : s.responses = []) :
      Step c owner s {s with responses := s.responses ++ [p]}
  | publishCatalog (s) : Step c owner s {s with catalog := s.catalog+1}
  | publishPolicy (s) : Step c owner s {s with policy := s.policy+1}
  | restrictHistory (s) : Step c owner s {s with history := s.history+1}
  | replaceEndpoint (s) : Step c owner s {s with endpoint := s.endpoint+1}
  | updateMetrics (s) : Step c owner s {s with metrics := s.metrics+1}
  | markUnavailable (s m) : Step c owner s {s with unavailable := m :: s.unavailable}
  | timeoutOrLostReply (s) : Step c owner s s

inductive Run (c : Config) (owner : Owner) : State → State → Prop where
  | refl (s) : Run c owner s s
  | next : Run c owner a b → Step c owner b d → Run c owner a d

theorem audit_step (h : Audit c owner s) (e : Step c owner s t) : Audit c owner t := by
  rcases h with ⟨count,audit,responseCount,responses⟩
  cases e with
  | dispatch p stored bound current eligible wire policy fresh =>
    refine ⟨by simp [fresh],?_,responseCount,?_⟩
    · intro d member
      have eq : d = ⟨p,view s⟩ := by simpa [fresh] using member
      subst d; exact ⟨bound,current,wire,policy⟩
    · intro p' hp
      rcases responses p' hp with ⟨d,member,same,valid⟩
      exact ⟨d,List.mem_append.mpr (Or.inl member),same,valid⟩
  | commitResponse p d emitted same release fresh =>
    refine ⟨count,audit,by simp [fresh],?_⟩
    intro p' member
    have eq : p' = p := by simpa [fresh] using member
    subst p'; exact ⟨d,emitted,same,release⟩
  | _ => exact ⟨count,audit,responseCount,responses⟩

theorem initialized_audit (run : Run c owner initial s) : Audit c owner s := by
  induction run with
  | refl => simp [Audit,initial]
  | next prior e ih => exact audit_step ih e

theorem actual_dispatch_rechecks_target (e : Step c owner s t)
    (changed : t.dispatches ≠ s.dispatches) :
    ∃ p, p ∈ s.plans ∧ Bound c p ∧ p.view = view s ∧ Eligible c s p.target ∧
      owner.wireValid p ∧ owner.finalPolicyValid p (view s) ∧ s.dispatches = [] := by
  cases e with
  | dispatch p stored bound current eligible wire policy fresh =>
    exact ⟨p,stored,bound,current,eligible,wire,policy,fresh⟩
  | _ => exact False.elim (changed rfl)

theorem ranked_proposal_has_eligible_minimum (e : Step c owner s t)
    (member : p ∈ t.plans) (fresh : p ∉ s.plans) (ranked : p.advised = false) :
    Bound c p ∧ Best c s p.target ∧ p.view = view s ∧ p.ranking = s.metrics := by
  cases e with
  | propose m manifest best =>
    rcases List.mem_append.mp member with old | new
    · exact False.elim (fresh old)
    · have eq : p = ⟨c.root,c.payload,m,view s,s.metrics,manifest,false⟩ := by simpa using new
      subst p; exact ⟨⟨rfl,rfl⟩,best,rfl,rfl⟩
  | proposeAdvised m manifest eligible =>
    rcases List.mem_append.mp member with old | new
    · exact False.elim (fresh old)
    · have eq : p = ⟨c.root,c.payload,m,view s,s.metrics,manifest,true⟩ := by simpa using new
      subst p; simp at ranked
  | _ => exact False.elim (fresh member)

theorem every_new_proposal_is_eligible (e : Step c owner s t)
    (member : p ∈ t.plans) (fresh : p ∉ s.plans) : Bound c p ∧ Eligible c s p.target := by
  cases e with
  | propose m manifest best =>
    rcases List.mem_append.mp member with old | new
    · exact False.elim (fresh old)
    · have eq : p = ⟨c.root,c.payload,m,view s,s.metrics,manifest,false⟩ := by simpa using new
      subst p; exact ⟨⟨rfl,rfl⟩,best.1⟩
  | proposeAdvised m manifest eligible =>
    rcases List.mem_append.mp member with old | new
    · exact False.elim (fresh old)
    · have eq : p = ⟨c.root,c.payload,m,view s,s.metrics,manifest,true⟩ := by simpa using new
      subst p; exact ⟨⟨rfl,rfl⟩,eligible⟩
  | _ => exact False.elim (fresh member)

theorem selected_cost_within_original_escrow (eligible : Eligible c s m) :
    c.costBound s.catalog m ≤ c.escrow := eligible.2.2.2.2.2.2.1

theorem soft_metrics_do_not_change_authority (s : State) :
    view {s with metrics := s.metrics+1} = view s := rfl

theorem history_denial_cannot_be_undone (c : Config) (denied : ¬ c.historyAllows h m) :
    ¬ c.historyAllows (h+1) m := fun allowed => denied (c.historyRestricts h m allowed)

theorem dispatch_record_never_disappears (e : Step c owner s t) : s.dispatches <+: t.dispatches := by
  cases e with
  | dispatch => exact List.prefix_append _ _
  | _ => exact List.prefix_refl _

theorem one_provider_admission_per_root (run : Run c owner initial s) : s.dispatches.length ≤ 1 :=
  (initialized_audit run).1

theorem one_response_source_per_root (run : Run c owner initial s) : s.responses.length ≤ 1 :=
  (initialized_audit run).2.2.1

-- This proof layer is pre-admission routing. The existing effect proof starts
-- after the selected route and provider encoding are bound and admitted.
structure AdmissionBridge (r : Config) (source : Weaver.GatewayHeadCAS.Config)
    (policy : Weaver.GatewayHeadCAS.Owner) where
  admission : Weaver.BrokerConsumptionQueue.Admission source policy
  sameRoot : r.root = admission.key
  samePayload : r.payload = source.payload admission.key
  sameEscrow : r.escrow = source.cost admission.key
  selected : Plan
  before : State
  after : State
  routerOwner : Owner
  routingEvent : Step r routerOwner before after
  wasDispatched : after.dispatches ≠ before.dispatches
  selectedEvent : ⟨selected,view before⟩ ∈ after.dispatches
  sameTarget : ∀ h, admission.before.head = some h → h.route = selected.target
  sameManifest : routerOwner.wireValid selected

theorem selected_route_fits_source_reservation (bridge : AdmissionBridge r source policy) :
    r.costBound bridge.before.catalog bridge.selected.target ≤ source.cost bridge.admission.key := by
  rcases bridge with ⟨admission,root,payload,escrow,selected,before,after,routerOwner,event,changed,member,target,wire⟩
  cases event with
  | dispatch p stored bound current eligible valid finalPolicy fresh =>
    have eq : (⟨selected,view before⟩ : Dispatch) = ⟨p,view before⟩ := by simpa [fresh] using member
    have same : selected = p := congrArg Dispatch.plan eq
    subst selected
    rw [← escrow]
    exact selected_cost_within_original_escrow eligible
  | _ => exact False.elim (changed rfl)

theorem original_account_capacity_survives (bridge : AdmissionBridge r source policy) (account) :
    Weaver.FiniteDomainMigration.booked source bridge.admission.after.base account ≤ source.capacity account :=
  Weaver.GatewayHeadCAS.shared_budget_is_bounded (.next bridge.admission.prior bridge.admission.event) account

theorem original_claim_is_not_recreated (bridge : AdmissionBridge r source policy) :
    (bridge.admission.after.base.messages bridge.admission.key).claims ≤ 1 ∧
    (bridge.admission.after.base.messages bridge.admission.key).sends ≤ 1 :=
  Weaver.GatewayHeadCAS.original_claim_and_offer_once (.next bridge.admission.prior bridge.admission.event) bridge.admission.key

theorem duplicate_root_dispatch_counterexample (c : Config) (owner : Owner) (p : Plan) :
    ¬ Audit c owner {dispatches := [⟨p,p.view⟩,⟨p,p.view⟩]} := by
  intro h; have bad := h.1; simp at bad

theorem stale_catalog_plan_counterexample (p : Plan) :
    p.view ≠ {p.view with catalog := p.view.catalog+1} := by
  intro eq; have bad := congrArg View.catalog eq; simp at bad

#print axioms selected_route_fits_source_reservation
#print axioms every_new_proposal_is_eligible
#print axioms initialized_audit
#print axioms actual_dispatch_rechecks_target
#print axioms ranked_proposal_has_eligible_minimum
#print axioms selected_cost_within_original_escrow
#print axioms soft_metrics_do_not_change_authority
#print axioms history_denial_cannot_be_undone
#print axioms dispatch_record_never_disappears
#print axioms one_provider_admission_per_root
#print axioms one_response_source_per_root
#print axioms original_account_capacity_survives
#print axioms original_claim_is_not_recreated
#print axioms duplicate_root_dispatch_counterexample
#print axioms stale_catalog_plan_counterexample
end Weaver.LlmRouting
