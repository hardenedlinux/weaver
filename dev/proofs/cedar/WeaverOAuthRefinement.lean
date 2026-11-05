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
structure Witness (Key : Type) where
  revoked : Key → Prop
  epoch : Nat

def Retains (old current : Witness Key) : Prop :=
  old.epoch ≤ current.epoch ∧ ∀ key, old.revoked key → current.revoked key

def RelayedUse (current : Witness Key) (root leaf : Key) (senderBound : Prop) : Prop :=
  senderBound ∧ ¬ current.revoked root ∧ ¬ current.revoked leaf

theorem retained_root_revocation_blocks_child
    (retained : Retains old current) (revoked : old.revoked root) :
    ¬ RelayedUse current root leaf senderBound := by
  intro accepted
  exact accepted.2.1 (retained.2 root revoked)

theorem retained_epoch_rejects_retired_signer
    (retained : Retains old current) (retired : signedEpoch < old.epoch) :
    signedEpoch ≠ current.epoch := by
  exact Nat.ne_of_lt (Nat.lt_of_lt_of_le retired retained.1)

theorem ahead_witness_blocks_unreconciled_use
    {projectedLength witnessLength : Nat} {mayUse : Prop} :
    projectedLength < witnessLength → ¬ (projectedLength = witnessLength ∧ mayUse) := by
  intro ahead accepted
  exact (Nat.ne_of_lt ahead) accepted.1

/-- The locked join matches every record used by the immutable candidate rule.
    Time, revocation and the witness are observations of the deciding scope. -/
theorem prepared_use_refines_current
    {Records : Type} {candidate current : Records} {staticCheck : Records → Prop}
    {view : Witness Key} {root leaf : Key} {senderBound : Prop}
    {starts now expires projectedLength witnessLength : Nat}
    (checked : staticCheck candidate) (same : current = candidate)
    (active : RelayedUse view root leaf senderBound)
    (fresh : starts ≤ now ∧ now < expires)
    (reconciled : projectedLength = witnessLength) :
    staticCheck current ∧ RelayedUse view root leaf senderBound ∧
      (starts ≤ now ∧ now < expires) ∧ projectedLength = witnessLength := by
  exact ⟨same.symm ▸ checked, active, fresh, reconciled⟩

/-- Reusing a decoded profile requires the same record in the deciding scope.
    The task floor and the other live execution predicates are independent. -/
theorem retained_profile_refines_current
    {Record : Type} {checked actual : Record} {valid : Record → Prop}
    {floorCurrent otherLiveGuards : Prop}
    (decoded : valid checked) (same : actual = checked)
    (floor : floorCurrent) (live : otherLiveGuards) :
    valid actual ∧ floorCurrent ∧ otherLiveGuards := by
  exact ⟨same.symm ▸ decoded, floor, live⟩

/-- A prepared SQL program is evaluated on the deciding image. Only evidence
    already checked against that same image can replace a second traversal. -/
theorem currentness_reuse_preserves_decision
    {Snapshot Claims : Type} {image : Snapshot} {checked observed : Claims}
    (readClaims : Snapshot → Claims) (guard : Snapshot → Prop)
    (fromScope : checked = readClaims image) :
    (checked = observed ∧ guard image) ↔
      (readClaims image = observed ∧ guard image) := by
  rw [fromScope]

#print axioms currentness_reuse_preserves_decision
#print axioms retained_profile_refines_current
#print axioms prepared_use_refines_current
#print axioms retained_root_revocation_blocks_child
#print axioms retained_epoch_rejects_retired_signer
#print axioms ahead_witness_blocks_unreconciled_use

end WeaverOAuthRefinement
