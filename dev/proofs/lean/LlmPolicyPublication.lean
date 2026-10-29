import LlmRecoveryCAS
namespace Weaver.LlmPolicyPublication

structure Change where
  id : Nat
  domain : Nat
  sourceVector : Nat
  binding : Weaver.LlmRegistryPublication.Binding
  parentGeneration : Nat
  parentTip : Nat
  contentCommitment : Nat
  allowed : Bool
  deriving DecidableEq
structure Publication where
  change : Change
  generation : Nat
  worker : Nat
  deriving DecidableEq
structure State where
  base : Weaver.LlmRecoveryCAS.State := Weaver.LlmRecoveryCAS.initial
  staged : List Change := []
  stageVisible : List Change := []
  published : List Publication := []
  publicationVisible : Nat := 0
  acknowledgements : List Publication := []
  acknowledgementVisible : List Publication := []
  online : Bool := true

def initial : State := {}
structure Owner where
  stageValid : Change → Weaver.LlmRegistryPublication.State → Prop
  stageDurable : Change → Prop
  publicationDurable : Publication → Prop
  publishValid : Change → Weaver.LlmRegistryPublication.State → Nat → Prop
  acknowledgementDurable : Publication → Prop
  recoveryValid : Weaver.LlmRecoveryCAS.State → List Publication → Prop

def tip (rows : List Publication) : Nat := (rows.getLast?.map (fun r => r.change.id)).getD 0
def effective (rows : List Publication) : Bool := (rows.getLast?.map (fun r => r.change.allowed)).getD true

def restarted (s : Weaver.LlmRecoveryCAS.State) : Weaver.LlmRecoveryCAS.State :=
  {s with publication := {s.publication with fence := s.publication.fence+1, execution := Weaver.LlmRegistryPublication.restarted s.publication.execution, revision := s.publication.revision+1, active := false, projection := none, acknowledged := false}}

theorem restart_projects : Weaver.LlmRecoveryCAS.Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner tenant vector s (restarted s) := by
  exact .background _ _ (.restart _) rfl rfl rfl rfl

inductive Step (source : Weaver.GatewayHeadCAS.Config) (registry : Weaver.LlmAuthoritativeScope.Registry) (routing : Weaver.LlmRouting.Config) (profile : Weaver.LlmAttemptLedger.Profile)
    (rootOwner : Weaver.GatewayHeadCAS.Owner) (childOwner : Weaver.LlmAttemptLedger.Owner) (codec : Weaver.LlmSemanticContract.Owner) (scopeOwner : Weaver.LlmAuthoritativeScope.Owner)
    (publicationOwner : Weaver.LlmRegistryPublication.Owner) (casOwner : Weaver.LlmRecoveryCAS.Owner) (owner : Owner) (tenant vector domain : Nat) : State → State → Prop where
  | stage (s c) (subject : s.base.publication.intent = some c.binding)
      (domainBound : c.domain = domain) (originalDomain : domain = source.history (source.root routing.root)) (sourceBound : c.sourceVector = vector)
      (fresh : ∀ old ∈ s.staged, old.id ≠ c.id)
      (valid : owner.stageValid c s.base.publication) (durable : owner.stageDurable c) :
      Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner owner tenant vector domain s {s with staged := s.staged ++ [c], stageVisible := s.stageVisible ++ [c]}
  | publish (s c worker) (pending : c ∈ s.staged) (visible : c ∈ s.stageVisible)
      (fresh : ∀ old ∈ s.published, old.change.id ≠ c.id)
      (parent : c.parentGeneration = s.base.policyGeneration) (predecessor : c.parentTip = tip s.published)
      (current : worker = s.base.publication.fence) (online : s.online = true)
      (durable : owner.publicationDurable ⟨c,s.base.policyGeneration+1,worker⟩)
      (authorized : owner.publishValid c s.base.publication worker) :
      Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner owner tenant vector domain s {s with base := {s.base with policyGeneration := s.base.policyGeneration+1, policyAllowed := c.allowed}, published := s.published ++ [⟨c,s.base.policyGeneration+1,worker⟩], publicationVisible := s.published.length+1}
  | queryPublication (s r) (committed : r ∈ s.published) (authentic : owner.publicationDurable r) :
      Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner owner tenant vector domain s {s with publicationVisible := s.published.length}
  | acknowledge (s r) (committed : r ∈ s.published) (staged : r.change ∈ s.stageVisible)
      (prefixKnown : s.publicationVisible = s.published.length) (online : s.online = true)
      (durable : owner.acknowledgementDurable r) :
      Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner owner tenant vector domain s {s with acknowledgements := s.acknowledgements ++ [r], acknowledgementVisible := s.acknowledgementVisible ++ [r]}
  | loseReplies (s) :
      Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner owner tenant vector domain s {s with publicationVisible := 0, acknowledgementVisible := []}
  | loseProducerProjection (s) :
      Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner owner tenant vector domain s {s with stageVisible := [], acknowledgementVisible := []}
  | restoreStage (s c) (stored : c ∈ s.staged) (authentic : owner.stageDurable c) :
      Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner owner tenant vector domain s {s with stageVisible := s.stageVisible ++ [c]}
  | restoreAcknowledgement (s r) (stored : r ∈ s.acknowledgements) (authentic : owner.acknowledgementDurable r) :
      Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner owner tenant vector domain s {s with acknowledgementVisible := s.acknowledgementVisible ++ [r]}
  | baseStep (s next) (event : Weaver.LlmRecoveryCAS.Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner tenant vector s.base next)
      (sameGeneration : next.policyGeneration = s.base.policyGeneration) (sameAllowed : next.policyAllowed = s.base.policyAllowed)
      (online : s.online = true) :
      Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner owner tenant vector domain s {s with base := next}
  | restart (s) : Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner owner tenant vector domain s {s with base := restarted s.base, online := false, publicationVisible := 0, acknowledgementVisible := []}
  | recoverOwner (s) (authentic : owner.recoveryValid s.base s.published) :
      Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner owner tenant vector domain s {s with online := true, publicationVisible := s.published.length}

