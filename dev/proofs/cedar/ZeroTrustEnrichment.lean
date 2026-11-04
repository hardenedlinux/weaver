-- SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
--
-- SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

import CedarPooSpec.Gateway.ZeroTrust
import CedarPooSpec.Gateway.PublicationReview
import PublicationRecovery
import WeaverPolicyBridge
import ProviderRpc

/-! Maintained consumer of the locked upstream Gateway Zero Trust framework.
The ordinary Lake target checks this composition against the released LeanPoo closure.
The generic functional framework belongs to CedarPooSpec.ZeroTrust; Gateway
specializes it through Gateway.ZeroTrust and existing POO publication; this file enriches
the existing Weaver view and applies the library's final-use laws. -/
namespace Weaver.ZeroTrustEnrichment

-- The existing publication recovery owner supplies preservation. This adapter
-- adds no ledger: the final invocation's exact post-state is related to that
-- owner's actual Step by an explicit, still unproved native refinement premise.
theorem reviewed_publication_keeps_recovery_contract
    {Result : Type}
    {authority : CedarPooSpec.Gateway.PublicationReview.Host Nat Result
      (PublicationRecovery.State Nat) Nat Nat Nat}
    {template : LeanPoo.Functional.DeclarativeMetadata.Contract Unit Nat Result}
    {prepare : PublicationRecovery.State Nat → Nat → Except Unit (Result × PublicationRecovery.State Nat)}
    {command : Nat} {actual : PublicationRecovery.State Nat}
    (final : CedarPooSpec.Gateway.PublicationReview.Final authority template prepare command actual)
    (refinement : ∀ before result after, authority.commit before result after →
      PublicationRecovery.Step before after)
    (safe : PublicationRecovery.Safe held calls actual) :
    authority.security.currentAtUse actual ∧ authority.pendingAdmissible command actual ∧
      PublicationRecovery.Extends actual final.receipt.state ∧
      PublicationRecovery.PreservesIntents actual final.receipt.state ∧
      PublicationRecovery.Safe held calls final.receipt.state := by
  have step := refinement _ _ _ final.committed
  exact ⟨final.current.2.2.1, final.pending,
    PublicationRecovery.step_preserves_original_decisions step,
    PublicationRecovery.step_preserves_original_intents step,
    PublicationRecovery.step_preserves_accounting safe step⟩

#print axioms reviewed_publication_keeps_recovery_contract

theorem durable_review_binding_survives_final_cas
    {Result : Type}
    {authority : CedarPooSpec.Gateway.PublicationReview.Host Nat Result
      (PublicationRecovery.State Nat) Nat Nat Nat}
    {template : LeanPoo.Functional.DeclarativeMetadata.Contract Unit Nat Result}
    {prepare : PublicationRecovery.State Nat → Nat → Except Unit (Result × PublicationRecovery.State Nat)}
    {command : Nat} {actual : PublicationRecovery.State Nat}
    (final : CedarPooSpec.Gateway.PublicationReview.Final authority template prepare command actual)
    (materializes : ∀ artifact, authority.registrationCommitted actual command artifact →
      ∃ entry, actual.reviewAnchor command = some entry ∧ entry.artifact = artifact)
    (refinement : ∀ before result after, authority.commit before result after →
      PublicationRecovery.Step before after) :
    authority.registryRecovered actual ∧ authority.registrarCurrent command actual ∧
      ∃ artifact entry, authority.approvedEvidenceAt actual command = some artifact ∧
        final.receipt.state.reviewAnchor command = some entry ∧ entry.artifact = artifact := by
  obtain ⟨artifact, present⟩ := final.approved
  obtain ⟨entry, registered, bound⟩ := materializes artifact (final.durable artifact present)
  exact ⟨final.recovered, final.fenced, artifact, entry, present,
    PublicationRecovery.step_preserves_review_anchor (refinement _ _ _ final.committed) registered, bound⟩

#print axioms durable_review_binding_survives_final_cas

-- Apply the sole SPEC identity meaning; no downstream identity evaluator or
-- credential issuance/revocation state machine is defined here.
theorem registrar_binding_reaches_final_cas
    {Result : Type}
    {authority : CedarPooSpec.Gateway.PublicationReview.Host Nat Result
      (PublicationRecovery.State Nat) Nat Nat Nat}
    {identity : CedarPooSpec.Gateway.PublicationReview.RegistrarAuthority Nat
      (PublicationRecovery.State Nat) Nat Nat Nat Nat Nat}
    {binding : CedarPooSpec.Gateway.PublicationReview.RegistrarBinding Nat Nat Nat Nat Nat}
    {template : LeanPoo.Functional.DeclarativeMetadata.Contract Unit Nat Result}
    {prepare : PublicationRecovery.State Nat → Nat → Except Unit (Result × PublicationRecovery.State Nat)}
    {command : Nat} {actual : PublicationRecovery.State Nat}
    (meaning : authority.registrarCurrent = identity.admitted binding)
    (final : CedarPooSpec.Gateway.PublicationReview.Final authority template prepare command actual) :
    binding = identity.current actual ∧ ¬ identity.revoked binding actual ∧
      identity.possession binding command actual ∧
      authority.security.consumptionCommitted command actual ∧
      authority.security.unknownRetained command actual := by
  have admitted := final.fenced
  rw [meaning] at admitted
  have bound := CedarPooSpec.Gateway.PublicationReview.registrar_admission_retains_exact_binding admitted
  exact ⟨bound.1, bound.2.1, bound.2.2, final.current.2.2.2.1, final.current.2.2.2.2.1⟩

