import SemanticGatewaySlice
namespace Weaver.CommittedSemanticProfile

deriving instance DecidableEq for SemanticGatewaySlice.NodeRule
structure Node where
  rule : SemanticGatewaySlice.NodeRule
  required : List Nat
  context : Nat
  region : Nat
  deriving DecidableEq
structure Profile where
  semantic : LlmAuthoritativeScope.Contract
  nodes : List Node
  deriving DecidableEq
-- These maps are owned by original task admission, not by the adapter.
structure Assignment where
  profile : Nat → Nat
  node : Nat → Nat
structure Binding where
  profile : Nat
  node : Nat
  payload : Nat
  budget : Nat
  history : Nat
  deriving DecidableEq

def bindingFor (source : GatewayHeadCAS.Config) (a : Assignment) (key : Nat) : Binding :=
  ⟨a.profile key,a.node key,source.payload key,source.budget (source.root key),source.history (source.root key)⟩
structure State where
  profiles : Nat → Option Profile := fun _ => none
  bindings : Nat → Option Binding := fun _ => none
  epoch : Nat := 0
  recovered : Bool := true

def initial : State := {}
def ValidProfile (p : Profile) : Prop := p.nodes.Pairwise (fun x y => x.rule.node ≠ y.rule.node)
def Safe (source : GatewayHeadCAS.Config) (a : Assignment) (s : State) : Prop :=
  ∀ key b, s.bindings key = some b → b = bindingFor source a key ∧
    ∃ p n, s.profiles b.profile = some p ∧ n ∈ p.nodes ∧ n.rule.node = b.node

inductive Step (source : GatewayHeadCAS.Config) (a : Assignment) : State → State → Prop where
  | publish (s id p) (fresh : s.profiles id = none) (valid : ValidProfile p) (ready : s.recovered = true) :
      Step source a s {s with profiles := fun i => if i = id then some p else s.profiles i}
  | bind (s key p n) (fresh : s.bindings key = none) (known : s.profiles (a.profile key) = some p)
      (member : n ∈ p.nodes) (assigned : n.rule.node = a.node key) (ready : s.recovered = true) :
      Step source a s {s with bindings := fun i => if i = key then some (bindingFor source a key) else s.bindings i}
  | restart (s) : Step source a s {s with epoch := s.epoch+1, recovered := false}
  | recover (s) : Step source a s {s with recovered := true}
  | lostReplyOrRead (s) : Step source a s s
inductive Run (source : GatewayHeadCAS.Config) (a : Assignment) : State → State → Prop where
  | refl (s) : Run source a s s
  | next : Run source a x y → Step source a y z → Run source a x z

theorem profile_retained_step (event : Step source a s t) (stored : s.profiles id = some p) :
    t.profiles id = some p := by
  cases event with
  | publish sId new fresh valid ready =>
    by_cases same : id = sId
    · subst id; rw [fresh] at stored; contradiction
    · simp [same,stored]
  | _ => exact stored

theorem binding_retained_step (event : Step source a s t) (stored : s.bindings key = some b) :
    t.bindings key = some b := by
  cases event with
  | bind k p n fresh known member assigned ready =>
    by_cases same : key = k
    · subst key; rw [fresh] at stored; contradiction
    · simp [same,stored]
  | _ => exact stored

theorem safe_step (safe : Safe source a s) (event : Step source a s t) : Safe source a t := by
  intro key b stored
  cases event with
  | publish id p fresh valid ready =>
    obtain ⟨canonical,old,n,known,member,assigned⟩ := safe key b stored
    refine ⟨canonical,old,n,?_,member,assigned⟩
    by_cases same : b.profile = id
    · rw [same,fresh] at known; contradiction
    · simp [same,known]
  | bind k p n fresh known member assigned ready =>
    by_cases same : key = k
    · subst key
      have eq : b = bindingFor source a k := by simpa using stored.symm
      subst b
      exact ⟨rfl,p,n,known,member,assigned⟩
    · have old : s.bindings key = some b := by simpa [same] using stored
      exact safe key b old
  | _ => exact safe key b stored

theorem initialized_safe (run : Run source a initial s) : Safe source a s := by
  induction run with
  | refl => simp [Safe,initial]
  | next prior event ih => exact safe_step ih event

theorem profile_retained (run : Run source a s t) (stored : s.profiles id = some p) : t.profiles id = some p := by
  induction run with
  | refl => exact stored
  | next prior event ih => exact profile_retained_step event ih

theorem binding_retained (run : Run source a s t) (stored : s.bindings key = some b) : t.bindings key = some b := by
  induction run with
  | refl => exact stored
  | next prior event ih => exact binding_retained_step event ih

theorem conflicting_profile_cannot_replace (run : Run source a s t) (stored : s.profiles id = some p)
    (later : t.profiles id = some q) : p = q := by
  have same := profile_retained run stored
  rw [same] at later
  exact Option.some.inj later

theorem conflicting_binding_cannot_replace (run : Run source a s t) (stored : s.bindings key = some b)
    (later : t.bindings key = some c) : b = c := by
  have same := binding_retained run stored
  rw [same] at later
  exact Option.some.inj later

