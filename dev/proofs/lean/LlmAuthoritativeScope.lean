-- SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
--
-- SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

import LlmSemanticContract
namespace Weaver.LlmAuthoritativeScope

-- The table belongs to canonical task admission, never to a provider adapter.
structure Contract where
  payload : Weaver.LlmSemanticContract.Payload
  document : Bool
  maxArguments : Nat
  maxCalls : Nat
  targets : List Nat
  deriving DecidableEq
structure Registry where
  commitment : Nat → Nat
  resolve : Nat → Option Contract

def emptyContract : Contract := ⟨⟨0,[],[],0,0,false,1⟩,false,0,0,[]⟩
def contract (_source : Weaver.GatewayHeadCAS.Config) (registry : Registry) (key : Nat) : Contract :=
  (registry.resolve (registry.commitment key)).getD emptyContract

def semantics (source : Weaver.GatewayHeadCAS.Config) (registry : Registry) (key : Nat) : Weaver.LlmSemanticContract.Semantics :=
  { toPayload := {(contract source registry key).payload with input := source.payload key},
    validatedDocument := (contract source registry key).document,
    historyDomain := source.history (source.root key), budgetDomain := source.budget (source.root key) }
def scopeFor (source : Weaver.GatewayHeadCAS.Config) (registry : Registry) (key : Nat) (a : Weaver.LlmAttemptLedger.Attempt) : Weaver.LlmSemanticContract.Scope :=
  ⟨key,a.id,a.plan.target,a.plan.manifest,semantics source registry key,(contract source registry key).maxArguments,(contract source registry key).maxCalls⟩
structure Record where
  key : Nat
  domain : Nat
  commitment : Nat
  payload : Nat
  claimToken : Nat
  claimStream : Nat
  semantics : Weaver.LlmSemanticContract.Semantics
  maxArguments : Nat
  maxCalls : Nat
  targets : List Nat
  deriving DecidableEq

def recordFor (source : Weaver.GatewayHeadCAS.Config) (registry : Registry) (key : Nat) (h : Weaver.GatewayHeadCAS.Head) : Record :=
  ⟨key,source.root key,registry.commitment key,source.payload key,h.claimToken,h.claimStream,semantics source registry key,
    (contract source registry key).maxArguments,(contract source registry key).maxCalls,(contract source registry key).targets⟩

structure Image where
  head : Weaver.GatewayHeadCAS.View
  boot : Nat
  route : Weaver.LlmRouting.View
structure Ticket where
  id : Nat
  child : Weaver.LlmAttemptLedger.Attempt
  scope : Weaver.LlmSemanticContract.Scope
  image : Image
structure Use where
  ticket : Ticket
  actual : Image
  record : Record
structure State where
  roots : Weaver.GatewayHeadCAS.State := Weaver.GatewayHeadCAS.initial
  children : Weaver.LlmAttemptLedger.State := Weaver.LlmAttemptLedger.initial
  record : Option Record := none
  boot : Nat := 0
  recovered : Bool := true
  tickets : List Ticket := []
  semantic : Nat → Weaver.LlmSemanticContract.State := fun _ => Weaver.LlmSemanticContract.initial
  uses : List Use := []

def initial : State := {}
def image (s : State) (h : Weaver.GatewayHeadCAS.Head) : Image := ⟨Weaver.GatewayHeadCAS.view s.roots h,s.boot,Weaver.LlmRouting.view s.children.routes⟩

def Origin (source : Weaver.GatewayHeadCAS.Config) (registry : Registry) (key : Nat) (s : State) (record : Record) (h : Weaver.GatewayHeadCAS.Head) : Prop :=
  s.record = some record ∧ s.roots.head = some h ∧ h.key = key ∧ Weaver.GatewayHeadCAS.Canonical source s.roots h ∧
  record = recordFor source registry key h

