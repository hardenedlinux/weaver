import LlmCanonicalRegistry
namespace Weaver.LlmMultiKeyRegistry

-- Qualified identifiers are source-issued, fully namespaced values, never wire IDs.
structure Entry where
  registration : Weaver.LlmCanonicalRegistry.Registration
  family : Nat
  claim : Nat
  profile : Nat
  budget : Nat
  history : Nat
  deriving DecidableEq
structure Alias where
  key : Weaver.LlmCanonicalRegistry.AliasKey
  origin : Weaver.LlmCanonicalRegistry.OriginKey
  deriving DecidableEq
inductive Operation where
  | register (entry : Entry)
  | bind (alias : Alias)
  | consume (alias : Alias) (amount : Nat)
  deriving DecidableEq
structure Request where
  id : Nat
  parent : Nat
  fence : Nat
  operation : Operation
  sourceCut : Weaver.LlmRecoveryCAS.Cut
  deriving DecidableEq

def put {K V : Type} [DecidableEq K] (m : K → V) (k : K) (v : V) : K → V :=
  fun x => if x = k then v else m x
structure State (S : Type) where
  source : S
  origins : Weaver.LlmCanonicalRegistry.OriginKey → Option Entry := fun _ => none
  families : Nat → Option Weaver.LlmCanonicalRegistry.OriginKey := fun _ => none
  claims : Nat → Option Weaver.LlmCanonicalRegistry.OriginKey := fun _ => none
  aliases : Weaver.LlmCanonicalRegistry.AliasKey → Option Weaver.LlmCanonicalRegistry.OriginKey := fun _ => none
  decisions : Nat → Option Request := fun _ => none
  pending : List Request := []
  spent : Nat → Bool := fun _ => false
  charged : Nat := 0
  revision : Nat := 0
  fence : Nat := 0
  readable : Bool := true

def initial (source : S) : State S := ⟨source,fun _ => none,fun _ => none,fun _ => none,fun _ => none,fun _ => none,[],fun _ => false,0,0,0,true⟩
def Current (s : State S) (r : Request) : Prop :=
  r ∈ s.pending ∧ s.decisions r.id = none ∧ r.parent = s.revision ∧ r.fence = s.fence ∧ s.readable = true

def finish (s : State S) (r : Request) (next : S) : State S :=
  {s with source := next, decisions := put s.decisions r.id (some r), revision := s.revision+1}

-- SourceStep must refine the actual source-ledger transition, including Policy,
-- original claim/profile/history and exact actual-effect checks. No Boolean RPC proof.
inductive Step (SourceStep : Request → S → S → Prop) (admitted : Entry → Prop)
    (limit : Nat) (recoveryValid : State S → Prop) : State S → State S → Prop where
  | stage (s r) (bodyStable : ∀ old ∈ s.pending, old.id = r.id → old = r) : Step SourceStep admitted limit recoveryValid s {s with pending := s.pending ++ [r]}
  | register (s r e next) (current : Current s r) (command : r.operation = .register e)
      (authentic : admitted e) (originFresh : s.origins e.registration.origin = none)
      (familyFresh : s.families e.family = none) (claimFresh : s.claims e.claim = none)
      (actual : SourceStep r s.source next) :
      Step SourceStep admitted limit recoveryValid s {finish s r next with origins := put s.origins e.registration.origin (some e), families := put s.families e.family (some e.registration.origin), claims := put s.claims e.claim (some e.registration.origin)}
  | bind (s r a e next) (current : Current s r) (command : r.operation = .bind a)
      (registered : s.origins a.origin = some e) (fresh : s.aliases a.key = none)
      (subject : a.key.tenant = a.origin.tenant ∧ a.key.principal = a.origin.principal ∧ a.key.issuer = a.origin.issuer)
      (actual : SourceStep r s.source next) :
      Step SourceStep admitted limit recoveryValid s {finish s r next with aliases := put s.aliases a.key (some a.origin)}
  | consume (s r a e amount next) (current : Current s r) (command : r.operation = .consume a amount)
      (aliasBound : s.aliases a.key = some a.origin) (registered : s.origins a.origin = some e)
      (unspent : s.spent e.claim = false) (budget : s.charged + amount ≤ limit)
      (actual : SourceStep r s.source next) :
      Step SourceStep admitted limit recoveryValid s {finish s r next with spent := put s.spent e.claim true, charged := s.charged+amount}
  | loseProjection (s) : Step SourceStep admitted limit recoveryValid s {s with readable := false}
  | recover (s) (evidence : recoveryValid s) :
      Step SourceStep admitted limit recoveryValid s {s with readable := true}
  | restart (s) : Step SourceStep admitted limit recoveryValid s {s with fence := s.fence+1, readable := false}

