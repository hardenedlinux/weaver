-- SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
--
-- SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

import LlmRegistryPublication
namespace Weaver.LlmRecoveryCAS

-- Policy generation includes external history/policy writes before their effective acknowledgement.
structure Cut where
  image : Weaver.LlmRegistryPublication.Image
  policyGeneration : Nat
  deriving DecidableEq
structure Observation where
  binding : Option Weaver.LlmRegistryPublication.Binding := none
  execution : Option Weaver.LlmRegistryPublication.Image := none
  policy : Option (Nat × Bool) := none
structure Request where
  id : Nat
  permit : Weaver.LlmRegistryPublication.Permit
  cut : Cut
  effectCommitment : Nat
  deriving DecidableEq
structure Decision where
  request : Request
  actual : Cut
  policyAllowed : Bool
  deriving DecidableEq
structure State where
  publication : Weaver.LlmRegistryPublication.State := Weaver.LlmRegistryPublication.initial
  policyGeneration : Nat := 0
  policyAllowed : Bool := true
  observation : Observation := {}
  requests : List Request := []
  decisions : List Decision := []
  confirmations : List Decision := []
def initial : State := {}
structure Owner where
  commitValid : Request → Cut → Weaver.LlmAuthoritativeScope.State → Weaver.LlmAuthoritativeScope.State → Prop

def cut (s : State) (b : Weaver.LlmRegistryPublication.Binding) : Cut :=
  ⟨Weaver.LlmRegistryPublication.image s.publication b,s.policyGeneration⟩
def Fresh (s : State) (q : Request) : Prop := ∀ d ∈ s.decisions, d.request.id ≠ q.id
def Current (s : State) (q : Request) : Prop :=
  q.cut = cut s q.permit.image.binding ∧ s.policyAllowed = true ∧ Weaver.LlmRegistryPublication.Gate s.publication q.permit

def committedPublication (s : Weaver.LlmRegistryPublication.State) (next : Weaver.LlmAuthoritativeScope.State) : Weaver.LlmRegistryPublication.State :=
  {s with execution := next, revision := s.revision+1, active := false, projection := none}
def Audit (s : State) : Prop :=
  ∀ d ∈ s.decisions, d.request.cut = d.actual ∧ d.policyAllowed = true

inductive Step (source : Weaver.GatewayHeadCAS.Config) (registry : Weaver.LlmAuthoritativeScope.Registry) (routing : Weaver.LlmRouting.Config) (profile : Weaver.LlmAttemptLedger.Profile)
    (rootOwner : Weaver.GatewayHeadCAS.Owner) (childOwner : Weaver.LlmAttemptLedger.Owner) (codec : Weaver.LlmSemanticContract.Owner) (scopeOwner : Weaver.LlmAuthoritativeScope.Owner)
    (publicationOwner : Weaver.LlmRegistryPublication.Owner) (owner : Owner) (tenant vector : Nat) : State → State → Prop where
  | readBinding (s b) (bound : s.publication.intent = some b) :
      Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner owner tenant vector s {s with observation := {s.observation with binding := some b}}
  | readExecution (s b) (bound : s.publication.intent = some b) :
      Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner owner tenant vector s {s with observation := {s.observation with execution := some (Weaver.LlmRegistryPublication.image s.publication b)}}
  | readPolicy (s) :
      Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner owner tenant vector s {s with observation := {s.observation with policy := some (s.policyGeneration,s.policyAllowed)}}
  | restoreObservation (s old) :
      Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner owner tenant vector s {s with observation := old}
  | prepare (s p i generation effectCommitment) (binding : s.observation.binding = some i.binding)
      (execution : s.observation.execution = some i) (policy : s.observation.policy = some (generation,true))
      (issued : p ∈ s.publication.permits) (image : p.image = i) :
      Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner owner tenant vector s {s with requests := s.requests ++ [⟨s.requests.length,p,⟨i,generation⟩,effectCommitment⟩]}
  | policyChange (s allowed) :
      Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner owner tenant vector s {s with policyGeneration := s.policyGeneration+1, policyAllowed := allowed}
  | background (s next) (event : Weaver.LlmRegistryPublication.Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner tenant vector s.publication next)
      (noUse : next.execution.uses = s.publication.execution.uses)
      (noCall : next.execution.children.calls = s.publication.execution.children.calls)
      (noOffer : (next.execution.roots.base.messages routing.root).sends = (s.publication.execution.roots.base.messages routing.root).sends)
      (noSettlement : (next.execution.roots.base.messages routing.root).charged = (s.publication.execution.roots.base.messages routing.root).charged) :
      Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner owner tenant vector s {s with publication := next}
  | consume (s q next) (prepared : q ∈ s.requests) (fresh : Fresh s q) (current : Current s q)
      (authentic : owner.commitValid q (cut s q.permit.image.binding) s.publication.execution next)
      (event : Weaver.LlmAuthoritativeScope.Step source registry routing profile rootOwner childOwner codec scopeOwner s.publication.execution next)
      (sameBoot : next.boot = s.publication.execution.boot) :
      Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner owner tenant vector s {s with publication := committedPublication s.publication next, decisions := s.decisions ++ [⟨q,cut s q.permit.image.binding,s.policyAllowed⟩]}
  | confirm (s d) (durable : d ∈ s.decisions) :
      Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner owner tenant vector s {s with confirmations := s.confirmations ++ [d]}

