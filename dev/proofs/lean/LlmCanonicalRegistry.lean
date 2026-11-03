-- SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
--
-- SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

import LlmPolicyContinuation
namespace Weaver.LlmCanonicalRegistry

structure OriginKey where
  tenant : Nat
  principal : Nat
  issuer : Nat
  operation : Nat
  deriving DecidableEq
structure Registration where
  origin : OriginKey
  original : Weaver.LlmPolicyPublication.Change
  deriving DecidableEq
structure AliasKey where
  tenant : Nat
  principal : Nat
  issuer : Nat
  peer : Nat
  protocol : Nat
  profile : Nat
  incarnation : Nat
  session : Nat
  task : Nat
  request : Nat
  deriving DecidableEq
structure AliasBinding where
  key : AliasKey
  target : Registration
  deriving DecidableEq
structure Image where
  alias : AliasBinding
  registryRevision : Nat
  registryFence : Nat
  sourceCut : Weaver.LlmRecoveryCAS.Cut
  deriving DecidableEq
structure Resolution where
  id : Nat
  image : Image
  deriving DecidableEq
structure State where
  base : Weaver.LlmPolicyContinuation.State := Weaver.LlmPolicyContinuation.initial
  registration : Option Registration := none
  registryVisible : Bool := false
  aliases : List AliasBinding := []
  aliasVisible : List AliasBinding := []
  revision : Nat := 0
  fence : Nat := 0
  online : Bool := true
  resolutions : List Resolution := []
def initial : State := {}
structure Owner where
  originValid : OriginKey → Weaver.LlmPolicyPublication.Change → Weaver.LlmPolicyContinuation.State → Prop
  registrationDurable : Registration → Prop
  continuityValid : AliasBinding → Weaver.LlmPolicyContinuation.State → Prop
  aliasDurable : AliasBinding → Prop
  currentRead : Image → Prop
  recoveryValid : State → Prop
  operationValid : Image → Weaver.LlmPolicyContinuation.State → Weaver.LlmPolicyContinuation.State → Prop

def canonicalAlias (a : AliasBinding) : Weaver.LlmPolicyContinuation.Alias :=
  ⟨a.key.protocol,a.key.session,a.key.task,a.target.original.id⟩
def image (s : State) (a : AliasBinding) : Image :=
  ⟨a,s.revision,s.fence,Weaver.LlmRecoveryCAS.cut s.base.base.base a.target.original.binding⟩
def SubjectBound (a : AliasBinding) : Prop :=
  a.key.tenant = a.target.origin.tenant ∧ a.key.principal = a.target.origin.principal ∧ a.key.issuer = a.target.origin.issuer

def Gate (s : State) (r : Resolution) : Prop :=
  r ∈ s.resolutions ∧ s.registration = some r.image.alias.target ∧ r.image.alias ∈ s.aliases ∧
  s.registryVisible = true ∧ r.image.alias ∈ s.aliasVisible ∧ s.online = true ∧ r.image = image s r.image.alias

def RegistrySafe (expected : OriginKey) (original : Weaver.LlmPolicyPublication.Change) (s : State) : Prop :=
  (∀ b, s.registration = some b → b = ⟨expected,original⟩) ∧
  (∀ a ∈ s.aliases, s.registration = some a.target ∧ SubjectBound a) ∧
  s.aliases.Pairwise (fun a b => a.key ≠ b.key)

