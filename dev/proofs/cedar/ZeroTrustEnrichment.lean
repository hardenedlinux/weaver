import CedarPooSpec.ZeroTrust
import WeaverPolicyBridge

/-! Candidate-library consumer, checked in isolation against the upstream PR.
The normal WeaverPolicyBridge target retains its unchanged dependency pin.
Zero Trust semantics belong to CedarPooSpec.ZeroTrust; this file only enriches
the existing Weaver view and applies the library's final-use laws. -/
namespace Weaver.ZeroTrustEnrichment

structure RuntimeView extends PolicyBridge.PublicationContext where
  semanticContext : CedarPooSpec.Gateway.Context
  commitFloor : Nat
  budgetVersion : Nat
  historyPrefix : List Nat
  deriving DecidableEq

open CedarPooSpec
variable {E S : Type} [BEq E] [LawfulBEq E] {project : E → S → Cedar.Spec.Request}
  {original : Gateway.Profile} {object : Gateway.ProfileObject.Object}
  {publication : Gateway.ProfileObject.Publication original object}
  {prepared : Gateway.Prepared E S project} {model : PolicyModules.Model}
  {effect : E} {state : S} {context : Gateway.Context}
  {checks : List Gateway.Assessment} {entities : Cedar.Spec.Entities}
  {host : ZeroTrust.Host E RuntimeView}
  (proposal : ZeroTrust.Proposal host publication prepared model effect state context checks entities)

theorem capacity_cannot_rebase_changed_floor (actual : RuntimeView)
    (_room : frames < 2) (changed : actual.commitFloor ≠ proposal.before.commitFloor) :
    ¬ ∃ use : ZeroTrust.FinalUse proposal, use.actual = actual := by
  apply ZeroTrust.changed_complete_view_cannot_finalize proposal
  exact fun same => changed (congrArg RuntimeView.commitFloor same)

theorem changed_history_cannot_finalize (actual : RuntimeView)
    (changed : actual.historyPrefix ≠ proposal.before.historyPrefix) :
    ¬ ∃ use : ZeroTrust.FinalUse proposal, use.actual = actual := by
  apply ZeroTrust.changed_complete_view_cannot_finalize proposal
  exact fun same => changed (congrArg RuntimeView.historyPrefix same)

theorem changed_budget_cannot_finalize (actual : RuntimeView)
    (changed : actual.budgetVersion ≠ proposal.before.budgetVersion) :
    ¬ ∃ use : ZeroTrust.FinalUse proposal, use.actual = actual := by
  apply ZeroTrust.changed_complete_view_cannot_finalize proposal
  exact fun same => changed (congrArg RuntimeView.budgetVersion same)

theorem changed_owner_cannot_finalize (actual : RuntimeView)
    (changed : actual.executorSession ≠ proposal.before.executorSession) :
    ¬ ∃ use : ZeroTrust.FinalUse proposal, use.actual = actual := by
  apply ZeroTrust.changed_complete_view_cannot_finalize proposal
  exact fun same => changed (congrArg (fun image : RuntimeView => image.executorSession) same)

theorem gateway_consumes_core_contract (use : ZeroTrust.FinalUse proposal) :
    original.Refines prepared.profile ∧
    prepared.context = host.context use.actual ∧
    host.currentAtUse use.actual ∧ host.committed use.actual proposal.after ∧
    host.unknownRetained use.actual proposal.after ∧ host.mediated effect use.actual :=
  ⟨ZeroTrust.final_use_preserves_original_contract proposal use,
   ZeroTrust.final_use_preserves_current_context proposal use,
   use.current, use.committed, use.unknownRetained, use.mediated⟩

#print axioms capacity_cannot_rebase_changed_floor
#print axioms changed_history_cannot_finalize
#print axioms changed_budget_cannot_finalize
#print axioms changed_owner_cannot_finalize
#print axioms gateway_consumes_core_contract
end Weaver.ZeroTrustEnrichment