def Current (source : Weaver.GatewayHeadCAS.Config) (registry : Registry) (routing : Weaver.LlmRouting.Config) (rootOwner : Weaver.GatewayHeadCAS.Owner)
    (s : State) (t : Ticket) (record : Record) (h : Weaver.GatewayHeadCAS.Head) : Prop :=
  Origin source registry routing.root s record h ∧ s.recovered = true ∧ s.roots.authorityOnline = true ∧
  t.image = image s h ∧ t.scope = scopeFor source registry routing.root t.child ∧
  t.child ∈ s.children.attempts ∧ t.child.plan.root = routing.root ∧
  t.child.plan.payload = source.payload routing.root ∧ t.child.plan.target ∈ (contract source registry routing.root).targets ∧
  s.roots.base.restricted (source.history (source.root routing.root)) = false ∧
  (s.roots.base.messages routing.root).retired = false ∧
  (s.roots.base.messages routing.root).charged = false ∧ rootOwner.policyAllows h s.roots.base ∧
  rootOwner.headReadValid (Weaver.GatewayHeadCAS.view s.roots h) ∧
  (s.roots.base.messages routing.root).sends = 1 ∧ registry.resolve (registry.commitment routing.root) ≠ none

def BoundUse (source : Weaver.GatewayHeadCAS.Config) (registry : Registry) (key : Nat) (u : Use) : Prop :=
  u.ticket.image = u.actual ∧ u.ticket.scope = scopeFor source registry key u.ticket.child ∧
  u.actual.head.head.key = key ∧ u.record = recordFor source registry key u.actual.head.head

def Audit (source : Weaver.GatewayHeadCAS.Config) (registry : Registry) (key : Nat) (s : State) : Prop :=
  ∀ u ∈ s.uses, BoundUse source registry key u

theorem useBound (current : Current source registry routing rootOwner s t record h) :
    BoundUse source registry routing.root ⟨t,image s h,record⟩ := by
  rcases current with ⟨⟨stored,held,key,canonical,origin⟩,recovered,online,exact,scope,rest⟩
  exact ⟨exact,scope,key,origin⟩

structure Owner where
  recoveryValid : Nat → Prop