inductive Step (source : Weaver.GatewayHeadCAS.Config) (registry : Weaver.LlmAuthoritativeScope.Registry) (routing : Weaver.LlmRouting.Config) (profile : Weaver.LlmAttemptLedger.Profile)
    (rootOwner : Weaver.GatewayHeadCAS.Owner) (childOwner : Weaver.LlmAttemptLedger.Owner) (codec : Weaver.LlmSemanticContract.Owner) (scopeOwner : Weaver.LlmAuthoritativeScope.Owner)
    (publicationOwner : Weaver.LlmRegistryPublication.Owner) (casOwner : Weaver.LlmRecoveryCAS.Owner) (policyOwner : Weaver.LlmPolicyPublication.Owner) (continuationOwner : Weaver.LlmPolicyContinuation.Owner) (owner : Owner)
    (tenant vector domain : Nat) (original : Weaver.LlmPolicyPublication.Change) (expected : OriginKey) : State → State → Prop where
  | register (s b worker) (empty : s.registration = none) (bound : b = ⟨expected,original⟩)
      (tenantBound : expected.tenant = tenant) (operationBound : expected.operation = original.id)
      (staged : original ∈ s.base.base.staged)
      (subject : s.base.base.base.publication.intent = some original.binding)
      (authentic : owner.originValid expected original s.base)
      (classification : continuationOwner.familyOf original = original.id) (current : worker = s.fence)
      (online : s.online = true) (durable : owner.registrationDurable b) :
      Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner continuationOwner owner tenant vector domain original expected s {s with registration := some b, registryVisible := true, revision := s.revision+1}
  | bind (s a worker) (registered : s.registration = some a.target) (visible : s.registryVisible = true)
      (subject : SubjectBound a) (fresh : ∀ old ∈ s.aliases, old.key ≠ a.key)
      (authentic : owner.continuityValid a s.base) (durable : owner.aliasDurable a)
      (prior : continuationOwner.aliasValid (canonicalAlias a) original)
      (root : a.target.original.id = original.id) (current : worker = s.fence) (online : s.online = true) :
      Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner continuationOwner owner tenant vector domain original expected s {s with aliases := s.aliases ++ [a], aliasVisible := s.aliasVisible ++ [a], revision := s.revision+1, base := {s.base with aliases := s.base.aliases ++ [canonicalAlias a]}}
  | resolve (s a) (registered : s.registration = some a.target) (stored : a ∈ s.aliases)
      (visible : s.registryVisible = true) (aliasKnown : a ∈ s.aliasVisible) (online : s.online = true)
      (qualified : owner.currentRead (image s a)) :
      Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner continuationOwner owner tenant vector domain original expected s {s with resolutions := s.resolutions ++ [⟨s.resolutions.length,image s a⟩]}
  | loseProjection (s) : Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner continuationOwner owner tenant vector domain original expected s {s with registryVisible := false, aliasVisible := []}
  | restoreRegistration (s b) (committed : s.registration = some b) (authentic : owner.registrationDurable b) :
      Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner continuationOwner owner tenant vector domain original expected s {s with registryVisible := true}
  | restoreAlias (s a) (committed : a ∈ s.aliases) (authentic : owner.aliasDurable a) :
      Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner continuationOwner owner tenant vector domain original expected s {s with aliasVisible := s.aliasVisible ++ [a]}
  | restart (s) : Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner continuationOwner owner tenant vector domain original expected s {s with fence := s.fence+1, revision := s.revision+1, online := false, registryVisible := false, aliasVisible := []}
  | recoverOwner (s) (qualified : owner.recoveryValid s) : Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner continuationOwner owner tenant vector domain original expected s {s with online := true}
  | bootstrap (s next) (event : Weaver.LlmPolicyContinuation.Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner continuationOwner tenant vector domain original s.base next)
      (sameAliases : next.aliases = s.base.aliases) (samePublications : next.base.published = s.base.base.published) (sameWinner : next.winner = s.base.winner)
      (noUse : next.base.base.publication.execution.uses = s.base.base.base.publication.execution.uses)
      (noCall : next.base.base.publication.execution.children.calls = s.base.base.base.publication.execution.children.calls)
      (noOffer : (next.base.base.publication.execution.roots.base.messages routing.root).sends = (s.base.base.base.publication.execution.roots.base.messages routing.root).sends)
      (noSettlement : (next.base.base.publication.execution.roots.base.messages routing.root).charged = (s.base.base.base.publication.execution.roots.base.messages routing.root).charged) :
      Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner continuationOwner owner tenant vector domain original expected s {s with base := next, revision := s.revision+1}
  | advance (s r next) (gate : Gate s r) (event : Weaver.LlmPolicyContinuation.Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner continuationOwner tenant vector domain original s.base next)
      (sameAliases : next.aliases = s.base.aliases) (actual : owner.operationValid r.image s.base next) :
      Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner continuationOwner owner tenant vector domain original expected s {s with base := next, revision := s.revision+1}