inductive Run (R : Request → S → S → Prop) (A : Entry → Prop) (limit : Nat) (Q : State S → Prop) : State S → State S → Prop where
  | refl (s) : Run R A limit Q s s
  | next (prior : Run R A limit Q s t) (event : Step R A limit Q t u) : Run R A limit Q s u

-- Every source mutation has an actual admitted transition; caches never assign it.
inductive SourceRun (R : Request → S → S → Prop) : S → S → Prop where
  | refl (s) : SourceRun R s s
  | next (prior : SourceRun R s t) (event : R req t u) : SourceRun R s u

theorem source_projection (run : Run R A limit Q s t) : SourceRun R s.source t.source := by
  induction run with
  | refl => exact .refl _
  | next prior event ih =>
    cases event with
    | register _ _ _ _ _ _ _ _ _ actual => exact .next ih actual
    | bind _ _ _ _ _ _ _ _ _ actual => exact .next ih actual
    | consume _ _ _ _ _ _ _ _ _ _ _ actual => exact .next ih actual
    | stage => exact ih
    | loseProjection => exact ih
    | recover => exact ih
    | restart => exact ih

theorem origin_step_immutable (event : Step R A limit Q s t) (known : s.origins k = some e) : t.origins k = some e := by
  cases event <;> simp_all [finish,put]
  intro eq; subst k; simp_all

theorem origin_immutable (run : Run R A limit Q s t) (known : s.origins k = some e) : t.origins k = some e := by
  induction run with
  | refl => exact known
  | next _ event ih => exact origin_step_immutable event ih

theorem alias_step_immutable (event : Step R A limit Q s t) (known : s.aliases k = some origin) : t.aliases k = some origin := by
  cases event <;> simp_all [finish,put]
  intro eq; subst k; simp_all

theorem alias_immutable (run : Run R A limit Q s t) (known : s.aliases k = some origin) : t.aliases k = some origin := by
  induction run with
  | refl => exact known
  | next _ event ih => exact alias_step_immutable event ih

theorem family_step_immutable (event : Step R A limit Q s t) (known : s.families k = some origin) : t.families k = some origin := by
  cases event <;> simp_all [finish,put]
  intro eq; subst k; simp_all

theorem claim_step_immutable (event : Step R A limit Q s t) (known : s.claims k = some origin) : t.claims k = some origin := by
  cases event <;> simp_all [finish,put]
  intro eq; subst k; simp_all

theorem decision_step_immutable (txid : Nat) (event : Step R A limit Q s t) (known : s.decisions txid = some r) : t.decisions txid = some r := by
  cases event <;> simp_all [finish,put,Current]
  all_goals intro eq; subst txid; simp_all

theorem spent_step_retained (event : Step R A limit Q s t) (known : s.spent claim = true) : t.spent claim = true := by
  cases event <;> simp_all [finish,put]

theorem unknown_hold_retained (run : Run R A limit Q s t) : s.charged ≤ t.charged := by
  induction run with
  | refl => exact Nat.le_refl _
  | next _ event ih =>
    apply Nat.le_trans ih
    cases event <;> simp [finish]