inductive Step (source : Weaver.GatewayHeadCAS.Config) (registry : Registry) (routing : Weaver.LlmRouting.Config) (profile : Weaver.LlmAttemptLedger.Profile)
    (rootOwner : Weaver.GatewayHeadCAS.Owner) (childOwner : Weaver.LlmAttemptLedger.Owner) (codec : Weaver.LlmSemanticContract.Owner) (owner : Owner) : State → State → Prop where
  | rootAdvance (s next) (event : Weaver.GatewayHeadCAS.Step source rootOwner s.roots next)
      (settlement : (next.base.messages routing.root).charged ≠ (s.roots.base.messages routing.root).charged → s.children.closed = true) :
      Step source registry routing profile rootOwner childOwner codec owner s {s with roots := next}
  | childAdvance (s next) (event : Weaver.LlmAttemptLedger.Step routing profile childOwner s.children next)
      (noCall : next.calls = s.children.calls)
      (escrow : routing.escrow = source.cost routing.root) :
      Step source registry routing profile rootOwner childOwner codec owner s {s with children := next}
  | register (s h) (empty : s.record = none) (held : s.roots.head = some h) (key : h.key = routing.root)
      (canonical : Weaver.GatewayHeadCAS.Canonical source s.roots h) (online : s.roots.authorityOnline = true)
      (recovered : s.recovered = true) (authenticated : rootOwner.headReadValid (Weaver.GatewayHeadCAS.view s.roots h))
      (known : registry.resolve (registry.commitment routing.root) ≠ none) :
      Step source registry routing profile rootOwner childOwner codec owner s {s with record := some (recordFor source registry routing.root h)}
  | observe (s t record h) (current : Current source registry routing rootOwner s t record h)
      (fresh : t.id = s.tickets.length) :
      Step source registry routing profile rootOwner childOwner codec owner s {s with tickets := s.tickets ++ [t]}
  | semanticData (s a next) (registered : a ∈ s.children.attempts)
      (event : Weaver.LlmSemanticContract.Step (scopeFor source registry routing.root a) codec (s.semantic a.id) next)
      (noConsume : next.consumed = (s.semantic a.id).consumed)
      (noOutput : next.outputs = (s.semantic a.id).outputs) (noProposal : next.proposals = (s.semantic a.id).proposals) :
      Step source registry routing profile rootOwner childOwner codec owner s
        {s with semantic := fun i => if i = a.id then next else s.semantic i}
  | invoke (s t record h) (call : Weaver.LlmSemanticContract.ChildCall routing profile childOwner) (wire next)
      (registered : t ∈ s.tickets) (current : Current source registry routing rootOwner s t record h)
      (escrow : routing.escrow = source.cost routing.root) (sameBefore : call.before = s.children) (sameChild : call.record = t.child) (worker : call.worker = s.boot)
      (bridge : Weaver.LlmSemanticContract.EncodingBridge (scopeFor source registry routing.root t.child) codec call wire)
      (prior : Weaver.LlmSemanticContract.Run (scopeFor source registry routing.root t.child) codec Weaver.LlmSemanticContract.initial (s.semantic t.child.id))
      (semanticEvent : Weaver.LlmSemanticContract.Step (scopeFor source registry routing.root t.child) codec (s.semantic t.child.id) next)
      (started : next.consumed ≠ (s.semantic t.child.id).consumed) :
      Step source registry routing profile rootOwner childOwner codec owner s {s with
        children := call.after,
        semantic := fun i => if i = t.child.id then next else s.semantic i,
        uses := s.uses ++ [⟨t,image s h,record⟩]}
  | semanticUse (s t record h next) (registered : t ∈ s.tickets)
      (current : Current source registry routing rootOwner s t record h)
      (called : s.children.calls t.child.id = 1)
      (prior : Weaver.LlmSemanticContract.Run (scopeFor source registry routing.root t.child) codec Weaver.LlmSemanticContract.initial (s.semantic t.child.id))
      (event : Weaver.LlmSemanticContract.Step (scopeFor source registry routing.root t.child) codec (s.semantic t.child.id) next)
      (noConsume : next.consumed = (s.semantic t.child.id).consumed) :
      Step source registry routing profile rootOwner childOwner codec owner s {s with
        semantic := fun i => if i = t.child.id then next else s.semantic i,
        uses := s.uses ++ [⟨t,image s h,record⟩]}
  | restart (s) : Step source registry routing profile rootOwner childOwner codec owner s {s with
      boot := s.boot+1, recovered := false,
      children := {s.children with epoch := s.children.epoch+1, retired := fun _ => true},
      semantic := fun i => {s.semantic i with epoch := (s.semantic i).epoch+1, retired := true}}
  | recover (s) (valid : owner.recoveryValid s.boot) :
      Step source registry routing profile rootOwner childOwner codec owner s {s with recovered := true}
  | lostReplyOrTimeout (s) : Step source registry routing profile rootOwner childOwner codec owner s s

inductive Run (source : Weaver.GatewayHeadCAS.Config) (registry : Registry) (routing : Weaver.LlmRouting.Config) (profile : Weaver.LlmAttemptLedger.Profile)
    (rootOwner : Weaver.GatewayHeadCAS.Owner) (childOwner : Weaver.LlmAttemptLedger.Owner) (codec : Weaver.LlmSemanticContract.Owner) (owner : Owner) : State → State → Prop where
  | refl (s) : Run source registry routing profile rootOwner childOwner codec owner s s
  | next : Run source registry routing profile rootOwner childOwner codec owner a b →
      Step source registry routing profile rootOwner childOwner codec owner b d →
      Run source registry routing profile rootOwner childOwner codec owner a d