structure Resolved (s : State) (key : Nat) where
  binding : Binding
  profile : Profile
  node : Node
  stored : s.bindings key = some binding
  known : s.profiles binding.profile = some profile
  member : node ∈ profile.nodes
  matches : node.rule.node = binding.node

def registry (s : State) (a : Assignment) : LlmAuthoritativeScope.Registry :=
  ⟨a.profile,fun id => (s.profiles id).map Profile.semantic⟩
def templateFor (dynamic : LlmRouting.Config) (node : Node) : LlmRouting.Config :=
  {dynamic with requirements := node.required, contextNeeded := node.context, regionNeeded := node.region}
def normal (source : GatewayHeadCAS.Config) (a : Assignment) (s : State) (key : Nat)
    (dynamic : LlmRouting.Config) (r : Resolved s key) : RoutineRoutingConfig.Normal :=
  SemanticGatewaySlice.normalize source (registry s a) key (templateFor dynamic r.node) r.node.rule

theorem resolved_binding_is_original (safe : Safe source a s) (r : Resolved s key) :
    r.binding = bindingFor source a key := (safe key r.binding r.stored).1

theorem resolved_node_is_assigned (safe : Safe source a s) (r : Resolved s key) : r.node.rule.node = a.node key := by
  rw [r.matches,resolved_binding_is_original safe r]; rfl

theorem resolved_contract_is_published (safe : Safe source a s) (r : Resolved s key) :
    LlmAuthoritativeScope.contract source (registry s a) key = r.profile.semantic := by
  have canonical := resolved_binding_is_original safe r
  have known : s.profiles (a.profile key) = some r.profile := by simpa [canonical,bindingFor] using r.known
  simp [LlmAuthoritativeScope.contract,registry,known]

theorem original_record_covers_full_profile (safe : Safe source a s) (r : Resolved s key) :
    (normal source a s key dynamic r).profile = a.profile key ∧
    (normal source a s key dynamic r).node = a.node key ∧
    (normal source a s key dynamic r).response = r.profile.semantic.payload.schema ∧
    (normal source a s key dynamic r).requirements = r.node.required ++ r.node.rule.extraRequirements ∧
    (normal source a s key dynamic r).region = r.node.region := by
  refine ⟨rfl,resolved_node_is_assigned safe r,?_,rfl,rfl⟩
  change (LlmAuthoritativeScope.contract source (registry s a) key).payload.schema = _
  rw [resolved_contract_is_published safe r]

theorem external_template_cannot_replace_constraints (left right : LlmRouting.Config) (r : Resolved s key) :
    normal source a s key left r = normal source a s key right r := rfl

theorem node_context_cannot_be_lowered (r : Resolved s key) :
    r.node.context ≤ (normal source a s key dynamic r).contextNeeded := Nat.le_max_left _ _

theorem original_budget_cannot_be_raised (r : Resolved s key) :
    (normal source a s key dynamic r).allowance ≤ source.cost key := Nat.min_le_left _ _

theorem actual_route_preserves_committed_capability (r : Resolved s key)
    (event : LlmRouting.Step
      (SemanticGatewaySlice.routing source (registry s a) key (templateFor dynamic r.node) r.node.rule) owner before after)
    (changed : after.dispatches ≠ before.dispatches) (required : capability ∈ r.node.required) :
    ∃ p, (templateFor dynamic r.node).supports before.catalog p.target capability ∧
      owner.wireValid p ∧ owner.finalPolicyValid p (LlmRouting.view before) := by
  obtain ⟨p,bound,eligible,current,wire,policy⟩ := SemanticGatewaySlice.actual_dispatch_preserves_constructed_parent event changed
  exact ⟨p,eligible.2.1 capability required,wire,policy⟩

theorem actual_semantic_use_keeps_published_schema (safe : Safe source a s) (r : Resolved s key)
    (run : LlmAuthoritativeScope.Run source (registry s a)
      (SemanticGatewaySlice.routing source (registry s a) key (templateFor dynamic r.node) r.node.rule)
      profile rootOwner childOwner codec owner LlmAuthoritativeScope.initial execution)
    (member : u ∈ execution.uses) : u.ticket.scope.semantics.schema = r.profile.semantic.payload.schema := by
  obtain ⟨scope,commitment,schema⟩ := SemanticGatewaySlice.actual_uses_share_registered_contract run member
  rw [scope]
  change (LlmAuthoritativeScope.contract source (registry s a) key).payload.schema = _
  rw [resolved_contract_is_published safe r]

#print axioms profile_retained_step
#print axioms binding_retained_step
#print axioms safe_step
#print axioms initialized_safe
#print axioms profile_retained
#print axioms binding_retained
#print axioms conflicting_profile_cannot_replace
#print axioms conflicting_binding_cannot_replace
#print axioms resolved_binding_is_original
#print axioms resolved_node_is_assigned
#print axioms resolved_contract_is_published
#print axioms original_record_covers_full_profile
#print axioms external_template_cannot_replace_constraints
#print axioms node_context_cannot_be_lowered
#print axioms original_budget_cannot_be_raised
#print axioms actual_route_preserves_committed_capability
#print axioms actual_semantic_use_keeps_published_schema
end Weaver.CommittedSemanticProfile