theorem shared_budget_bound (run : Run R A limit Q (initial seed) t) : t.charged ≤ limit := by
  induction run with
  | refl => simp [initial]
  | next _ event ih => cases event <;> simp_all [finish]

theorem pending_intent_retained (run : Run R A limit Q s t) (known : r ∈ s.pending) : r ∈ t.pending := by
  induction run with
  | refl => exact known
  | next _ event ih => cases event <;> simp_all [finish]

theorem stale_owner_blocks_commit (mismatch : r.fence ≠ s.fence) : ¬ Current s r := by
  intro gate; exact mismatch gate.2.2.2.1

theorem stale_parent_blocks_commit (mismatch : r.parent ≠ s.revision) : ¬ Current s r := by
  intro gate; exact mismatch gate.2.2.1

theorem lost_reply_blocks_reapply (known : s.decisions r.id = some original) : ¬ Current s r := by
  intro gate; simp_all [Current]

theorem recovery_cannot_replace_source (s : State S) : ({s with readable := true} : State S).source = s.source := rfl

-- A refinement transports the serialized source path to any initialized existing
-- transition system, including category 18. Shared accounts require ONE source
-- product relation, not independently cloned category-18 initial states.
theorem composition {S : Type} {R : Request → S → S → Prop} {s t : S} (run : SourceRun R s t) (P : S → Prop) (seed : P s)
    (preserves : ∀ op a b, R op a b → P a → P b) : P t := by
  induction run with
  | refl => exact seed
  | next prior event ih => exact preserves _ _ _ event ih

def Coherent (s : State S) : Prop :=
  ∀ key e, s.origins key = some e →
    e.registration.origin = key ∧ s.families e.family = some key ∧ s.claims e.claim = some key

theorem coherence_step (event : Step R A limit Q s t) (safe : Coherent s) : Coherent t := by
  intro key old known
  cases event with
  | register req entry next current command authentic originFresh familyFresh claimFresh actual =>
    by_cases same : key = entry.registration.origin
    · simp [finish,put,same] at known
      subst old
      simp [finish,put,same]
    · have prior : s.origins key = some old := by simpa [finish,put,same] using known
      obtain ⟨binding, family, claim⟩ := safe key old prior
      have distinctFamily : old.family ≠ entry.family := by
        intro eq; rw [eq, familyFresh] at family; contradiction
      have distinctClaim : old.claim ≠ entry.claim := by
        intro eq; rw [eq, claimFresh] at claim; contradiction
      simp [finish,put,distinctFamily,distinctClaim,binding,family,claim]
  | stage => exact safe _ _ known
  | bind => exact safe _ _ known
  | consume => exact safe _ _ known
  | loseProjection => exact safe _ _ known
  | recover => exact safe _ _ known
  | restart => exact safe _ _ known

theorem initialized_coherence (run : Run R A limit Q (initial seed) t) : Coherent t := by
  induction run with
  | refl => intro k e known; simp [initial] at known
  | next _ event ih => exact coherence_step event ih