#print axioms registrar_binding_reaches_final_cas

/- Independent producer qualification and the SPEC final-use contract are both
   required. This theorem does not derive qualified from authenticated, or prove
   the native SQL/IO refinement. Integration fixtures discharge neither premise. -/
theorem authenticated_producer_and_spec_publication_compose
    {Result : Type}
    {authority : CedarPooSpec.Gateway.PublicationReview.Host Nat Result
      (PublicationRecovery.State Nat) Nat Nat Nat}
    {template : LeanPoo.Functional.DeclarativeMetadata.Contract Unit Nat Result}
    {prepare : PublicationRecovery.State Nat → Nat → Except Unit (Result × PublicationRecovery.State Nat)}
    {command payload fence : Nat} {actual : PublicationRecovery.State Nat}
    {auth qualified : PublicationRecovery.DeploymentReview.Evidence → Prop}
    {cut : PublicationRecovery.DeploymentReview.Cut}
    {evidence : PublicationRecovery.DeploymentReview.Evidence}
    (admitted : PublicationRecovery.DeploymentReview.Admitted auth qualified cut actual command payload fence evidence)
    (final : CedarPooSpec.Gateway.PublicationReview.Final authority template prepare command actual)
    (refinement : ∀ before result after, authority.commit before result after →
      PublicationRecovery.Step before after)
    (safe : PublicationRecovery.Safe held calls actual) :
    auth evidence ∧ qualified evidence ∧
      (authority.security.currentAtUse actual ∧ authority.pendingAdmissible command actual ∧
      PublicationRecovery.Extends actual final.receipt.state ∧
      PublicationRecovery.PreservesIntents actual final.receipt.state ∧
      PublicationRecovery.Safe held calls final.receipt.state) := by
  exact ⟨admitted.1, admitted.2.1,
    reviewed_publication_keeps_recovery_contract final refinement safe⟩

#print axioms authenticated_producer_and_spec_publication_compose

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

-- Usage control enriches the existing continuing Gateway interpretation. It
-- neither introduces a second consumption ledger nor permits recovery to
-- substitute a fresh root. Source authority remains a native refinement duty.
theorem usage_control_keeps_current_consumption
    (control : ZeroTrust.UsageControl E RuntimeView)
    (assessment : ZeroTrust.Requirement E RuntimeView)
    (bound : control.core = Gateway.ZeroTrust.continuing proposal assessment)
    (accepted : control.step phase transition before effect after) :
    host.currentAtUse before ∧ host.committed before proposal.after ∧
      Nonempty (Gateway.ZeroTrust.CommittedPrefix proposal before) ∧
      host.unknownRetained before proposal.after := by
  have required := ZeroTrust.usage_retains_core control accepted
  rw [bound] at required
  exact ⟨required.2.2.1, required.2.2.2.1.1, required.2.2.2.1.2,
    required.2.2.2.2.1⟩

#print axioms usage_control_keeps_current_consumption

-- The native deciding writer must materialize every input from the same
-- authoritative image. An arbitrary caller assertion cannot instantiate this
-- premise. Strengthen the upstream continuing contract, never replace it.
theorem provider_exposure_strengthens_continuing_zero_trust
    (accepted : ((Gateway.ZeroTrust.continuing proposal assessment).withRequirement
      (fun _ _ => Weaver.ProviderRpc.ProviderExposure claim reserved originalCost held budget reservations ∧
        Weaver.ProviderRpc.SharedExecutionExposure claimsMatch requestCosts messageCosts providerCosts held budget originalBudget)).required
      requested actual) :
    (Gateway.ZeroTrust.continuing proposal assessment).required requested actual ∧
    Weaver.ProviderRpc.ProviderExposure claim reserved originalCost held budget reservations ∧
    Weaver.ProviderRpc.SharedExecutionExposure claimsMatch requestCosts messageCosts providerCosts held budget originalBudget := by
  exact ⟨ZeroTrust.with_requirement_preserves_framework _ _ _ _ accepted, accepted.2.1.2⟩

#print axioms provider_exposure_strengthens_continuing_zero_trust

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