inductive Run (source : Weaver.GatewayHeadCAS.Config) (registry : Weaver.LlmAuthoritativeScope.Registry) (routing : Weaver.LlmRouting.Config) (profile : Weaver.LlmAttemptLedger.Profile)
    (rootOwner : Weaver.GatewayHeadCAS.Owner) (childOwner : Weaver.LlmAttemptLedger.Owner) (codec : Weaver.LlmSemanticContract.Owner) (scopeOwner : Weaver.LlmAuthoritativeScope.Owner)
    (publicationOwner : Weaver.LlmRegistryPublication.Owner) (owner : Owner) (tenant vector : Nat) : State → State → Prop where
  | refl (s) : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner owner tenant vector s s
  | next : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner owner tenant vector a b → Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner owner tenant vector b d → Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner owner tenant vector a d

theorem publication_projection (run : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner owner tenant vector initial s) :
    Weaver.LlmRegistryPublication.Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner tenant vector Weaver.LlmRegistryPublication.initial s.publication := by
  induction run with
  | refl => exact .refl _
  | next prior event ih =>
    cases event with
    | background next e noUse noCall noOffer noSettlement => exact .next ih e
    | consume q next prepared fresh current authentic e sameBoot =>
      exact .next ih (.advance _ _ _ current.2.2 e sameBoot)
    | _ => exact ih

theorem audit_step (safe : Audit s) (event : Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner owner tenant vector s t) : Audit t := by
  cases event with
  | consume q next prepared fresh current authentic e sameBoot =>
    intro d member
    rcases List.mem_append.mp member with old | new
    · exact safe d old
    · have eq : d = ⟨q,cut s q.permit.image.binding,s.policyAllowed⟩ := by simpa using new
      subst d
      exact ⟨current.1,current.2.1⟩
  | _ => exact safe

theorem initialized_audit (run : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner owner tenant vector initial s) : Audit s := by
  induction run with
  | refl => simp [Audit,initial]
  | next prior event ih => exact audit_step ih event

theorem committed_at_exact_cut (run : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner owner tenant vector initial s) (member : d ∈ s.decisions) :
    d.request.cut = d.actual ∧ d.policyAllowed = true := initialized_audit run d member

theorem stale_policy_generation_cannot_commit (current : Current s q)
    (stale : q.cut.policyGeneration ≠ s.policyGeneration) : False := by
  exact stale (congrArg Cut.policyGeneration current.1)

theorem stale_execution_revision_cannot_commit (current : Current s q)
    (stale : q.permit.image.executionRevision ≠ s.publication.revision) : False :=
  Weaver.LlmRegistryPublication.stale_execution_snapshot_cannot_use current.2.2 stale

theorem stale_fence_cannot_commit (current : Current s q)
    (stale : q.permit.worker ≠ s.publication.fence) : False :=
  Weaver.LlmRegistryPublication.stale_worker_cannot_use current.2.2 stale

theorem policy_denial_blocks_commit (current : Current s q) (deny : s.policyAllowed = false) : False := by
  simp_all [Current]

theorem committed_request_cannot_repeat (fresh : Fresh s q) (member : d ∈ s.decisions)
    (same : d.request.id = q.id) : False := fresh d member same

theorem late_confirmation_preserves_authority (s : State) (d : Decision) :
    ({s with confirmations := s.confirmations ++ [d]} : State).publication = s.publication ∧
    ({s with confirmations := s.confirmations ++ [d]} : State).decisions = s.decisions := ⟨rfl,rfl⟩

theorem restored_observation_is_only_data (s : State) (o : Observation) :
    ({s with observation := o} : State).publication = s.publication ∧
    ({s with observation := o} : State).decisions = s.decisions := ⟨rfl,rfl⟩

theorem policy_generation_never_decreases (event : Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner owner tenant vector s t) : s.policyGeneration ≤ t.policyGeneration := by
  cases event <;> simp <;> omega

theorem original_claim_stays_unique (run : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner owner tenant vector initial s) :
    (s.publication.execution.roots.base.messages routing.root).claims ≤ 1 ∧
    (s.publication.execution.roots.base.messages routing.root).sends ≤ 1 :=
  Weaver.LlmRegistryPublication.original_claim_remains_unique (publication_projection run)