theorem same_family_same_origin (safe : Coherent s)
    (first : s.origins k = some e) (second : s.origins j = some f)
    (shared : e.family = f.family) : k = j := by
  have h := (safe k e first).2.1
  have h' := (safe j f second).2.1
  rw [shared,h'] at h
  exact (Option.some.inj h).symm

theorem same_claim_same_origin (safe : Coherent s)
    (first : s.origins k = some e) (second : s.origins j = some f)
    (shared : e.claim = f.claim) : k = j := by
  have h := (safe k e first).2.2
  have h' := (safe j f second).2.2
  rw [shared,h'] at h
  exact (Option.some.inj h).symm

-- Concrete composition with the existing source model, for a selected origin.
-- A multi-origin backend must supply this refinement for each origin AND the
-- shared-account transition; this theorem does not manufacture that backend.
theorem canonical_source_composition
    {S : Type} {R : Request → S → S → Prop} {s t : S}
    (project : S → Weaver.LlmCanonicalRegistry.State)
    (run : SourceRun R s t)
    (prior : Weaver.LlmCanonicalRegistry.Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner continuationOwner owner tenant vector domain original expected Weaver.LlmCanonicalRegistry.initial (project s))
    (refines : ∀ r a b, R r a b → project a = project b ∨ Weaver.LlmCanonicalRegistry.Step source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner continuationOwner owner tenant vector domain original expected (project a) (project b)) :
    Weaver.LlmCanonicalRegistry.Run source registry routing profile rootOwner childOwner codec scopeOwner publicationOwner casOwner policyOwner continuationOwner owner tenant vector domain original expected Weaver.LlmCanonicalRegistry.initial (project t) := by
  induction run with
  | refl => exact prior
  | next before event ih =>
    rcases refines _ _ _ event with same | actual
    · simpa [same] using ih
    · exact .next ih actual

theorem family_immutable (run : Run R A limit Q s t) (known : s.families k = some origin) : t.families k = some origin := by
  induction run with
  | refl => exact known
  | next _ event ih => exact family_step_immutable event ih

theorem claim_immutable (run : Run R A limit Q s t) (known : s.claims k = some origin) : t.claims k = some origin := by
  induction run with
  | refl => exact known
  | next _ event ih => exact claim_step_immutable event ih

theorem decision_immutable (txid : Nat) (run : Run R A limit Q s t) (known : s.decisions txid = some r) : t.decisions txid = some r := by
  induction run with
  | refl => exact known
  | next _ event ih => exact decision_step_immutable txid event ih

theorem spent_retained (run : Run R A limit Q s t) (known : s.spent claim = true) : t.spent claim = true := by
  induction run with
  | refl => exact known
  | next _ event ih => exact spent_step_retained event ih

def AliasesBound (s : State S) : Prop :=
  ∀ key origin, s.aliases key = some origin → ∃ entry, s.origins origin = some entry

theorem aliases_bound_step (event : Step R A limit Q s t) (safe : AliasesBound s) : AliasesBound t := by
  have retained : ∀ {k e}, s.origins k = some e → t.origins k = some e := fun found => origin_step_immutable event found
  intro key origin known
  cases event with
  | bind req alias entry next current command registered fresh subject actual =>
    by_cases same : key = alias.key
    · simp [finish,put,same] at known
      subst origin
      exact ⟨entry, registered⟩
    · have prior : s.aliases key = some origin := by simpa [finish,put,same] using known
      exact safe key origin prior
  | register =>
    obtain ⟨entry, found⟩ := safe key origin known
    exact ⟨entry,retained found⟩
  | stage => exact safe key origin known
  | consume => exact safe key origin known
  | loseProjection => exact safe key origin known
  | recover => exact safe key origin known
  | restart => exact safe key origin known

theorem initialized_aliases_bound (run : Run R A limit Q (initial seed) t) : AliasesBound t := by
  induction run with
  | refl => intro k origin known; simp [initial] at known
  | next _ event ih => exact aliases_bound_step event ih

#print axioms source_projection
#print axioms origin_immutable
#print axioms alias_immutable
#print axioms family_step_immutable
#print axioms claim_step_immutable
#print axioms decision_step_immutable
#print axioms spent_step_retained
#print axioms unknown_hold_retained
#print axioms shared_budget_bound
#print axioms pending_intent_retained
#print axioms stale_owner_blocks_commit
#print axioms stale_parent_blocks_commit
#print axioms lost_reply_blocks_reapply
#print axioms recovery_cannot_replace_source
#print axioms composition
#print axioms canonical_source_composition

#print axioms initialized_coherence
#print axioms same_family_same_origin
#print axioms same_claim_same_origin
#print axioms family_immutable
#print axioms claim_immutable
#print axioms decision_immutable
#print axioms spent_retained
#print axioms initialized_aliases_bound
end Weaver.LlmMultiKeyRegistry
