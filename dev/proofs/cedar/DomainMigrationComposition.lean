-- SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
--
-- SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

import ProviderSnapshotPublication
import ProviderSemanticProgress
import CedarPooSpec.Gateway.ZeroTrust
import GatewayHeadCAS
import SharedDomains
import PublicationRecovery
import ProviderEgressWindow

/-! Strengthen the existing SPEC final-use framework with the existing finite
domain execution model on the SAME deciding view. No duplicate state machine,
authorization evaluator, caller-selected image or implementation refinement. -/
namespace Weaver.DomainMigrationComposition
open Cedar.Spec CedarPooSpec
open Weaver.FiniteDomainMigration

def reachableDomain (c : Config) : ZeroTrust.Requirement E GatewayHeadCAS.State :=
  fun _ actual => Reachable c actual.base

variable {E S : Type} [BEq E] [LawfulBEq E] {project : E → S → Request}
  {original : Gateway.Profile} {object : Gateway.ProfileObject.Object}
  {publication : Gateway.ProfileObject.Publication original object}
  {prepared : Gateway.Prepared E S project} {model : PolicyModules.Model}
  {effect : E} {state : S} {actualContext : Gateway.Context}
  {checks : List Gateway.Assessment} {entities : Entities}
  {host : Gateway.ZeroTrust.Host E GatewayHeadCAS.State}
  {proposal : Gateway.ZeroTrust.Proposal host publication prepared model effect state actualContext checks entities}

theorem gateway_final_use_preserves_domain_contract
    (use : Gateway.ZeroTrust.FinalUse proposal)
    (events : GatewayHeadCAS.Run c owner GatewayHeadCAS.initial use.actual) :
    (Gateway.ZeroTrust.specialize proposal (reachableDomain c)).required effect use.actual ∧
    (∀ account, booked c use.actual.base account ≤ c.capacity account) ∧
    (∀ key, (use.actual.base.messages key).claims ≤ 1 ∧ (use.actual.base.messages key).sends ≤ 1) ∧
    original.Refines prepared.profile := by
  have reachable := GatewayHeadCAS.initialized_product_refines_semantics events
  have core := Gateway.ZeroTrust.final_use_satisfies_framework proposal use
  have strengthened : (Gateway.ZeroTrust.specialize proposal (reachableDomain c)).required effect use.actual :=
    ⟨core.1, ⟨core.2.1, reachable⟩, core.2.2⟩
  exact ⟨strengthened, fun account => finite_budget_bound reachable account,
    fun key => per_message_affinity reachable key,
    (Gateway.ZeroTrust.specialization_preserves_core_and_original proposal strengthened).2⟩

/-- Compose the acknowledged receiver certificate with SPEC's existing final-use
contract on exactly the same view. Equality is the Host projection obligation;
this theorem does not assume arbitrary SQL or an unmediated writer is verified. -/
theorem acknowledged_delivery_preserves_same_actual_view
    (use : Gateway.ZeroTrust.FinalUse proposal)
    (events : GatewayHeadCAS.Run c owner GatewayHeadCAS.initial use.actual)
    (delivered : GatewayHeadCAS.State) (same : delivered = use.actual)
    (receipt : Weaver.ProviderEgressWindow.DeliveryJoin.Receipt)
    (revision incarnation pending orphaned : Nat) (failed : Bool)
    (current : Weaver.ProviderEgressWindow.DeliveryJoin.Current receipt revision incarnation pending orphaned failed) :
    Weaver.ProviderEgressWindow.DeliveryJoin.Current receipt revision incarnation pending orphaned failed ∧
    (Gateway.ZeroTrust.specialize proposal (reachableDomain c)).required effect delivered ∧
    (∀ account, booked c delivered.base account ≤ c.capacity account) ∧
    (∀ key, (delivered.base.messages key).claims ≤ 1 ∧ (delivered.base.messages key).sends ≤ 1) ∧
    original.Refines prepared.profile := by
  refine ⟨current, ?_⟩
  simpa only [same] using gateway_final_use_preserves_domain_contract use events

#print axioms acknowledged_delivery_preserves_same_actual_view

/-- Reuse the pinned SPEC final-use theorem under the exact projection preserved
    by any finite sequence of the two progress-only SQL transitions. The host
    still proves that its concrete SQL read set matches Image. No new axiom. -/