inductive Run (source : Weaver.GatewayHeadCAS.Config) (registry : Weaver.LlmAuthoritativeScope.Registry) (routing : Weaver.LlmRouting.Config) (profile : Weaver.LlmAttemptLedger.Profile)
    (rootOwner : Weaver.GatewayHeadCAS.Owner) (childOwner : Weaver.LlmAttemptLedger.Owner) (codec : Weaver.LlmSemanticContract.Owner) (scopeOwner : Weaver.LlmAuthoritativeScope.Owner)
    (publicationOwner : Weaver.LlmRegistryPublication.Owner) (casOwner : Weaver.LlmRecoveryCAS.Owner) (owner : Owner) (tenant vector domain : Nat) : State → State → Prop where
  | refl (s) : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner owner tenant vector domain s s
  | next : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner owner tenant vector domain a b → Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner owner tenant vector domain b d → Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner owner tenant vector domain a d

theorem cas_projection (run : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner owner tenant vector domain initial s) : Weaver.LlmRecoveryCAS.Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner tenant vector Weaver.LlmRecoveryCAS.initial s.base := by
  induction run with
  | refl => exact .refl _
  | next prior event ih =>
    cases event with
    | publish c worker pending visible fresh parent predecessor current online durable authorized => exact .next ih (.policyChange _ c.allowed)
    | baseStep next e sameGeneration sameAllowed online => exact .next ih e
    | restart => exact .next ih restart_projects
    | _ => exact ih

theorem generation_matches_durable_prefix (run : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner owner tenant vector domain initial s) : s.base.policyGeneration = s.published.length := by
  induction run with
  | refl => rfl
  | next prior event ih =>
    cases event with
    | publish => simpa using congrArg Nat.succ ih
    | baseStep next e sameGeneration sameAllowed online => exact sameGeneration.trans ih
    | _ => exact ih

theorem effective_value_matches_durable_prefix (run : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner owner tenant vector domain initial s) : s.base.policyAllowed = effective s.published := by
  induction run with
  | refl => rfl
  | next prior event ih =>
    cases event with
    | publish => simp [effective]
    | baseStep next e sameGeneration sameAllowed online => exact sameAllowed.trans ih
    | _ => exact ih

