import LlmMultiKeyRegistry
namespace Weaver.LlmResultProjection

-- Exact typed result bodies abstract native canonical bytes and commitments.
-- A digest alone is not evidence of the body's authenticity or durability.
structure Image (S : Type) where
  source : S
  origins : Weaver.LlmCanonicalRegistry.OriginKey → Option Weaver.LlmMultiKeyRegistry.Entry
  families : Nat → Option Weaver.LlmCanonicalRegistry.OriginKey
  claims : Nat → Option Weaver.LlmCanonicalRegistry.OriginKey
  aliases : Weaver.LlmCanonicalRegistry.AliasKey → Option Weaver.LlmCanonicalRegistry.OriginKey
  decisions : Nat → Option Weaver.LlmMultiKeyRegistry.Request
  spent : Nat → Bool
  charged : Nat
  revision : Nat

def image (s : Weaver.LlmMultiKeyRegistry.State S) : Image S :=
  ⟨s.source,s.origins,s.families,s.claims,s.aliases,s.decisions,s.spent,s.charged,s.revision⟩
structure Result (S : Type) where
  request : Weaver.LlmMultiKeyRegistry.Request
  position : Nat
  before : Image S
  after : Image S
structure Projection (S : Type) where
  position : Nat
  body : Image S
structure State (S : Type) where
  base : Weaver.LlmMultiKeyRegistry.State S
  log : List (Result S)
  sourceStore : Projection S
  accountStore : Projection S
  qualified : Bool
  active : Bool

def initial (seed : S) : State S :=
  let b := Weaver.LlmMultiKeyRegistry.initial seed
  ⟨b,[],⟨0,image b⟩,⟨0,image b⟩,true,true⟩
def Joined (s : State S) : Prop :=
  s.sourceStore.position = s.log.length ∧ s.accountStore.position = s.log.length ∧
  s.sourceStore.body = image s.base ∧ s.accountStore.body = image s.base

def ApplyGate (s : State S) (p : Projection S) (r : Result S) (worker : Nat) : Prop :=
  worker = s.base.fence ∧ s.qualified = true ∧ s.log[p.position]? = some r ∧
  r.position = p.position+1 ∧ p.body = r.before

def PrefixImage (seed : S) (log : List (Result S)) (p : Projection S) : Prop :=
  (p.position = 0 ∧ p.body = image (Weaver.LlmMultiKeyRegistry.initial seed)) ∨
  ∃ r ∈ log, r.position = p.position ∧ r.after = p.body

inductive Step (R : Weaver.LlmMultiKeyRegistry.Request → S → S → Prop)
    (A : Weaver.LlmMultiKeyRegistry.Entry → Prop) (limit : Nat)
    (Q : Weaver.LlmMultiKeyRegistry.State S → Prop) (V : State S → Prop) (seed : S) : State S → State S → Prop where
  | stage (s r worker) (current : worker = s.base.fence) (qualified : s.qualified = true)
      (stable : ∀ old ∈ s.base.pending, old.id = r.id → old = r) :
      Step R A limit Q V seed s {s with base := {s.base with pending := s.base.pending ++ [r]}}
  | commit (s next r worker) (current : worker = s.base.fence)
      (qualified : s.qualified = true) (active : s.active = true)
      (actual : Weaver.LlmMultiKeyRegistry.Step R A limit Q s.base next)
      (fresh : s.base.decisions r.id = none) (decided : next.decisions r.id = some r) :
      Step R A limit Q V seed s {s with base := next, log := s.log ++ [⟨r,s.log.length+1,image s.base,image next⟩]}
  | applySource (s result worker) (gate : ApplyGate s s.sourceStore result worker) :
      Step R A limit Q V seed s {s with sourceStore := ⟨result.position,result.after⟩}
  | applyAccount (s result worker) (gate : ApplyGate s s.accountStore result worker) :
      Step R A limit Q V seed s {s with accountStore := ⟨result.position,result.after⟩}
  | observe (s) : Step R A limit Q V seed s s
  | restart (s) :
      Step R A limit Q V seed s {s with base := {s.base with fence := s.base.fence+1, readable := false}, qualified := false, active := false}
  | recover (s) (retired : s.qualified = false) (closed : s.active = false)
      (authentic : Q s.base) (resultPrefix : V s) :
      Step R A limit Q V seed s {s with base := {s.base with readable := true}, qualified := true, active := false}
  | restoreSource (s p worker) (current : worker = s.base.fence) (qualified : s.qualified = true)
      (closed : s.active = false) (valid : PrefixImage seed s.log p) :
      Step R A limit Q V seed s {s with sourceStore := p}
  | restoreAccount (s p worker) (current : worker = s.base.fence) (qualified : s.qualified = true)
      (closed : s.active = false) (valid : PrefixImage seed s.log p) :
      Step R A limit Q V seed s {s with accountStore := p}
  | activate (s) (qualified : s.qualified = true) (joined : Joined s) :
      Step R A limit Q V seed s {s with active := true}