inductive Run (source : Weaver.GatewayHeadCAS.Config) (registry : Weaver.LlmAuthoritativeScope.Registry) (routing : Weaver.LlmRouting.Config) (profile : Weaver.LlmAttemptLedger.Profile)
    (rootOwner : Weaver.GatewayHeadCAS.Owner) (childOwner : Weaver.LlmAttemptLedger.Owner) (codec : Weaver.LlmSemanticContract.Owner) (scopeOwner : Weaver.LlmAuthoritativeScope.Owner)
    (publicationOwner : Weaver.LlmRegistryPublication.Owner) (casOwner : Weaver.LlmRecoveryCAS.Owner) (policyOwner : Weaver.LlmPolicyPublication.Owner) (continuationOwner : Weaver.LlmPolicyContinuation.Owner) (owner : Owner)
    (tenant vector domain : Nat) (original : Weaver.LlmPolicyPublication.Change) (expected : OriginKey) : State → State → Prop where
  | refl (s) : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner continuationOwner owner tenant vector domain original expected s s
  | next : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner continuationOwner owner tenant vector domain original expected a b → Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner continuationOwner owner tenant vector domain original expected b d → Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner continuationOwner owner tenant vector domain original expected a d

theorem continuation_projection (run : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner continuationOwner owner tenant vector domain original expected initial s) : Weaver.LlmPolicyContinuation.Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner continuationOwner tenant vector domain original Weaver.LlmPolicyContinuation.initial s.base := by
  induction run with
  | refl => exact .refl _
  | next prior event ih =>
    cases event with
    | bind a worker registered visible subject fresh authentic durable oldValid root current online =>
      exact .next ih (.bindAlias _ _ root oldValid)
    | bootstrap next e sameAliases samePublications sameWinner noUse noCall noOffer noSettlement => exact .next ih e
    | advance r next gate e sameAliases actual => exact .next ih e
    | _ => exact ih

theorem registry_safe_step (safe : RegistrySafe expected original s) (event : Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner continuationOwner owner tenant vector domain original expected s t) : RegistrySafe expected original t := by
  rcases safe with ⟨registered,aliases,unique⟩
  cases event with
  | register b worker empty bound tenantBound operationBound staged subject authentic classification current online durable =>
    refine ⟨?_,?_,unique⟩
    · intro row eq; have same : b = row := Option.some.inj eq; simpa [← same] using bound
    · intro a member; have old := (aliases a member).1; simp [empty] at old
  | bind a worker registeredNow visible subject fresh authentic durable oldValid root current online =>
    refine ⟨registered,?_,?_⟩
    · intro row member
      rcases List.mem_append.mp member with old | new
      · exact aliases row old
      · have eq : row = a := by simpa using new
        simpa [eq] using And.intro registeredNow subject
    · rw [List.pairwise_append]
      refine ⟨unique,by simp,?_⟩
      intro old member row singleton
      have eq : row = a := by simpa using singleton
      simpa [eq] using fresh old member
  | _ => exact ⟨registered,aliases,unique⟩

theorem initialized_registry_safe (run : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner continuationOwner owner tenant vector domain original expected initial s) : RegistrySafe expected original s := by
  induction run with
  | refl => simp [RegistrySafe,initial]
  | next prior event ih => exact registry_safe_step ih event