theorem range_progress_preserves_spec_final_use
    (use : Gateway.ZeroTrust.FinalUse proposal)
    (events : GatewayHeadCAS.Run c owner GatewayHeadCAS.initial use.actual)
    (before after : Weaver.ProviderSemanticProgress.Store)
    (projection : Weaver.ProviderSemanticProgress.Image → GatewayHeadCAS.State)
    (joined : projection before.image = use.actual)
    (steps : Weaver.ProviderSemanticProgress.Steps before after) :
    (Gateway.ZeroTrust.specialize proposal (reachableDomain c)).required effect (projection after.image) ∧
    (∀ account, booked c (projection after.image).base account ≤ c.capacity account) ∧
    (∀ key, ((projection after.image).base.messages key).claims ≤ 1 ∧
      ((projection after.image).base.messages key).sends ≤ 1) ∧
    original.Refines prepared.profile := by
  have same : projection after.image = use.actual := by
    rw [Weaver.ProviderSemanticProgress.finite_progress_preserves_image steps]
    exact joined
  simpa only [same] using gateway_final_use_preserves_domain_contract use events

#print axioms range_progress_preserves_spec_final_use

/-- Each manifest member joins the qualified snapshot with the actual cut.
    SPEC final use and finite shared-domain obligations remain the semantic
    dependency; the host supplies the exact cut-to-actual-view projection. -/
theorem published_snapshot_preserves_spec_final_use
    (use : Gateway.ZeroTrust.FinalUse proposal)
    (events : GatewayHeadCAS.Run c owner GatewayHeadCAS.initial use.actual)
    (snapshot : Weaver.ProviderSnapshotPublication.Snapshot)
    (gate : Weaver.ProviderSnapshotPublication.Gate)
    (row : Weaver.ProviderSnapshotPublication.Range)
    (acknowledged unexpired : Prop)
    (current : Weaver.ProviderSnapshotPublication.Ready snapshot gate row acknowledged unexpired)
    (projection : Nat → GatewayHeadCAS.State)
    (qualified : ∀ member ∈ snapshot.manifest, projection snapshot.cut = use.actual) :
    (Gateway.ZeroTrust.specialize proposal (reachableDomain c)).required effect (projection gate.cut) ∧
    (∀ account, booked c (projection gate.cut).base account ≤ c.capacity account) ∧
    (∀ key, ((projection gate.cut).base.messages key).claims ≤ 1 ∧
      ((projection gate.cut).base.messages key).sends ≤ 1) ∧
    original.Refines prepared.profile := by
  have joined : projection gate.cut = use.actual :=
    Weaver.ProviderSnapshotPublication.final_use_joins_snapshot snapshot gate row acknowledged unexpired
      (fun cut _ => projection cut = use.actual) qualified current
  simpa only [joined] using gateway_final_use_preserves_domain_contract use events

#print axioms published_snapshot_preserves_spec_final_use

theorem head_cas_preserves_original_obligations
    (step : GatewayHeadCAS.Step c owner before after)
    (claimed : (before.base.messages key).claimed = true)
    (history : (before.base.messages key).history = true) :
    (after.base.messages key).claimed = true ∧
    (after.base.messages key).claimToken = (before.base.messages key).claimToken ∧
    (after.base.messages key).claimStream = (before.base.messages key).claimStream ∧
    (after.base.messages key).history = true ∧
    after.base.claimOwner key = before.base.claimOwner key := by
  obtain ⟨claim, token, stream, retained⟩ := GatewayHeadCAS.original_claim_and_history_survive step claimed history
  exact ⟨claim, token, stream, retained, GatewayHeadCAS.original_executor_survives step claimed⟩

theorem overbooked_actual_view_cannot_supply_final_run
    (overbooked : c.capacity account < booked c actual.base account) :
    ¬ GatewayHeadCAS.Run c owner GatewayHeadCAS.initial actual := by
  intro events
  have bounded := GatewayHeadCAS.shared_budget_is_bounded events account
  omega

#print axioms overbooked_actual_view_cannot_supply_final_run
#print axioms gateway_final_use_preserves_domain_contract
#print axioms head_cas_preserves_original_obligations