theorem root_projection (run : Run source registry routing profile rootOwner childOwner codec owner initial s) :
    Weaver.GatewayHeadCAS.Run source rootOwner Weaver.GatewayHeadCAS.initial s.roots := by
  induction run with
  | refl => exact .refl _
  | next prior event ih =>
    cases event with
    | rootAdvance next sourceEvent settlement => exact .next ih sourceEvent
    | _ => exact ih

theorem child_projection (run : Run source registry routing profile rootOwner childOwner codec owner initial s) :
    Weaver.LlmAttemptLedger.Run routing profile childOwner Weaver.LlmAttemptLedger.initial s.children := by
  induction run with
  | refl => exact .refl _
  | next prior event ih =>
    cases event with
    | childAdvance next sourceEvent noCall escrow => exact .next ih sourceEvent
    | invoke t record h call wire next registered current escrow sameBefore sameChild worker bridge semanticPrior semanticEvent started =>
      have e := Weaver.LlmSemanticContract.refines_actual_child_invocation call
      rw [sameBefore] at e
      exact .next ih e
    | restart => exact .next ih (.restart _)
    | _ => exact ih

theorem audit_step (safe : Audit source registry routing.root s)
    (event : Step source registry routing profile rootOwner childOwner codec owner s t) : Audit source registry routing.root t := by
  cases event with
  | invoke ticket record h call wire next registered current escrow sameBefore sameChild worker bridge prior semanticEvent started =>
    intro u member; rcases List.mem_append.mp member with old | fresh
    · exact safe u old
    · have same : u = ⟨ticket,image s h,record⟩ := by simpa using fresh
      subst u; exact useBound current
  | semanticUse ticket record h next registered current called prior event noConsume =>
    intro u member; rcases List.mem_append.mp member with old | fresh
    · exact safe u old
    · have same : u = ⟨ticket,image s h,record⟩ := by simpa using fresh
      subst u; exact useBound current
  | _ => exact safe

theorem initialized_audit (run : Run source registry routing profile rootOwner childOwner codec owner initial s) :
    Audit source registry routing.root s := by
  induction run with
  | refl => simp [Audit,initial]
  | next prior event ih => exact audit_step ih event

theorem uses_keep_registered_record (run : Run source registry routing profile rootOwner childOwner codec owner initial s) :
    ∀ u ∈ s.uses, s.record = some u.record := by
  induction run with
  | refl => simp [initial]
  | next prior event ih =>
    cases event with
    | invoke ticket record h call wire next registered current escrow sameBefore sameChild worker bridge semPrior semEvent started =>
      intro u member; rcases List.mem_append.mp member with old | fresh
      · exact ih u old
      · have same := List.mem_singleton.mp fresh
        subst u; exact current.1.1
    | semanticUse ticket record h next registered current called semPrior semEvent noConsume =>
      intro u member; rcases List.mem_append.mp member with old | fresh
      · exact ih u old
      · have same := List.mem_singleton.mp fresh
        subst u; exact current.1.1
    | register h empty held key canonical online recovered authenticated known =>
      intro u member; have original := ih u member; simp_all
    | _ => exact ih

theorem all_uses_have_authoritative_scope (run : Run source registry routing profile rootOwner childOwner codec owner initial s)
    (member : u ∈ s.uses) : u.ticket.scope = scopeFor source registry routing.root u.ticket.child :=
  (initialized_audit run u member).2.1

theorem all_uses_keep_original_domains (run : Run source registry routing profile rootOwner childOwner codec owner initial s)
    (member : u ∈ s.uses) :
    u.ticket.scope.semantics.budgetDomain = source.budget (source.root routing.root) ∧
    u.ticket.scope.semantics.historyDomain = source.history (source.root routing.root) := by
  rw [all_uses_have_authoritative_scope run member]; exact ⟨rfl,rfl⟩