theorem registration_is_original (run : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner continuationOwner owner tenant vector domain original expected initial s) (registered : s.registration = some b) : b = ⟨expected,original⟩ :=
  (initialized_registry_safe run).1 b registered

theorem aliases_resolve_registered_original (run : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner continuationOwner owner tenant vector domain original expected initial s) (member : a ∈ s.aliases) :
    s.registration = some a.target ∧ SubjectBound a := (initialized_registry_safe run).2.1 a member

theorem alias_targets_original_family (run : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner continuationOwner owner tenant vector domain original expected initial s) (member : a ∈ s.aliases) : a.target.original.id = original.id := by
  have registered := (aliases_resolve_registered_original run member).1
  have same := registration_is_original run registered
  exact congrArg (fun b : Registration => b.original.id) same

theorem registered_origin_retains_pending (run : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner continuationOwner owner tenant vector domain original expected initial s) :
    ∀ b, s.registration = some b → original ∈ s.base.base.staged := by
  induction run with
  | refl => simp [initial]
  | next prior event ih =>
    cases event with
    | register b worker empty bound tenantBound operationBound staged subject authentic classification current online durable =>
      intro row registered
      exact staged
    | bootstrap next e sameAliases samePublications sameWinner noUse noCall noOffer noSettlement =>
      intro b registered
      exact Weaver.LlmPolicyContinuation.original_staged_intent_is_retained e (ih b registered)
    | advance r next gate e sameAliases actual =>
      intro b registered
      exact Weaver.LlmPolicyContinuation.original_staged_intent_is_retained e (ih b registered)
    | _ => exact ih

theorem alias_keys_cannot_rebind (run : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner continuationOwner owner tenant vector domain original expected initial s) : s.aliases.Pairwise (fun a b => a.key ≠ b.key) :=
  (initialized_registry_safe run).2.2

theorem registration_is_never_replaced (event : Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner continuationOwner owner tenant vector domain original expected s t) (registered : s.registration = some b) : t.registration = some b := by
  cases event with
  | register next worker empty bound tenantBound operationBound staged subject authentic classification current online durable => simp_all
  | _ => exact registered

theorem stale_registry_revision_blocks_use (s : State) (gate : Gate s r) (stale : r.image.registryRevision ≠ s.revision) : False := by
  exact stale (congrArg Image.registryRevision gate.2.2.2.2.2.2)

theorem stale_registry_fence_blocks_use (s : State) (gate : Gate s r) (stale : r.image.registryFence ≠ s.fence) : False := by
  exact stale (congrArg Image.registryFence gate.2.2.2.2.2.2)

theorem missing_registry_projection_blocks_use (s : State) (gate : Gate s r) (missing : s.registryVisible = false) : False := by
  have visible := gate.2.2.2.1
  simp_all

theorem projection_restore_never_assigns_authority (s : State) :
    ({s with registryVisible := true} : State).registration = s.registration ∧
    ({s with registryVisible := true} : State).base = s.base := ⟨rfl,rfl⟩

theorem resolution_is_not_consumption (s : State) (a : AliasBinding) :
    ({s with resolutions := s.resolutions ++ [⟨s.resolutions.length,image s a⟩]} : State).base = s.base := rfl

theorem owner_fence_never_decreases (event : Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner continuationOwner owner tenant vector domain original expected s t) : s.fence ≤ t.fence := by cases event <;> simp <;> omega

theorem original_pending_is_retained (run : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner continuationOwner owner tenant vector domain original expected initial s) (member : original ∈ s.base.base.staged)
    (event : Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner continuationOwner owner tenant vector domain original expected s t) : original ∈ t.base.base.staged := by
  cases event with
  | bootstrap next e sameAliases samePublications sameWinner noUse noCall noOffer noSettlement => exact Weaver.LlmPolicyContinuation.original_staged_intent_is_retained e member
  | advance r next gate e sameAliases actual => exact Weaver.LlmPolicyContinuation.original_staged_intent_is_retained e member
  | _ => exact member