theorem original_allowance_stays_bounded (run : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner owner tenant vector initial s) :
    Weaver.LlmAttemptLedger.total s.publication.execution.children.attempts ≤ source.cost routing.root :=
  Weaver.LlmRegistryPublication.original_allowance_is_preserved (publication_projection run)

theorem original_profile_stays_bound (run : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner owner tenant vector initial s) (bound : s.publication.intent = some b) :
    Weaver.LlmRegistryPublication.resolvePublished b routing.root = registry.resolve (registry.commitment routing.root) :=
  Weaver.LlmRegistryPublication.publication_resolves_original_contract (publication_projection run) bound

theorem original_domains_stay_bound (run : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner owner tenant vector initial s) (member : u ∈ s.publication.execution.uses) :
    u.ticket.scope.semantics.budgetDomain = source.budget (source.root routing.root) ∧
    u.ticket.scope.semantics.historyDomain = source.history (source.root routing.root) :=
  Weaver.LlmRegistryPublication.original_scope_domains_survive_recovery (publication_projection run) member

theorem original_response_mode_stays_bound (run : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner owner tenant vector initial s) (member : u ∈ s.publication.execution.uses) :
    u.ticket.scope.semantics.validatedDocument = (Weaver.LlmAuthoritativeScope.contract source registry routing.root).document :=
  Weaver.LlmRegistryPublication.original_response_mode_survives_recovery (publication_projection run) member

theorem unknown_usage_retains_hold (run : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner owner tenant vector initial s)
    (registered : a ∈ s.publication.execution.children.attempts) (unknown : s.publication.execution.children.usage a.id = none)
    (event : Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner owner tenant vector s t) :
    (t.publication.execution.roots.base.messages routing.root).charged = (s.publication.execution.roots.base.messages routing.root).charged := by
  cases event with
  | background next e noUse noCall noOffer noSettlement => exact noSettlement
  | consume q next prepared fresh current authentic e sameBoot =>
    exact Weaver.LlmRegistryPublication.unknown_usage_blocks_settlement (publication_projection run) registered unknown
      (.advance _ _ _ current.2.2 e sameBoot)
  | _ => rfl

def Unique (s : State) : Prop :=
  s.decisions.Pairwise (fun a b => a.request.id ≠ b.request.id)

theorem unique_step (unique : Unique s)
    (event : Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner owner tenant vector s t) : Unique t := by
  cases event with
  | consume q next prepared fresh current authentic e sameBoot =>
    change (s.decisions ++ [(⟨q,cut s q.permit.image.binding,s.policyAllowed⟩ : Decision)]).Pairwise _
    rw [List.pairwise_append]
    refine ⟨unique,by simp,?_⟩
    intro a member b singleton
    have eq : b = ⟨q,cut s q.permit.image.binding,s.policyAllowed⟩ := by simpa using singleton
    subst b
    exact fresh a member
  | _ => exact unique

theorem decision_ids_remain_unique
    (run : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner owner tenant vector initial s) : Unique s := by
  induction run with
  | refl => simp [Unique,initial]
  | next prior event ih => exact unique_step ih event

theorem confirmed_decision_is_committed
    (run : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner owner tenant vector initial s) :
    ∀ d ∈ s.confirmations, d ∈ s.decisions := by
  induction run with
  | refl => simp [initial]
  | next prior event ih =>
    cases event with
    | consume q next prepared fresh current authentic e sameBoot =>
      intro d member
      exact List.mem_append.mpr (Or.inl (ih d member))
    | confirm d durable =>
      intro row member
      rcases List.mem_append.mp member with old | new
      · exact ih row old
      · have eq : row = d := by simpa using new
        simpa [eq] using durable
    | _ => exact ih

#print axioms publication_projection
#print axioms initialized_audit
#print axioms committed_at_exact_cut
#print axioms stale_policy_generation_cannot_commit
#print axioms stale_execution_revision_cannot_commit
#print axioms stale_fence_cannot_commit
#print axioms policy_denial_blocks_commit
#print axioms committed_request_cannot_repeat
#print axioms late_confirmation_preserves_authority
#print axioms restored_observation_is_only_data
#print axioms policy_generation_never_decreases
#print axioms original_claim_stays_unique
#print axioms original_allowance_stays_bounded
#print axioms original_profile_stays_bound
#print axioms original_domains_stay_bound
#print axioms original_response_mode_stays_bound
#print axioms unknown_usage_retains_hold
#print axioms decision_ids_remain_unique
#print axioms confirmed_decision_is_committed
end Weaver.LlmRecoveryCAS