inductive Linked : List Publication → Prop where
  | nil : Linked []
  | append (rows r) : Linked rows → r.change.parentGeneration = rows.length →
      r.change.parentTip = tip rows → r.generation = rows.length+1 → Linked (rows ++ [r])

theorem exact_parent_chain (run : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner owner tenant vector domain initial s) : Linked s.published := by
  induction run with
  | refl => exact .nil
  | next prior event ih =>
    cases event with
    | publish c worker pending visible fresh parent predecessor current online durable authorized =>
      exact .append _ _ ih (parent.trans (generation_matches_durable_prefix prior)) predecessor
        (congrArg Nat.succ (generation_matches_durable_prefix prior))
    | _ => exact ih

theorem acknowledgements_name_committed_publications (run : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner owner tenant vector domain initial s) :
    ∀ r ∈ s.acknowledgements, r ∈ s.published := by
  induction run with
  | refl => simp [initial]
  | next prior event ih =>
    cases event with
    | publish => intro r member; exact List.mem_append.mpr (Or.inl (ih r member))
    | acknowledge r committed staged prefixKnown online durable =>
      intro row member
      rcases List.mem_append.mp member with old | new
      · exact ih row old
      · have eq : row = r := by simpa using new
        simpa [eq] using committed
    | _ => exact ih

def Unique (s : State) : Prop := s.published.Pairwise (fun a b => a.change.id ≠ b.change.id)
theorem unique_step (unique : Unique s) (event : Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner owner tenant vector domain s t) : Unique t := by
  cases event with
  | publish c worker pending visible fresh parent predecessor current online durable authorized =>
    change (s.published ++ [(⟨c,s.base.policyGeneration+1,worker⟩ : Publication)]).Pairwise _
    rw [List.pairwise_append]
    refine ⟨unique,by simp,?_⟩
    intro a member b singleton
    have eq : b = ⟨c,s.base.policyGeneration+1,worker⟩ := by simpa using singleton
    subst b
    exact fresh a member
  | _ => exact unique

theorem one_publication_per_change (run : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner owner tenant vector domain initial s) : Unique s := by
  induction run with
  | refl => simp [Unique,initial]
  | next prior event ih => exact unique_step ih event

theorem published_changes_have_parent_successor (run : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner owner tenant vector domain initial s) :
    ∀ r ∈ s.published, r.generation = r.change.parentGeneration+1 := by
  induction run with
  | refl => simp [initial]
  | next prior event ih =>
    cases event with
    | publish c worker pending visible fresh parent predecessor current online durable authorized =>
      intro r member
      rcases List.mem_append.mp member with old | new
      · exact ih r old
      · have eq : r = ⟨c,c.parentGeneration+1,worker⟩ := by simpa [parent] using new
        subst r
        rfl
    | _ => exact ih

theorem published_prefix_is_inherited (event : Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner owner tenant vector domain s t) : ∃ tail, t.published = s.published ++ tail := by
  cases event with
  | publish => exact ⟨[_],rfl⟩
  | _ => exact ⟨[],by simp⟩

theorem publication_is_from_staged_change (run : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner owner tenant vector domain initial s) : ∀ r ∈ s.published, r.change ∈ s.staged := by
  induction run with
  | refl => simp [initial]
  | next prior event ih =>
    cases event with
    | stage c subject domainBound originalDomain sourceBound fresh valid durable =>
      intro r member; exact List.mem_append.mpr (Or.inl (ih r member))
    | publish c worker pending visible fresh parent predecessor current online durable authorized =>
      intro r member
      rcases List.mem_append.mp member with old | new
      · exact ih r old
      · have eq : r = ⟨c,c.parentGeneration+1,worker⟩ := by simpa [parent] using new
        simpa [eq] using pending
    | _ => exact ih

theorem original_change_domain_is_bound (run : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner owner tenant vector domain initial s) :
    ∀ c ∈ s.staged, c.domain = domain ∧ c.sourceVector = vector := by
  induction run with
  | refl => simp [initial]
  | next prior event ih =>
    cases event with
    | stage c subject domainBound originalDomain sourceBound fresh valid durable =>
      intro row member
      rcases List.mem_append.mp member with old | new
      · exact ih row old
      · have eq : row = c := by simpa using new
        simpa [eq] using And.intro domainBound sourceBound
    | _ => exact ih

