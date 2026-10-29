import LlmPolicyPublication
namespace Weaver.LlmPolicyContinuation

structure Inspection where
  cut : Weaver.LlmRecoveryCAS.Cut
  tip : Nat
  deriving DecidableEq
structure Approval where
  candidate : Weaver.LlmPolicyPublication.Change
  inspection : Inspection
  deriving DecidableEq
structure Alias where
  protocol : Nat
  session : Nat
  task : Nat
  canonicalRoot : Nat
  deriving DecidableEq
structure State where
  base : Weaver.LlmPolicyPublication.State := Weaver.LlmPolicyPublication.initial
  inspections : List Inspection := []
  approvals : List Approval := []
  winner : Option Weaver.LlmPolicyPublication.Publication := none
  aliases : List Alias := []
def initial : State := {}
structure Owner where
  familyOf : Weaver.LlmPolicyPublication.Change → Nat
  inspectionValid : Weaver.LlmPolicyPublication.Change → Weaver.LlmPolicyPublication.State → Prop
  reauthorizeValid : Weaver.LlmPolicyPublication.Change → Weaver.LlmPolicyPublication.Change → Weaver.LlmPolicyPublication.State → Prop
  approvalDurable : Approval → Prop
  aliasValid : Alias → Weaver.LlmPolicyPublication.Change → Prop

def SameIntent (a b : Weaver.LlmPolicyPublication.Change) : Prop :=
  a.domain = b.domain ∧ a.sourceVector = b.sourceVector ∧ a.binding = b.binding ∧
  a.contentCommitment = b.contentCommitment ∧ a.allowed = b.allowed

def inspection (s : State) (original : Weaver.LlmPolicyPublication.Change) : Inspection :=
  ⟨Weaver.LlmRecoveryCAS.cut s.base.base original.binding,Weaver.LlmPolicyPublication.tip s.base.published⟩
def Registered (s : State) (original candidate : Weaver.LlmPolicyPublication.Change) : Prop :=
  candidate = original ∨ ∃ a ∈ s.approvals, a.candidate = candidate

def WinnerSafe (owner : Owner) (original : Weaver.LlmPolicyPublication.Change) (s : State) : Prop :=
  (∀ r ∈ s.base.published, owner.familyOf r.change = original.id → s.winner = some r) ∧
  (∀ r, s.winner = some r → r ∈ s.base.published ∧ owner.familyOf r.change = original.id)

inductive Step (source : Weaver.GatewayHeadCAS.Config) (registry : Weaver.LlmAuthoritativeScope.Registry) (routing : Weaver.LlmRouting.Config) (profile : Weaver.LlmAttemptLedger.Profile)
    (rootOwner : Weaver.GatewayHeadCAS.Owner) (childOwner : Weaver.LlmAttemptLedger.Owner) (codec : Weaver.LlmSemanticContract.Owner) (scopeOwner : Weaver.LlmAuthoritativeScope.Owner)
    (publicationOwner : Weaver.LlmRegistryPublication.Owner) (casOwner : Weaver.LlmRecoveryCAS.Owner) (policyOwner : Weaver.LlmPolicyPublication.Owner) (owner : Owner)
    (tenant vector domain : Nat) (original : Weaver.LlmPolicyPublication.Change) : State → State → Prop where
  | background (s next) (event : Weaver.LlmPolicyPublication.Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner tenant vector domain s.base next)
      (sameLog : next.published = s.base.published) :
      Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner owner tenant vector domain original s {s with base := next}
  | inspect (s) (unresolved : s.winner = none) (online : s.base.online = true)
      (absent : ∀ r ∈ s.base.published, owner.familyOf r.change ≠ original.id)
      (qualified : owner.inspectionValid original s.base) :
      Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner owner tenant vector domain original s {s with inspections := s.inspections ++ [inspection s original]}
  | approve (s c observed) (stored : c ∈ s.base.staged) (rootStored : original ∈ s.base.staged)
      (same : SameIntent original c) (fresh : c.id ≠ original.id)
      (family : owner.familyOf c = original.id) (unresolved : s.winner = none)
      (observedBefore : observed ∈ s.inspections) (current : observed = inspection s original)
      (originalStale : original.parentGeneration < s.base.base.policyGeneration)
      (parent : c.parentGeneration = s.base.base.policyGeneration) (predecessor : c.parentTip = Weaver.LlmPolicyPublication.tip s.base.published)
      (online : s.base.online = true) (authorized : owner.reauthorizeValid original c s.base)
      (durable : owner.approvalDurable ⟨c,observed⟩) :
      Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner owner tenant vector domain original s {s with approvals := s.approvals ++ [⟨c,observed⟩]}
  | publishFamily (s c row next) (event : Weaver.LlmPolicyPublication.Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner tenant vector domain s.base next)
      (appended : next.published = s.base.published ++ [row]) (exactChange : row.change = c)
      (family : owner.familyOf c = original.id) (registered : Registered s original c)
      (same : SameIntent original c) (unresolved : s.winner = none)
      (freshApproval : c = original ∨ ∃ a ∈ s.approvals, a.candidate = c ∧ a.inspection = inspection s original) :
      Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner owner tenant vector domain original s {s with base := next, winner := some row}
  | publishOther (s row next) (event : Weaver.LlmPolicyPublication.Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner tenant vector domain s.base next)
      (appended : next.published = s.base.published ++ [row]) (other : owner.familyOf row.change ≠ original.id) :
      Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner owner tenant vector domain original s {s with base := next}
  | bindAlias (s a) (bound : a.canonicalRoot = original.id) (authentic : owner.aliasValid a original) :
      Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner owner tenant vector domain original s {s with aliases := s.aliases ++ [a]}

