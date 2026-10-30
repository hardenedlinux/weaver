import CedarPooSpec.Admission.BoundOperation

/- Native host contract: authentic effect/state facts precede proof reuse.
   This bridge imports the actual pinned upstream package. It does not assert
   correctness of Rust, SQLite, transport callbacks or caller authentication. -/
namespace Weaver.PolicyBridge
open Cedar.Spec CedarPooSpec.Admission

theorem matching_actual_values_preserve_request
    [DecidableEq Effect] [DecidableEq HostState]
    (project : Effect → HostState → Request)
    (operation : BoundOperation Effect HostState project)
    (effect : Effect) (state : HostState)
    (accepted : operation.matches effect state = true) :
    operation.request = project effect state := by
  have equal : operation.effect = effect ∧ operation.state = state := by
    simpa [BoundOperation.matches] using accepted
  simp [BoundOperation.request,equal.1,equal.2]

theorem changed_effect_rejects_bound_reuse
    [DecidableEq Effect] [DecidableEq HostState]
    (project : Effect → HostState → Request)
    (operation : BoundOperation Effect HostState project)
    (effect : Effect) (state : HostState)
    (changed : operation.effect ≠ effect) : operation.matches effect state = false := by
  simp [BoundOperation.matches,changed]

theorem compound_acceptance_requires_each_error_free_allow
    (model : CedarPooSpec.PolicyModules.Model) (root : String) (requests : List Request)
    (entities : Entities) (receipt : CedarPooSpec.CompoundAuthorization.Receipt model root requests entities)
    (accepted : receipt.allowed = true) :
    ∀ request ∈ requests, let response := isAuthorized request entities receipt.policies
      (response.decision == .allow && response.erroringPolicies.isEmpty) = true := by
  have all : requests ≠ [] ∧ ∀ response ∈ receipt.responses,
      response.decision = .allow ∧ response.erroringPolicies.isEmpty = true := by
    simpa [CedarPooSpec.CompoundAuthorization.Receipt.allowed,List.all_eq_true] using accepted
  intro request member
  have evaluated : isAuthorized request entities receipt.policies ∈ receipt.responses := by
    rw [receipt.evaluated]
    exact List.mem_map.mpr ⟨request,member,rfl⟩
  simpa using all.2 _ evaluated


/- Semantic refinement only. The host authenticates actual values and establishes
   that native parsing/publication materialized this exact root. Quint checks
   publication ordering and failures; native tests check SQL and transport. -/
theorem governance_projection_and_actual_request_require_error_free_allow
    [DecidableEq Effect] [DecidableEq HostState]
    (project : Effect → HostState → Request)
    (operation : BoundOperation Effect HostState project)
    (effect : Effect) (state : HostState)
    (matched : operation.matches effect state = true)
    (model : CedarPooSpec.PolicyModules.Model) (root : String)
    (entities : Entities) (runtimePolicies : Policies)
    (materialized : model.compile root = .ok runtimePolicies)
    (receipt : CedarPooSpec.CompoundAuthorization.Receipt model root [operation.request] entities)
    (accepted : receipt.allowed = true) :
    let response := isAuthorized (project effect state) entities runtimePolicies
    (response.decision == .allow && response.erroringPolicies.isEmpty) = true := by
  have same : receipt.policies = runtimePolicies := by
    have equal := receipt.compiled.symm.trans materialized
    exact Except.ok.inj equal
  have request := matching_actual_values_preserve_request project operation effect state matched
  have allowed := compound_acceptance_requires_each_error_free_allow model root
    [operation.request] entities receipt accepted operation.request (by simp)
  simpa [same, request] using allowed

#print axioms governance_projection_and_actual_request_require_error_free_allow
#print axioms matching_actual_values_preserve_request
#print axioms changed_effect_rejects_bound_reuse
#print axioms compound_acceptance_requires_each_error_free_allow
end Weaver.PolicyBridge