inductive Run (R : Weaver.LlmMultiKeyRegistry.Request → S → S → Prop)
    (A : Weaver.LlmMultiKeyRegistry.Entry → Prop) (limit : Nat)
    (Q : Weaver.LlmMultiKeyRegistry.State S → Prop) (V : State S → Prop) (seed : S) : State S → State S → Prop where
  | refl (s) : Run R A limit Q V seed s s
  | next (prior : Run R A limit Q V seed s t) (event : Step R A limit Q V seed t u) : Run R A limit Q V seed s u

theorem authority_projection (run : Run R A limit Q V seed s t) :
    Weaver.LlmMultiKeyRegistry.Run R A limit Q s.base t.base := by
  induction run with
  | refl => exact .refl _
  | next prior event ih =>
    cases event with
    | stage _ _ _ _ stable => exact .next ih (.stage _ _ stable)
    | commit _ _ _ _ _ _ actual _ _ => exact .next ih actual
    | restart => exact .next ih (.restart _)
    | recover _ _ authentic _ => exact .next ih (.recover _ authentic)
    | applySource => exact ih
    | applyAccount => exact ih
    | observe => exact ih
    | restoreSource => exact ih
    | restoreAccount => exact ih
    | activate => exact ih

theorem log_step_retained (event : Step R A limit Q V seed s t) (known : r ∈ s.log) : r ∈ t.log := by
  cases event <;> simp_all

theorem result_retained (run : Run R A limit Q V seed s t) (known : r ∈ s.log) : r ∈ t.log := by
  induction run with
  | refl => exact known
  | next _ event ih => exact log_step_retained event ih

theorem exact_source_result (gate : ApplyGate s s.sourceStore r worker) :
    s.sourceStore.body = r.before ∧ s.log[s.sourceStore.position]? = some r ∧ r.position = s.sourceStore.position+1 :=
  ⟨gate.2.2.2.2,gate.2.2.1,gate.2.2.2.1⟩

theorem exact_account_result (gate : ApplyGate s s.accountStore r worker) :
    s.accountStore.body = r.before ∧ s.log[s.accountStore.position]? = some r ∧ r.position = s.accountStore.position+1 :=
  ⟨gate.2.2.2.2,gate.2.2.1,gate.2.2.2.1⟩

theorem old_owner_blocks_application (old : worker ≠ s.base.fence) : ¬ ApplyGate s p r worker := by
  intro gate; exact old gate.1

theorem wrong_before_blocks_application (wrong : p.body ≠ r.before) : ¬ ApplyGate s p r worker := by
  intro gate; exact wrong gate.2.2.2.2

theorem duplicate_position_blocks_application (done : r.position = p.position) : ¬ ApplyGate s p r worker := by
  intro gate
  have h := gate.2.2.2.1
  omega

theorem partial_projection_blocks_join (behind : s.sourceStore.position ≠ s.log.length ∨ s.accountStore.position ≠ s.log.length) : ¬ Joined s := by
  intro joined
  rcases behind with source | account
  · exact source joined.1
  · exact account joined.2.1

theorem joined_source_is_authoritative (joined : Joined s) : s.sourceStore.body = image s.base := joined.2.2.1

theorem joined_account_holds_original_exposure (joined : Joined s) : s.accountStore.body.charged = s.base.charged := by
  rw [joined.2.2.2]; rfl

theorem unknown_exposure_retained (run : Run R A limit Q V seed s t) : s.base.charged ≤ t.base.charged :=
  Weaver.LlmMultiKeyRegistry.unknown_hold_retained (authority_projection run)

theorem original_spent_retained (run : Run R A limit Q V seed s t) (spent : s.base.spent claim = true) : t.base.spent claim = true :=
  Weaver.LlmMultiKeyRegistry.spent_retained (authority_projection run) spent

theorem original_pending_retained (run : Run R A limit Q V seed s t) (pending : req ∈ s.base.pending) : req ∈ t.base.pending :=
  Weaver.LlmMultiKeyRegistry.pending_intent_retained (authority_projection run) pending