inductive Run (source : Weaver.GatewayHeadCAS.Config) (registry : Weaver.LlmAuthoritativeScope.Registry) (routing : Weaver.LlmRouting.Config) (profile : Weaver.LlmAttemptLedger.Profile)
    (rootOwner : Weaver.GatewayHeadCAS.Owner) (childOwner : Weaver.LlmAttemptLedger.Owner) (codec : Weaver.LlmSemanticContract.Owner) (scopeOwner : Weaver.LlmAuthoritativeScope.Owner)
    (publicationOwner : Weaver.LlmRegistryPublication.Owner) (casOwner : Weaver.LlmRecoveryCAS.Owner) (policyOwner : Weaver.LlmPolicyPublication.Owner) (owner : Owner)
    (tenant vector domain : Nat) (original : Weaver.LlmPolicyPublication.Change) : State → State → Prop where
  | refl (s) : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner owner tenant vector domain original s s
  | next : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner owner tenant vector domain original a b → Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner owner tenant vector domain original b d → Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner owner tenant vector domain original a d

theorem publication_projection (run : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner owner tenant vector domain original initial s) : Weaver.LlmPolicyPublication.Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner tenant vector domain Weaver.LlmPolicyPublication.initial s.base := by
  induction run with
  | refl => exact .refl _
  | next prior event ih =>
    cases event with
    | background next e sameLog => exact .next ih e
    | publishFamily c row next e appended exactChange family candidateRegistered same unresolved freshApproval => exact .next ih e
    | publishOther row next e appended other => exact .next ih e
    | _ => exact ih

theorem winner_safe_step (safe : WinnerSafe owner original s) (event : Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner owner tenant vector domain original s t) : WinnerSafe owner original t := by
  rcases safe with ⟨familyBound,winnerBound⟩
  cases event with
  | background next e sameLog => simpa [WinnerSafe,sameLog] using And.intro familyBound winnerBound
  | publishFamily c row next e appended exactChange family candidateRegistered same unresolved freshApproval =>
    constructor
    · intro r member own
      rw [appended] at member
      rcases List.mem_append.mp member with old | new
      · have prior := familyBound r old own
        simp [unresolved] at prior
      · have eq : r = row := by simpa using new
        simpa [eq]
    · intro r eq
      have eq' : row = r := Option.some.inj eq
      subst r
      exact ⟨by rw [appended]; simp,by simpa [exactChange] using family⟩
  | publishOther row next e appended other =>
    constructor
    · intro r member own
      rw [appended] at member
      rcases List.mem_append.mp member with old | new
      · exact familyBound r old own
      · have eq : r = row := by simpa using new
        subst r
        exact False.elim (other own)
    · intro r winner
      rcases winnerBound r winner with ⟨member,own⟩
      exact ⟨by rw [appended]; exact List.mem_append.mpr (Or.inl member),own⟩
  | _ => exact ⟨familyBound,winnerBound⟩

