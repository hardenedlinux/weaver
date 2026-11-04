-- SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
--
-- SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0


import CedarPooSpec.Gateway.OAuth
import CedarPooSpec.Gateway.ZeroTrust

namespace WeaverOAuthRefinement
open Cedar.Spec CedarPooSpec

variable {E S V : Type} [BEq E] [LawfulBEq E] {project : E → S → Request}
  {original : Gateway.Profile} {object : Gateway.ProfileObject.Object}
  {publication : Gateway.ProfileObject.Publication original object}
  {prepared : Gateway.Prepared E S project} {model : PolicyModules.Model}
  {effect : E} {state : S} {actualContext : Gateway.Context}
  {checks : List Gateway.Assessment} {entities : Entities}
  {host : Gateway.ZeroTrust.Host E V}
  {proposal : Gateway.ZeroTrust.Proposal host publication prepared model effect state actualContext checks entities}

theorem final_effect_requires_both
    (observe : E → V → Gateway.OAuth.CurrentUse)
    (use : Gateway.ZeroTrust.FinalUse proposal)
    (accepted : (Gateway.OAuth.strengthen (Gateway.ZeroTrust.framework proposal) observe).required effect use.actual) :
    (observe effect use.actual).bound ∧
    host.committed use.actual proposal.after ∧ host.unknownRetained use.actual proposal.after :=
  ⟨Gateway.OAuth.strengthened_requires_fresh_oauth _ observe accepted, use.committed, use.unknownRetained⟩

theorem refreshed_grant_preserves_original_consumption
    (observe : E → V → Gateway.OAuth.CurrentUse)
    (assessment : ZeroTrust.Requirement E V)
    (accepted : (Gateway.OAuth.strengthen (Gateway.ZeroTrust.continuing proposal assessment) observe).required requested actual)
    (renewed : Admission.AuthorityLedger E) (renewedId : String) :
    (observe requested actual).bound ∧ host.unknownRetained actual proposal.after ∧
    Gateway.consumeAdmission publication proposal.receipt (host.operations actual) renewed renewedId =
      .error .operationAlreadyAdmitted := by
  have base := Gateway.OAuth.strengthened_preserves_gateway _ observe accepted
  have ⟨_, _, retained, consumed⟩ := Gateway.ZeroTrust.continuing_use_preserves_original_consumption proposal base renewed renewedId
  exact ⟨Gateway.OAuth.strengthened_requires_fresh_oauth _ observe accepted, retained, consumed⟩

#print axioms final_effect_requires_both
#print axioms refreshed_grant_preserves_original_consumption
end WeaverOAuthRefinement
