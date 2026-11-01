import GerbilExitQualification
namespace Weaver.DynamicImportBoundary

structure Contract where
  requiredBindings : List Nat
  resolve : Nat → Nat
  requiredInitializers : List Nat
  bodyDigest : Nat
  interfaceABI : Nat

structure Publication where
  resolve : Nat → Nat
  activeInitializers : List Nat
  bodyDigest : Nat
  interfaceABI : Nat

def Admitted (c : Contract) (p : Publication) : Prop :=
  (∀ name ∈ c.requiredBindings, p.resolve name = c.resolve name) ∧
  (∀ body ∈ c.requiredInitializers, body ∈ p.activeInitializers) ∧
  p.bodyDigest = c.bodyDigest ∧ p.interfaceABI = c.interfaceABI

def BindingsAgree (names : List Nat) (a b : Nat → Nat) : Prop :=
  ∀ name ∈ names, a name = b name

theorem binding_agreement_composes
    (first : BindingsAgree names original umbrella)
    (second : BindingsAgree names umbrella owner) :
    BindingsAgree names original owner := by
  intro name required
  exact (first name required).trans (second name required)

theorem admitted_bindings_keep_original_owner (admitted : Admitted c p)
    (required : name ∈ c.requiredBindings) : p.resolve name = c.resolve name :=
  admitted.1 name required

theorem required_initializer_cannot_be_pruned (admitted : Admitted c p)
    (required : body ∈ c.requiredInitializers) : body ∈ p.activeInitializers :=
  admitted.2.1 body required

theorem executable_bodies_are_unchanged (admitted : Admitted c p) :
    p.bodyDigest = c.bodyDigest := admitted.2.2.1

theorem interface_abi_is_preserved (admitted : Admitted c p) :
    p.interfaceABI = c.interfaceABI := admitted.2.2.2

theorem absent_required_initializer_rejects
    (required : body ∈ c.requiredInitializers) (missing : body ∉ p.activeInitializers) :
    ¬ Admitted c p := by
  intro admitted
  exact missing (required_initializer_cannot_be_pruned admitted required)

theorem dynamic_native_pass_still_closes_handles
    (pass : GerbilExitQualification.Qualified clock receipt) :
    receipt.returned = true ∧ receipt.handles = [] :=
  GerbilExitQualification.qualification_preserves_cleanup pass

theorem late_dynamic_exit_is_not_qualification
    (late : clock.budget < receipt.elapsed) :
    ¬ GerbilExitQualification.Qualified clock receipt :=
  GerbilExitQualification.late_natural_exit_still_fails late

theorem dynamic_pass_still_requires_final_policy
    (_pass : GerbilExitQualification.Qualified clock receipt)
    (event : LlmRouting.Step router owner before after)
    (changed : after.dispatches ≠ before.dispatches) :
    ∃ p, owner.wireValid p ∧ owner.finalPolicyValid p (LlmRouting.view before) :=
  GerbilExitQualification.natural_pass_still_needs_gateway_policy _pass event changed

#print axioms binding_agreement_composes
#print axioms admitted_bindings_keep_original_owner
#print axioms required_initializer_cannot_be_pruned
#print axioms executable_bodies_are_unchanged
#print axioms interface_abi_is_preserved
#print axioms absent_required_initializer_rejects
#print axioms dynamic_native_pass_still_closes_handles
#print axioms late_dynamic_exit_is_not_qualification
#print axioms dynamic_pass_still_requires_final_policy
end Weaver.DynamicImportBoundary
