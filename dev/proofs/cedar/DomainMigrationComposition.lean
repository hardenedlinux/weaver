-- SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
--
-- SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

import CedarPooSpec.Gateway.ZeroTrust
import GatewayHeadCAS
import SharedDomains

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
end Weaver.DomainMigrationComposition
