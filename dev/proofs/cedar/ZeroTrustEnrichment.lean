import CedarPooSpec.Gateway.ZeroTrust
import WeaverPolicyBridge

/-! Candidate-library consumer, checked in isolation against the upstream PR.
The normal WeaverPolicyBridge target retains its unchanged dependency pin.
The generic functional framework belongs to CedarPooSpec.ZeroTrust; Gateway
specializes it through Gateway.ZeroTrust and existing POO publication; this file enriches
the existing Weaver view and applies the library's final-use laws. -/
namespace Weaver.ZeroTrustEnrichment

structure RuntimeView extends PolicyBridge.PublicationContext where
  semanticContext : CedarPooSpec.Gateway.Context
  commitFloor : Nat
  budgetVersion : Nat
  historyPrefix : List Nat
  pendingPublications : List (String × String)
  deriving DecidableEq

open CedarPooSpec
variable {E S : Type} [BEq E] [LawfulBEq E] {project : E → S → Cedar.Spec.Request}
  {original : Gateway.Profile} {object : Gateway.ProfileObject.Object}
  {publication : Gateway.ProfileObject.Publication original object}
  {prepared : Gateway.Prepared E S project} {model : PolicyModules.Model}
  {effect : E} {state : S} {context : Gateway.Context}
  {checks : List Gateway.Assessment} {entities : Cedar.Spec.Entities}
  {host : Gateway.ZeroTrust.Host E RuntimeView}
  (proposal : Gateway.ZeroTrust.Proposal host publication prepared model effect state context checks entities)

theorem capacity_cannot_rebase_changed_floor (actual : RuntimeView)
    (_room : frames < 2) (changed : actual.commitFloor ≠ proposal.before.commitFloor) :
    ¬ ∃ use : Gateway.ZeroTrust.FinalUse proposal, use.actual = actual := by
  apply Gateway.ZeroTrust.changed_complete_view_cannot_finalize proposal
  exact fun same => changed (congrArg RuntimeView.commitFloor same)

theorem changed_history_cannot_finalize (actual : RuntimeView)
    (changed : actual.historyPrefix ≠ proposal.before.historyPrefix) :
    ¬ ∃ use : Gateway.ZeroTrust.FinalUse proposal, use.actual = actual := by
  apply Gateway.ZeroTrust.changed_complete_view_cannot_finalize proposal
  exact fun same => changed (congrArg RuntimeView.historyPrefix same)

theorem changed_budget_cannot_finalize (actual : RuntimeView)
    (changed : actual.budgetVersion ≠ proposal.before.budgetVersion) :
    ¬ ∃ use : Gateway.ZeroTrust.FinalUse proposal, use.actual = actual := by
  apply Gateway.ZeroTrust.changed_complete_view_cannot_finalize proposal
  exact fun same => changed (congrArg RuntimeView.budgetVersion same)

theorem changed_owner_cannot_finalize (actual : RuntimeView)
    (changed : actual.executorSession ≠ proposal.before.executorSession) :
    ¬ ∃ use : Gateway.ZeroTrust.FinalUse proposal, use.actual = actual := by
  apply Gateway.ZeroTrust.changed_complete_view_cannot_finalize proposal
  exact fun same => changed (congrArg (fun image : RuntimeView => image.executorSession) same)

theorem gateway_consumes_core_contract (use : Gateway.ZeroTrust.FinalUse proposal) :
    original.Refines prepared.profile ∧
    prepared.context = host.context use.actual ∧
    host.currentAtUse use.actual ∧ host.committed use.actual proposal.after ∧
    host.unknownRetained use.actual proposal.after ∧ host.mediated effect use.actual :=
  ⟨Gateway.ZeroTrust.final_use_preserves_original_contract proposal use,
   Gateway.ZeroTrust.final_use_preserves_current_context proposal use,
   use.current, use.committed, use.unknownRetained, use.mediated⟩

#print axioms capacity_cannot_rebase_changed_floor
#print axioms changed_history_cannot_finalize
#print axioms changed_budget_cannot_finalize
#print axioms changed_owner_cannot_finalize
#print axioms gateway_consumes_core_contract

-- Pure specialization preserves the actual POO publication's original Contract
-- and all generic framework conditions. It grants no native IO capability.
theorem gateway_specialization_retains_generic_framework
    (accepted : (Gateway.ZeroTrust.specialize proposal extra).required requested actual) :
    (Gateway.ZeroTrust.framework proposal).required requested actual ∧
      original.Refines prepared.profile :=
  Gateway.ZeroTrust.specialization_preserves_core_and_original proposal accepted

#print axioms gateway_specialization_retains_generic_framework

theorem continuing_uses_current_state_and_original_consumption
    (accepted : (Gateway.ZeroTrust.continuing proposal assessment).required requested actual)
    (renewed : Admission.AuthorityLedger E) (renewedId : String) :
    host.currentAtUse actual ∧ Nonempty (Gateway.ZeroTrust.CommittedPrefix proposal actual) ∧
    host.unknownRetained actual proposal.after ∧
    Gateway.consumeAdmission publication proposal.receipt (host.operations actual) renewed renewedId =
      .error .operationAlreadyAdmitted := by
  have retained := Gateway.ZeroTrust.continuing_use_preserves_original_consumption
    proposal accepted renewed renewedId
  exact ⟨accepted.2.2.1, accepted.2.2.2.1.2, retained.2.2.1, retained.2.2.2⟩

#print axioms continuing_uses_current_state_and_original_consumption

theorem retained_parent_and_selected_object_reach_gateway
    {parentObject selectedObject : ZeroTrust.ProfileObject.Object (Gateway.ZeroTrust.framework proposal).required}
    (requiredParent : ZeroTrust.ProfileObject.Session (Gateway.ZeroTrust.framework proposal).required parentObject)
    (selected : ZeroTrust.ProfileObject.Session (Gateway.ZeroTrust.framework proposal).required selectedObject)
    (composition : ZeroTrust.ProfileObject.Composed requiredParent selected)
    (read : Gateway.ZeroTrust.fromFrameworkObject proposal requiredParent selected = some composition)
    (accepted : composition.requirement requested actual) :
    parentObject.read .profile = some composition.parentProfile ∧
    selectedObject.read .profile = some composition.selectedProfile ∧
    composition.parentProfile.requirement requested actual ∧
    (Gateway.ZeroTrust.framework proposal).required requested actual ∧ original.Refines prepared.profile :=
  Gateway.ZeroTrust.framework_object_preserves_gateway_contract proposal requiredParent selected composition read accepted

#print axioms retained_parent_and_selected_object_reach_gateway

theorem changed_pending_set_invalidates_initial_view (actual : RuntimeView)
    (changed : actual.pendingPublications ≠ proposal.before.pendingPublications) :
    ¬ ∃ use : Gateway.ZeroTrust.FinalUse proposal, use.actual = actual := by
  apply Gateway.ZeroTrust.changed_complete_view_cannot_finalize proposal
  exact fun same => changed (congrArg RuntimeView.pendingPublications same)

theorem pending_policy_blocks_ongoing_use
    (projectsBarrier : ∀ view, view.pendingPublications ≠ [] → ¬ host.currentAtUse view)
    (pending : actual.pendingPublications ≠ []) :
    ¬ (Gateway.ZeroTrust.continuing proposal assessment).required requested actual :=
  fun accepted => projectsBarrier actual pending accepted.2.2.1

#print axioms changed_pending_set_invalidates_initial_view
#print axioms pending_policy_blocks_ongoing_use
end Weaver.ZeroTrustEnrichment