theorem original_origin_retained (run : Run R A limit Q V seed s t) (known : s.base.origins key = some e) : t.base.origins key = some e :=
  Weaver.LlmMultiKeyRegistry.origin_immutable (authority_projection run) known

theorem shared_exposure_bound (run : Run R A limit Q V seed (initial seed) t) : t.base.charged ≤ limit :=
  Weaver.LlmMultiKeyRegistry.shared_budget_bound (authority_projection run)

theorem committed_request_cannot_repeat (s : State S) (known : s.base.decisions req.id = some original) : ¬ Weaver.LlmMultiKeyRegistry.Current s.base req :=
  Weaver.LlmMultiKeyRegistry.lost_reply_blocks_reapply known

theorem source_application_has_no_authority_effect (s : State S) (r : Result S) :
    ({s with sourceStore := ⟨r.position,r.after⟩} : State S).base = s.base := rfl

theorem account_application_has_no_authority_effect (s : State S) (r : Result S) :
    ({s with accountStore := ⟨r.position,r.after⟩} : State S).base = s.base := rfl

def Indexed (s : State S) : Prop :=
  ∀ r ∈ s.log, s.base.decisions r.request.id = some r.request

theorem indexed_step (event : Step R A limit Q V seed s t) (prior : Indexed s) : Indexed t := by
  cases event with
  | commit next req worker current qualified active actual fresh decided =>
    intro row member
    simp only [List.mem_append,List.mem_singleton] at member
    rcases member with old | same
    · exact Weaver.LlmMultiKeyRegistry.decision_step_immutable row.request.id actual (prior row old)
    · subst row; exact decided
  | stage => exact prior
  | applySource => exact prior
  | applyAccount => exact prior
  | observe => exact prior
  | restart => exact prior
  | recover => exact prior
  | restoreSource => exact prior
  | restoreAccount => exact prior
  | activate => exact prior

theorem initialized_result_index (run : Run R A limit Q V seed (initial seed) t) : Indexed t := by
  induction run with
  | refl => intro row member; simp [initial] at member
  | next _ event ih => exact indexed_step event ih

theorem initialized_position_bound (run : Run R A limit Q V seed (initial seed) t) :
    ∀ r ∈ t.log, r.position ≤ t.log.length := by
  induction run with
  | refl => intro row member; simp [initial] at member
  | next prior event ih =>
    cases event <;> try exact ih
    intro row member
    simp only [List.mem_append,List.mem_singleton] at member
    rcases member with old | same
    · have bound := ih row old
      simp only [List.length_append,List.length_singleton]
      omega
    · subst row; simp

theorem initialized_positions_ordered {S : Type} {seed : S} {t : State S}
    {R : Weaver.LlmMultiKeyRegistry.Request → S → S → Prop} {A : Weaver.LlmMultiKeyRegistry.Entry → Prop}
    {limit : Nat} {Q : Weaver.LlmMultiKeyRegistry.State S → Prop} {V : State S → Prop} (run : Run R A limit Q V seed (initial seed) t) :
    t.log.Pairwise (fun a b => a.position < b.position) := by
  induction run with
  | refl => simp [initial]
  | next prior event ih =>
    cases event <;> try exact ih
    apply List.pairwise_append.mpr
    refine ⟨ih,by simp,?_⟩
    intro row member appended single
    simp only [List.mem_singleton] at single
    subst appended
    have bound := initialized_position_bound prior row member
    simp only
    omega

theorem fresh_decision_has_no_old_result (req : Weaver.LlmMultiKeyRegistry.Request) (indexed : Indexed s)
    (fresh : s.base.decisions req.id = none) : ∀ r ∈ s.log, r.request.id ≠ req.id := by
  intro row member same
  have h := indexed row member
  rw [same,fresh] at h
  contradiction

#print axioms authority_projection
#print axioms result_retained
#print axioms exact_source_result
#print axioms exact_account_result
#print axioms old_owner_blocks_application
#print axioms wrong_before_blocks_application
#print axioms duplicate_position_blocks_application
#print axioms partial_projection_blocks_join
#print axioms joined_source_is_authoritative
#print axioms joined_account_holds_original_exposure
#print axioms unknown_exposure_retained
#print axioms original_spent_retained
#print axioms original_pending_retained
#print axioms original_origin_retained
#print axioms shared_exposure_bound
#print axioms committed_request_cannot_repeat
#print axioms source_application_has_no_authority_effect
#print axioms account_application_has_no_authority_effect
#print axioms initialized_result_index
#print axioms initialized_position_bound
#print axioms initialized_positions_ordered
#print axioms fresh_decision_has_no_old_result
end Weaver.LlmResultProjection
