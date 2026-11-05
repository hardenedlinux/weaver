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

/-- Prequalification is transported only across exact artifact equality.
    Review authority, pending publication and OAuth are live premises. -/
theorem prepared_review_refines_live
    {Image : Type} {prepared live : Image} {qualifies : Image → Prop}
    {pendingClear issuerCurrent oauthCurrent fenceCurrent : Prop}
    (verified : qualifies prepared) (matched : live = prepared)
    (pending : pendingClear) (issuer : issuerCurrent)
    (oauth : oauthCurrent) (fence : fenceCurrent) :
    qualifies live ∧ pendingClear ∧ issuerCurrent ∧ oauthCurrent ∧ fenceCurrent := by
  exact ⟨matched.symm ▸ verified, pending, issuer, oauth, fence⟩

/-- A prepared original transports a deterministic static check across exact
    row equality. Mutable domain state and the original publication link
    belong to the deciding transaction. -/
theorem prepared_original_refines_live
    {Row View : Type} {candidate actual : Row} {staticCheck : Row → Prop}
    {view : View} {liveChecks : View → Prop}
    (verified : staticCheck candidate) (same : actual = candidate)
    (live : liveChecks view) :
    staticCheck actual ∧ liveChecks view :=
  ⟨same.symm ▸ verified, live⟩

/-- A claim insert changes the manifest, but can share the locked domain
    identity with the ensuing capacity-guarded charge and history append
    when neither root nor the origin can change between those effects. -/
theorem retained_domain_identity_preserves_mutation_target
    {Image Keys : Type} {before after : Image} {retained : Keys}
    {keys : Image → Keys} {guardedMutation : Keys → Prop}
    (observed : retained = keys before) (stable : keys before = keys after) :
    guardedMutation retained ↔ guardedMutation (keys after) := by
  rw [observed, stable]

/-- The held stripe keys for an accepted effect identify the current
    origin and roots. The owner gate stabilizes this equality during use. -/
theorem retained_stamp_selects_live_keys
    {Stamp Keys : Type} {expected current : Stamp}
    (select : Stamp → Keys) (matched : current = expected) :
    select expected = select current :=
  congrArg select matched.symm

/-- Program compatibility is an engine premise. The query is rebound to
    the requested family and evaluated on the deciding transaction.
    No equality between earlier and current domain rows is assumed. -/
theorem prepared_domain_program_preserves_live_decision
    {Image Family View : Type}
    (readFresh runProgram : Image → Family → Option View)
    (agrees : ∀ image family, runProgram image family = readFresh image family)
    (decide : Image → Option View → Prop)
    (current : Image) (family : Family) :
    decide current (runProgram current family) ↔
      decide current (readFresh current family) := by
  rw [agrees]

/-- One deciding image supplies dispatch, cursor and pending-range facts.
    The live authorization premise remains independent of the projection. -/
theorem joined_release_progress_preserves_gate
    {Image Progress : Type} (separate joined : Image → Progress)
    (same : ∀ image, joined image = separate image)
    (liveAuthorization : Image → Prop) (progressAllows : Progress → Prop)
    (current : Image) :
    (liveAuthorization current ∧ progressAllows (joined current)) ↔
      (liveAuthorization current ∧ progressAllows (separate current)) := by
  rw [same]

/-- Experimental pre-queue marker. Exactly one conditional write means the
    pending row matched. Scheduling order supplies no authority premise. -/
theorem conditional_range_mark_refines_queue_gate
    {rowMatches live oauthAtQueue : Prop} {affected : Nat}
    (exact : affected = 1 ↔ rowMatches) :
    (live ∧ affected = 1 ∧ oauthAtQueue) ↔
      (live ∧ rowMatches ∧ oauthAtQueue) := by
  rw [exact]

/-- The conditional marker is transaction-local. Independent observers
    see the original row through callback failure and native rollback. -/
theorem range_marker_rollback_preserves_durable
    {State : Type} (original staged : State) (committed : Bool)
    (rollback : committed = false) :
    (if committed then staged else original) = original := by
  simp [rollback]

/-- The order statistic counts a later instrumented arrival granted first.
    FIFO, when provided by a scheduler, rules out this inversion. -/
theorem fifo_excludes_arrival_grant_inversion
    {olderArrival youngerArrival olderGrant youngerGrant : Nat}
    (fifo : olderArrival < youngerArrival → olderGrant ≤ youngerGrant)
    (arrived : olderArrival < youngerArrival) :
    ¬ youngerGrant < olderGrant :=
  Nat.not_lt_of_ge (fifo arrived)

/-- Compatible programs execute the same lookup and post-queue update
    against the deciding image. The authorization and queue-time premises
    are independent of native program preparation. -/
theorem cached_release_programs_preserve_ordered_effect
    {Image Key Digest : Type}
    (readFresh readCached : Image → Key → Option Digest)
    (markFresh markCached : Image → Key → Image)
    (readAgrees : ∀ image key, readCached image key = readFresh image key)
    (markAgrees : ∀ image key, markCached image key = markFresh image key)
    (before after : Image) (key : Key) (expected : Digest) (live queueAccepted : Prop) :
    (live ∧ readCached before key = some expected ∧ queueAccepted ∧
      markCached before key = after) ↔
    (live ∧ readFresh before key = some expected ∧ queueAccepted ∧
      markFresh before key = after) := by
  rw [readAgrees, markAgrees]

#print axioms cached_release_programs_preserve_ordered_effect
#print axioms conditional_range_mark_refines_queue_gate
#print axioms range_marker_rollback_preserves_durable
#print axioms fifo_excludes_arrival_grant_inversion
#print axioms joined_release_progress_preserves_gate
#print axioms prepared_domain_program_preserves_live_decision
#print axioms retained_stamp_selects_live_keys
#print axioms prepared_original_refines_live
#print axioms retained_domain_identity_preserves_mutation_target
#print axioms prepared_review_refines_live
#print axioms currentness_reuse_preserves_decision
#print axioms retained_profile_refines_current
#print axioms prepared_use_refines_current
#print axioms retained_root_revocation_blocks_child
#print axioms retained_epoch_rejects_retired_signer
#print axioms ahead_witness_blocks_unreconciled_use

end WeaverOAuthRefinement