/-- A committed whole-domain union is interpreted on the exact SPEC actual view.
The projection equality and admission inequality are Host refinement obligations,
not an assertion that arbitrary SQL or configuration replacement is verified. -/
theorem final_use_on_committed_union
    (use : Gateway.ZeroTrust.FinalUse proposal)
    (events : GatewayHeadCAS.Run c owner GatewayHeadCAS.initial use.actual)
    (domain : GatewayHeadCAS.State → SharedDomains.Domain)
    (left right : SharedDomains.Domain)
    (same : domain use.actual = SharedDomains.union left right)
    (admitted : SharedDomains.total left.claims + SharedDomains.total right.claims ≤
      min left.cap right.cap) :
    (Gateway.ZeroTrust.specialize proposal (reachableDomain c)).required effect use.actual ∧
    SharedDomains.Safe (domain use.actual) ∧
    SharedDomains.total (domain use.actual).claims =
      SharedDomains.total left.claims + SharedDomains.total right.claims ∧
    (∀ entry, entry ∈ left.history ∨ entry ∈ right.history →
      entry ∈ (domain use.actual).history) ∧
    ((domain use.actual).epoch ≠ left.epoch ∧ (domain use.actual).epoch ≠ right.epoch) ∧
    original.Refines prepared.profile := by
  obtain ⟨framework, _, _, refinement⟩ := gateway_final_use_preserves_domain_contract use events
  obtain ⟨capacity, retained⟩ := SharedDomains.admitted_union_conserves_capacity left right admitted
  refine ⟨framework, ?_, ?_, ?_, ?_, refinement⟩
  · simpa only [same] using capacity
  · simpa only [same] using retained
  · intro entry original
    simpa only [same] using SharedDomains.union_retains_history left right entry original
  · simpa only [same] using SharedDomains.union_fences_both_old_permits left right

#print axioms final_use_on_committed_union

/-- On the same actual view, neither pre-union epoch can qualify the use.
Recovery of an old result does not change the supplied actual projection. -/
theorem pre_union_epoch_cannot_match_actual
    (use : Gateway.ZeroTrust.FinalUse proposal)
    (domain : GatewayHeadCAS.State → SharedDomains.Domain)
    (left right : SharedDomains.Domain)
    (same : domain use.actual = SharedDomains.union left right)
    {permitEpoch : Nat}
    (old : permitEpoch = left.epoch ∨ permitEpoch = right.epoch) :
    (domain use.actual).epoch ≠ permitEpoch := by
  obtain ⟨fromLeft, fromRight⟩ := SharedDomains.union_fences_both_old_permits left right
  rcases old with old | old
  · simpa only [same, old] using fromLeft
  · simpa only [same, old] using fromRight

#print axioms pre_union_epoch_cannot_match_actual

/-- An exact old view cannot be reused after a changed authority version.
A projected committed union also rejects either old domain epoch. -/
theorem stale_parent_or_epoch_cannot_match
    (use : Gateway.ZeroTrust.FinalUse proposal)
    (before : GatewayHeadCAS.State) (head : GatewayHeadCAS.Head)
    (domain : GatewayHeadCAS.State → SharedDomains.Domain)
    (left right : SharedDomains.Domain)
    (changed : before.version ≠ use.actual.version ∨
      domain use.actual = SharedDomains.union left right)
    (old : permitEpoch = left.epoch ∨ permitEpoch = right.epoch) :
    ¬ (GatewayHeadCAS.view before head = GatewayHeadCAS.view use.actual head ∧
      (domain use.actual).epoch = permitEpoch) := by
  rintro ⟨sameView, sameEpoch⟩
  rcases changed with version | union
  · exact version (congrArg GatewayHeadCAS.View.version sameView)
  · exact pre_union_epoch_cannot_match_actual use domain left right union old sameEpoch

#print axioms stale_parent_or_epoch_cannot_match

/-- Staging preserves an unresolved barrier on the actual publication image.
The transport guard must require readiness of that same image. -/
theorem staged_policy_excludes_actual_effect {Key : Type} [DecidableEq Key]
    (prior : PublicationRecovery.State Key) (id : Key) (q : Nat × Nat × Nat)
    (actual : PublicationRecovery.State Key)
    (bound : actual = {prior with pending := PublicationRecovery.write prior.pending id q})
    (effectRequiresReady : allowed → PublicationRecovery.Ready actual) :
    ¬ allowed := by
  subst actual
  intro effect
  exact PublicationRecovery.staged_intent_blocks_effect_readiness (s := prior) id q
    (effectRequiresReady effect)

#print axioms staged_policy_excludes_actual_effect

end Weaver.DomainMigrationComposition