theorem family_winner_is_never_replaced (event : Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner continuationOwner owner tenant vector domain original expected s t) (winner : s.base.winner = some row) : t.base.winner = some row := by
  cases event with
  | bootstrap next e sameAliases samePublications sameWinner noUse noCall noOffer noSettlement => exact sameWinner.trans winner
  | advance r next gate e sameAliases actual => exact Weaver.LlmPolicyContinuation.winner_is_never_replaced e winner
  | _ => exact winner

theorem original_claim_stays_unique (run : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner continuationOwner owner tenant vector domain original expected initial s) :
    (s.base.base.base.publication.execution.roots.base.messages routing.root).claims ≤ 1 ∧
    (s.base.base.base.publication.execution.roots.base.messages routing.root).sends ≤ 1 := Weaver.LlmPolicyContinuation.original_claim_stays_unique (continuation_projection run)

theorem original_profile_stays_bound (run : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner continuationOwner owner tenant vector domain original expected initial s) (bound : s.base.base.base.publication.intent = some b) :
    Weaver.LlmRegistryPublication.resolvePublished b routing.root = registry.resolve (registry.commitment routing.root) := Weaver.LlmPolicyContinuation.original_profile_stays_bound (continuation_projection run) bound

theorem original_allowance_stays_bounded (run : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner continuationOwner owner tenant vector domain original expected initial s) :
    Weaver.LlmAttemptLedger.total s.base.base.base.publication.execution.children.attempts ≤ source.cost routing.root := Weaver.LlmPolicyContinuation.original_allowance_stays_bounded (continuation_projection run)

theorem original_domains_stay_bound (run : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner continuationOwner owner tenant vector domain original expected initial s) (member : u ∈ s.base.base.base.publication.execution.uses) :
    u.ticket.scope.semantics.budgetDomain = source.budget (source.root routing.root) ∧
    u.ticket.scope.semantics.historyDomain = source.history (source.root routing.root) := Weaver.LlmPolicyContinuation.original_domains_stay_bound (continuation_projection run) member

theorem unknown_usage_retains_hold (run : Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner continuationOwner owner tenant vector domain original expected initial s)
    (registered : a ∈ s.base.base.base.publication.execution.children.attempts) (unknown : s.base.base.base.publication.execution.children.usage a.id = none)
    (event : Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner continuationOwner owner tenant vector domain original expected s t) :
    (t.base.base.base.publication.execution.roots.base.messages routing.root).charged = (s.base.base.base.publication.execution.roots.base.messages routing.root).charged := by
  cases event with
  | bootstrap next e sameAliases samePublications sameWinner noUse noCall noOffer noSettlement => exact noSettlement
  | advance r next gate e sameAliases actual => exact Weaver.LlmPolicyContinuation.unknown_usage_retains_hold (continuation_projection run) registered unknown e
  | _ => rfl

#print axioms alias_targets_original_family
#print axioms registered_origin_retains_pending
#print axioms continuation_projection
#print axioms initialized_registry_safe
#print axioms registration_is_original
#print axioms aliases_resolve_registered_original
#print axioms alias_keys_cannot_rebind
#print axioms registration_is_never_replaced
#print axioms stale_registry_revision_blocks_use
#print axioms stale_registry_fence_blocks_use
#print axioms missing_registry_projection_blocks_use
#print axioms projection_restore_never_assigns_authority
#print axioms resolution_is_not_consumption
#print axioms owner_fence_never_decreases
#print axioms original_pending_is_retained
#print axioms family_winner_is_never_replaced
#print axioms original_claim_stays_unique
#print axioms original_profile_stays_bound
#print axioms original_allowance_stays_bounded
#print axioms original_domains_stay_bound
#print axioms unknown_usage_retains_hold
end Weaver.LlmCanonicalRegistry