theorem all_uses_keep_response_mode (run : Run source registry routing profile rootOwner childOwner codec owner initial s)
    (member : u ∈ s.uses) : u.ticket.scope.semantics.validatedDocument = (contract source registry routing.root).document := by
  rw [all_uses_have_authoritative_scope run member]; rfl

theorem all_uses_keep_original_claim (run : Run source registry routing profile rootOwner childOwner codec owner initial s)
    (member : u ∈ s.uses) :
    u.record.claimToken = u.actual.head.head.claimToken ∧ u.record.claimStream = u.actual.head.head.claimStream := by
  rw [(initialized_audit run u member).2.2.2]; exact ⟨rfl,rfl⟩

theorem record_cannot_be_replaced (event : Step source registry routing profile rootOwner childOwner codec owner s t)
    (stored : s.record = some record) : t.record = some record := by
  cases event with
  | register h empty held key canonical online recovered authenticated known => simp_all
  | _ => exact stored

theorem current_scope_is_unique (a : Current source registry routing rootOwner s t record h)
    (b : Current source registry routing rootOwner s t' record' h') (same : t.child = t'.child) : t.scope = t'.scope := by
  rw [a.2.2.2.2.1,b.2.2.2.2.1,same]

theorem stale_image_cannot_be_used (current : Current source registry routing rootOwner s t record h)
    (stale : t.image ≠ image s h) : False := stale current.2.2.2.1

theorem restricted_original_history_blocks_use (current : Current source registry routing rootOwner s t record h)
    (restricted : s.roots.base.restricted (source.history (source.root routing.root)) = true) : False := by
  rcases current with ⟨origin,recovered,online,exact,scope,registered,root,payload,target,history,rest⟩
  simp_all

theorem original_claim_stays_unique (run : Run source registry routing profile rootOwner childOwner codec owner initial s) :
    (s.roots.base.messages routing.root).claims ≤ 1 ∧ (s.roots.base.messages routing.root).sends ≤ 1 :=
  Weaver.GatewayHeadCAS.original_claim_and_offer_once (root_projection run) routing.root

theorem child_budget_stays_bounded (run : Run source registry routing profile rootOwner childOwner codec owner initial s) :
    Weaver.LlmAttemptLedger.total s.children.attempts ≤ routing.escrow := Weaver.LlmAttemptLedger.finite_attempt_budget_is_bounded (child_projection run)

theorem original_account_capacity_stays_booked (run : Run source registry routing profile rootOwner childOwner codec owner initial s) (account) :
    Weaver.FiniteDomainMigration.booked source s.roots.base account ≤ source.capacity account :=
  Weaver.GatewayHeadCAS.shared_budget_is_bounded (root_projection run) account

theorem unknown_usage_blocks_root_settlement (run : Run source registry routing profile rootOwner childOwner codec owner initial s)
    (registered : a ∈ s.children.attempts) (unknown : s.children.usage a.id = none)
    (event : Step source registry routing profile rootOwner childOwner codec owner s t) :
    (t.roots.base.messages routing.root).charged = (s.roots.base.messages routing.root).charged := by
  cases event with
  | rootAdvance next sourceEvent settlement =>
    by_cases same : (next.base.messages routing.root).charged = (s.roots.base.messages routing.root).charged
    · exact same
    · have closed := settlement same
      have notClosed := Weaver.LlmAttemptLedger.unknown_usage_prevents_close (child_projection run) registered unknown
      simp_all
  | _ => rfl

theorem equal_input_does_not_identify_response_contract :
    ∃ a b : Weaver.LlmSemanticContract.Semantics, a.input = b.input ∧ a.validatedDocument ≠ b.validatedDocument := by
  exact ⟨⟨⟨10,[],[],0,0,false,1⟩,true,3,5⟩,⟨⟨10,[],[],0,0,false,1⟩,false,3,5⟩,rfl,by decide⟩