theorem late_acknowledgement_preserves_authority (s : State) (r : Publication) :
    ({s with acknowledgements := s.acknowledgements ++ [r], acknowledgementVisible := s.acknowledgementVisible ++ [r]} : State).base = s.base := rfl

theorem producer_projection_loss_preserves_authority (s : State) :
    ({s with stageVisible := [], acknowledgementVisible := []} : State).base = s.base ∧
    ({s with stageVisible := [], acknowledgementVisible := []} : State).published = s.published := ⟨rfl,rfl⟩

theorem stale_generation_cannot_consume (s : State) (current : Weaver.LlmRecoveryCAS.Current s.base q)
    (stale : q.cut.policyGeneration ≠ s.base.policyGeneration) : False := Weaver.LlmRecoveryCAS.stale_policy_generation_cannot_commit current stale

theorem old_fence_cannot_consume (s : State) (current : Weaver.LlmRecoveryCAS.Current s.base q)
    (stale : q.permit.worker ≠ s.base.publication.fence) : False := Weaver.LlmRecoveryCAS.stale_fence_cannot_commit current stale

theorem original_claim_stays_unique (run : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner owner tenant vector domain initial s) :
    (s.base.publication.execution.roots.base.messages routing.root).claims ≤ 1 ∧
    (s.base.publication.execution.roots.base.messages routing.root).sends ≤ 1 := Weaver.LlmRecoveryCAS.original_claim_stays_unique (cas_projection run)

theorem original_profile_stays_bound (run : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner owner tenant vector domain initial s) (bound : s.base.publication.intent = some b) :
    Weaver.LlmRegistryPublication.resolvePublished b routing.root = registry.resolve (registry.commitment routing.root) := Weaver.LlmRecoveryCAS.original_profile_stays_bound (cas_projection run) bound

theorem original_allowance_stays_bounded (run : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner owner tenant vector domain initial s) :
    Weaver.LlmAttemptLedger.total s.base.publication.execution.children.attempts ≤ source.cost routing.root := Weaver.LlmRecoveryCAS.original_allowance_stays_bounded (cas_projection run)

theorem original_domains_stay_bound (run : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner owner tenant vector domain initial s) (member : u ∈ s.base.publication.execution.uses) :
    u.ticket.scope.semantics.budgetDomain = source.budget (source.root routing.root) ∧
    u.ticket.scope.semantics.historyDomain = source.history (source.root routing.root) := Weaver.LlmRecoveryCAS.original_domains_stay_bound (cas_projection run) member

theorem unknown_usage_retains_hold (run : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner owner tenant vector domain initial s)
    (registered : a ∈ s.base.publication.execution.children.attempts) (unknown : s.base.publication.execution.children.usage a.id = none)
    (event : Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner owner tenant vector domain s t) :
    (t.base.publication.execution.roots.base.messages routing.root).charged = (s.base.publication.execution.roots.base.messages routing.root).charged := by
  cases event with
  | baseStep next e sameGeneration sameAllowed online => exact Weaver.LlmRecoveryCAS.unknown_usage_retains_hold (cas_projection run) registered unknown e
  | _ => rfl

#print axioms exact_parent_chain
#print axioms cas_projection
#print axioms generation_matches_durable_prefix
#print axioms effective_value_matches_durable_prefix
#print axioms acknowledgements_name_committed_publications
#print axioms one_publication_per_change
#print axioms published_changes_have_parent_successor
#print axioms published_prefix_is_inherited
#print axioms publication_is_from_staged_change
#print axioms original_change_domain_is_bound
#print axioms late_acknowledgement_preserves_authority
#print axioms producer_projection_loss_preserves_authority
#print axioms stale_generation_cannot_consume
#print axioms old_fence_cannot_consume
#print axioms original_claim_stays_unique
#print axioms original_profile_stays_bound
#print axioms original_allowance_stays_bounded
#print axioms original_domains_stay_bound
#print axioms unknown_usage_retains_hold
end Weaver.LlmPolicyPublication