theorem initialized_winner_safe (run : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner owner tenant vector domain original initial s) : WinnerSafe owner original s := by
  induction run with
  | refl => simp [WinnerSafe,initial,Weaver.LlmPolicyPublication.initial]
  | next prior event ih => exact winner_safe_step ih event

theorem family_has_one_winner (run : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner owner tenant vector domain original initial s)
    (first : r ∈ s.base.published) (firstFamily : owner.familyOf r.change = original.id)
    (second : q ∈ s.base.published) (secondFamily : owner.familyOf q.change = original.id) : r = q := by
  have one := (initialized_winner_safe run).1 r first firstFamily
  have two := (initialized_winner_safe run).1 q second secondFamily
  exact Option.some.inj (one.symm.trans two)

theorem committed_family_prevents_absence (run : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner owner tenant vector domain original initial s)
    (member : r ∈ s.base.published) (family : owner.familyOf r.change = original.id) (absent : s.winner = none) : False := by
  have winner := (initialized_winner_safe run).1 r member family
  simp [absent] at winner

theorem winner_is_never_replaced (event : Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner owner tenant vector domain original s t) (winner : s.winner = some r) : t.winner = some r := by
  cases event with
  | publishFamily c row next e appended exactChange family candidateRegistered same unresolved freshApproval => simp_all
  | _ => exact winner

theorem original_staged_intent_is_retained (event : Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner owner tenant vector domain original s t) (member : original ∈ s.base.staged) : original ∈ t.base.staged := by
  have keep : ∀ next, Weaver.LlmPolicyPublication.Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner tenant vector domain s.base next → original ∈ next.staged := by
    intro next e
    cases e with
    | stage => exact List.mem_append.mpr (Or.inl member)
    | _ => exact member
  cases event with
  | background next e sameLog => exact keep next e
  | publishFamily c row next e appended exactChange family candidateRegistered same unresolved freshApproval => exact keep next e
  | publishOther row next e appended other => exact keep next e
  | _ => exact member

theorem approvals_keep_original_semantics (run : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner owner tenant vector domain original initial s) : ∀ a ∈ s.approvals, SameIntent original a.candidate := by
  induction run with
  | refl => simp [initial]
  | next prior event ih =>
    cases event with
    | approve c observed stored rootStored same fresh family unresolved observedBefore current originalStale parent predecessor online authorized durable =>
      intro a member
      rcases List.mem_append.mp member with old | new
      · exact ih a old
      · have eq : a = ⟨c,observed⟩ := by simpa using new
        simpa [eq] using same
    | _ => exact ih

theorem aliases_keep_canonical_family (run : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner owner tenant vector domain original initial s) : ∀ a ∈ s.aliases, a.canonicalRoot = original.id := by
  induction run with
  | refl => simp [initial]
  | next prior event ih =>
    cases event with
    | bindAlias a bound authentic =>
      intro row member
      rcases List.mem_append.mp member with old | new
      · exact ih row old
      · have eq : row = a := by simpa using new
        simpa [eq] using bound
    | _ => exact ih

theorem protocol_alias_is_only_data (s : State) (a : Alias) :
    ({s with aliases := s.aliases ++ [a]} : State).base = s.base ∧
    ({s with aliases := s.aliases ++ [a]} : State).winner = s.winner := ⟨rfl,rfl⟩

theorem inspection_cannot_authorize_consumption (s : State) (original : Weaver.LlmPolicyPublication.Change) :
    ({s with inspections := s.inspections ++ [inspection s original]} : State).base = s.base := rfl

theorem stale_approval_cut_is_rejected (s : State) (original : Weaver.LlmPolicyPublication.Change) (a : Approval)
    (current : a.inspection = inspection s original)
    (old : a.inspection.cut ≠ Weaver.LlmRecoveryCAS.cut s.base.base original.binding) : False := by
  exact old (congrArg Inspection.cut current)