theorem same_commitment_resolves_same_contract (same : registry.commitment key = registry.commitment other) :
    contract source registry key = contract source registry other := by simp [contract,same]

theorem missing_contract_blocks_use (current : Current source registry routing rootOwner s t record h)
    (missing : registry.resolve (registry.commitment routing.root) = none) : False := by
  rcases current with ⟨origin,recovered,online,exact,scope,registered,root,payload,target,history,retired,charged,policy,read,sent,known⟩
  exact known missing

theorem allocations_fit_source_allowance (run : Run source registry routing profile rootOwner childOwner codec owner initial s) :
    Weaver.LlmAttemptLedger.total s.children.attempts ≤ source.cost routing.root := by
  induction run with
  | refl => simp [initial,Weaver.LlmAttemptLedger.initial,Weaver.LlmAttemptLedger.total]
  | next prior event ih =>
    cases event with
    | childAdvance next childEvent noCall escrow =>
      have bound := Weaver.LlmAttemptLedger.finite_attempt_budget_is_bounded (.next (child_projection prior) childEvent)
      simpa [escrow] using bound
    | invoke ticket record h call wire next registered current escrow sameBefore sameChild worker bridge semPrior semEvent started =>
      simpa [Weaver.LlmSemanticContract.ChildCall.after,sameBefore] using ih
    | _ => exact ih

theorem actual_wire_keeps_source_context
    (bridge : Weaver.LlmSemanticContract.EncodingBridge (scopeFor source registry key child) codec call wire) :
    wire.budgetDomain = source.budget (source.root key) ∧
    wire.historyDomain = source.history (source.root key) ∧
    wire.validatedDocument = (contract source registry key).document := by
  rcases bridge.valid with ⟨root,attempt,target,manifest,digest,decoded,names,candidates,history,budget,mode⟩
  exact ⟨budget,history,mode⟩

theorem proposal_keeps_source_contract
    (run : Weaver.LlmSemanticContract.Run (scopeFor source registry key child) codec Weaver.LlmSemanticContract.initial state)
    (member : proposal ∈ state.proposals) :
    proposal.root = key ∧ proposal.tool ∈ (contract source registry key).payload.tools ∧
    proposal.arguments.length ≤ (contract source registry key).maxArguments := by
  have bound := (Weaver.LlmSemanticContract.initialized_audit run).2.2.1 proposal member
  exact ⟨bound.1,bound.2.2.1,bound.2.2.2.1⟩

-- Reuse the actual upstream admission, not a caller's payload-only claim.
theorem child_total_fits_original_escrow (sponsor : Weaver.LlmAttemptLedger.RootSponsor routing profile source rootOwner childOwner)
    (run : Run source registry routing profile rootOwner childOwner codec owner initial s) :
    Weaver.LlmAttemptLedger.total s.children.attempts ≤ source.cost sponsor.admission.key := by
  rw [← sponsor.allowance]; exact child_budget_stays_bounded run

#print axioms uses_keep_registered_record
#print axioms actual_wire_keeps_source_context
#print axioms proposal_keeps_source_contract
#print axioms equal_input_does_not_identify_response_contract
#print axioms same_commitment_resolves_same_contract
#print axioms missing_contract_blocks_use
#print axioms allocations_fit_source_allowance
#print axioms initialized_audit
#print axioms all_uses_have_authoritative_scope
#print axioms all_uses_keep_original_domains
#print axioms all_uses_keep_response_mode
#print axioms all_uses_keep_original_claim
#print axioms record_cannot_be_replaced
#print axioms current_scope_is_unique
#print axioms stale_image_cannot_be_used
#print axioms restricted_original_history_blocks_use
#print axioms original_claim_stays_unique
#print axioms child_budget_stays_bounded
#print axioms original_account_capacity_stays_booked
#print axioms unknown_usage_blocks_root_settlement
#print axioms child_total_fits_original_escrow
end Weaver.LlmAuthoritativeScope