theorem stale_approval_fence_is_rejected (s : State) (original : Weaver.LlmPolicyPublication.Change) (a : Approval)
    (current : a.inspection = inspection s original)
    (old : a.inspection.cut.image.fence ≠ s.base.base.publication.fence) : False := by
  have eq := congrArg (fun i : Inspection => i.cut.image.fence) current
  exact old eq

theorem current_publication_prefix_is_inherited (event : Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner owner tenant vector domain original s t) : ∃ tail, t.base.published = s.base.published ++ tail := by
  cases event with
  | background next e sameLog => exact ⟨[],by simpa using sameLog⟩
  | publishFamily c row next e appended exactChange family candidateRegistered same unresolved freshApproval => exact ⟨[row],appended⟩
  | publishOther row next e appended other => exact ⟨[row],appended⟩
  | _ => exact ⟨[],by simp⟩

theorem original_claim_stays_unique (run : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner owner tenant vector domain original initial s) :
    (s.base.base.publication.execution.roots.base.messages routing.root).claims ≤ 1 ∧
    (s.base.base.publication.execution.roots.base.messages routing.root).sends ≤ 1 := Weaver.LlmPolicyPublication.original_claim_stays_unique (publication_projection run)

theorem original_profile_stays_bound (run : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner owner tenant vector domain original initial s) (bound : s.base.base.publication.intent = some b) :
    Weaver.LlmRegistryPublication.resolvePublished b routing.root = registry.resolve (registry.commitment routing.root) := Weaver.LlmPolicyPublication.original_profile_stays_bound (publication_projection run) bound

theorem original_allowance_stays_bounded (run : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner owner tenant vector domain original initial s) :
    Weaver.LlmAttemptLedger.total s.base.base.publication.execution.children.attempts ≤ source.cost routing.root := Weaver.LlmPolicyPublication.original_allowance_stays_bounded (publication_projection run)

theorem original_domains_stay_bound (run : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner owner tenant vector domain original initial s) (member : u ∈ s.base.base.publication.execution.uses) :
    u.ticket.scope.semantics.budgetDomain = source.budget (source.root routing.root) ∧
    u.ticket.scope.semantics.historyDomain = source.history (source.root routing.root) := Weaver.LlmPolicyPublication.original_domains_stay_bound (publication_projection run) member

theorem unknown_usage_retains_hold (run : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner owner tenant vector domain original initial s)
    (registered : a ∈ s.base.base.publication.execution.children.attempts) (unknown : s.base.base.publication.execution.children.usage a.id = none)
    (event : Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner owner tenant vector domain original s t) :
    (t.base.base.publication.execution.roots.base.messages routing.root).charged = (s.base.base.publication.execution.roots.base.messages routing.root).charged := by
  cases event with
  | background next e sameLog => exact Weaver.LlmPolicyPublication.unknown_usage_retains_hold (publication_projection run) registered unknown e
  | publishFamily c row next e appended exactChange family candidateRegistered same unresolved freshApproval => exact Weaver.LlmPolicyPublication.unknown_usage_retains_hold (publication_projection run) registered unknown e
  | publishOther row next e appended other => exact Weaver.LlmPolicyPublication.unknown_usage_retains_hold (publication_projection run) registered unknown e
  | _ => rfl

#print axioms publication_projection
#print axioms initialized_winner_safe
#print axioms family_has_one_winner
#print axioms committed_family_prevents_absence
#print axioms winner_is_never_replaced
#print axioms original_staged_intent_is_retained
#print axioms approvals_keep_original_semantics
#print axioms aliases_keep_canonical_family
#print axioms protocol_alias_is_only_data
#print axioms inspection_cannot_authorize_consumption
#print axioms stale_approval_cut_is_rejected
#print axioms stale_approval_fence_is_rejected
#print axioms current_publication_prefix_is_inherited
#print axioms original_claim_stays_unique
#print axioms original_profile_stays_bound
#print axioms original_allowance_stays_bounded
#print axioms original_domains_stay_bound
#print axioms unknown_usage_retains_hold
end Weaver.LlmPolicyContinuation
