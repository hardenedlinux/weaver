-- SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
--
-- SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

import RoutineRoutingConfig
import LlmAuthoritativeScope

namespace Weaver.SemanticGatewaySlice
abbrev R := LlmRouting.Config
abbrev Source := GatewayHeadCAS.Config
abbrev Registry := LlmAuthoritativeScope.Registry

-- The template is the immutable original task capability/context/region contract.
-- Authentication and its publication under the same commitment remain native duties.
def original (source : Source) (registry : Registry) (key : Nat) (template : R) : R :=
  {template with
    root := key
    payload := source.payload key
    escrow := source.cost key
    catalog := fun g => (template.catalog g).filter (fun m => decide (m ∈ (LlmAuthoritativeScope.contract source registry key).targets))}

structure NodeRule where
  node : Nat
  extraRequirements : List Nat
  targets : List Nat
  ceiling : Nat
  contextFloor : Nat

def normalize (source : Source) (registry : Registry) (key : Nat) (template : R) (rule : NodeRule) : RoutineRoutingConfig.Normal :=
  {root := key, payload := source.payload key, profile := registry.commitment key,
   node := rule.node, response := (LlmAuthoritativeScope.contract source registry key).payload.schema,
   requirements := template.requirements ++ rule.extraRequirements, targets := rule.targets,
   allowance := min (source.cost key) rule.ceiling,
   contextNeeded := max template.contextNeeded rule.contextFloor, region := template.regionNeeded}

def routing (source : Source) (registry : Registry) (key : Nat) (template : R) (rule : NodeRule) : R :=
  RoutineRoutingConfig.lower (original source registry key template) (normalize source registry key template rule)

theorem constructed_refinement :
    RoutineRoutingConfig.Refines (original source registry key template) (registry.commitment key) rule.node
      (LlmAuthoritativeScope.contract source registry key).payload.schema (normalize source registry key template rule) := by
  refine ⟨rfl,rfl,rfl,rfl,rfl,?_,?_,?_,rfl⟩
  · intro r member; exact List.mem_append_left _ member
  · exact Nat.min_le_left _ _
  · exact Nat.le_max_left _ _

theorem original_identity :
    (routing source registry key template rule).root = key ∧
    (routing source registry key template rule).payload = source.payload key := ⟨rfl,rfl⟩

theorem root_reservation_bounds_normal :
    (normalize source registry key template rule).allowance ≤ source.cost key := Nat.min_le_left _ _

theorem extra_requirements_cannot_erase_original (member : c ∈ template.requirements) :
    c ∈ (normalize source registry key template rule).requirements := List.mem_append_left _ member

theorem original_context_is_preserved : template.contextNeeded ≤ (normalize source registry key template rule).contextNeeded :=
  Nat.le_max_left _ _

theorem eligible_preserves_original
    (eligible : LlmRouting.Eligible (routing source registry key template rule) s m) :
    LlmRouting.Eligible (original source registry key template) s m :=
  RoutineRoutingConfig.eligible_is_narrowed constructed_refinement eligible

theorem selected_target_has_original_contract_membership
    (eligible : LlmRouting.Eligible (routing source registry key template rule) s m) :
    m ∈ (LlmAuthoritativeScope.contract source registry key).targets := by
  have originalMember := (eligible_preserves_original eligible).1
  have joined : m ∈ template.catalog s.catalog ∧ m ∈ (LlmAuthoritativeScope.contract source registry key).targets := by
    simpa [original,List.mem_filter] using originalMember
  exact joined.2

theorem selected_cost_fits_original_reservation
    (eligible : LlmRouting.Eligible (routing source registry key template rule) s m) :
    template.costBound s.catalog m ≤ source.cost key :=
  (eligible_preserves_original eligible).2.2.2.2.2.2.1

theorem no_catalog_or_target_union
    (eligible : LlmRouting.Eligible (routing source registry key template rule) s m) :
    m ∈ template.catalog s.catalog ∧ m ∈ rule.targets := by
  have parent := (eligible_preserves_original eligible).1
  have joined : m ∈ template.catalog s.catalog ∧ m ∈ (LlmAuthoritativeScope.contract source registry key).targets := by
    simpa [original,List.mem_filter] using parent
  exact ⟨joined.1,RoutineRoutingConfig.selected_target_is_declared eligible⟩

theorem normalization_binds_registered_record :
    (normalize source registry key template rule).profile = (LlmAuthoritativeScope.recordFor source registry key h).commitment ∧
    (normalize source registry key template rule).payload = (LlmAuthoritativeScope.recordFor source registry key h).payload ∧
    (normalize source registry key template rule).response = (LlmAuthoritativeScope.recordFor source registry key h).semantics.schema :=
  ⟨rfl,rfl,rfl⟩

theorem actual_dispatch_preserves_constructed_parent
    (event : LlmRouting.Step (routing source registry key template rule) owner s t)
    (changed : t.dispatches ≠ s.dispatches) :
    ∃ p, LlmRouting.Bound (original source registry key template) p ∧
      LlmRouting.Eligible (original source registry key template) s p.target ∧
      p.view = LlmRouting.view s ∧ owner.wireValid p ∧ owner.finalPolicyValid p (LlmRouting.view s) :=
  RoutineRoutingConfig.final_dispatch_rechecks_parent constructed_refinement event changed

theorem current_scope_and_normal_share_contract
    (current : LlmAuthoritativeScope.Current source registry (routing source registry key template rule) rootOwner s ticket record h) :
    ticket.scope.semantics = LlmAuthoritativeScope.semantics source registry key ∧
    (normalize source registry key template rule).profile = record.commitment ∧
    (normalize source registry key template rule).response = ticket.scope.semantics.schema := by
  have scope := current.2.2.2.2.1
  have recordEq := current.1.2.2.2.2
  have sem : ticket.scope.semantics = LlmAuthoritativeScope.semantics source registry key := by
    simpa [LlmAuthoritativeScope.scopeFor,routing,original,RoutineRoutingConfig.lower] using congrArg LlmSemanticContract.Scope.semantics scope
  refine ⟨sem,?_,?_⟩
  · rw [recordEq]; rfl
  · rw [sem]; rfl

theorem actual_uses_share_registered_contract
    (run : LlmAuthoritativeScope.Run source registry (routing source registry key template rule) profile rootOwner childOwner codec owner LlmAuthoritativeScope.initial s)
    (member : u ∈ s.uses) :
    u.ticket.scope = LlmAuthoritativeScope.scopeFor source registry key u.ticket.child ∧
    (normalize source registry key template rule).profile = u.record.commitment ∧
    (normalize source registry key template rule).response = u.ticket.scope.semantics.schema := by
  have bound := LlmAuthoritativeScope.initialized_audit run u member
  have scope := bound.2.1
  have recordEq := bound.2.2.2
  refine ⟨scope,?_,?_⟩
  · rw [recordEq]; rfl
  · rw [scope]; rfl

theorem actual_source_reservation_covers_selected_cost
    (bridge : LlmRouting.AdmissionBridge (routing source registry key template rule) source policy) :
    template.costBound bridge.before.catalog bridge.selected.target ≤ source.cost bridge.admission.key :=
  LlmRouting.selected_route_fits_source_reservation bridge

theorem actual_source_claim_not_recreated
    (bridge : LlmRouting.AdmissionBridge (routing source registry key template rule) source policy) :
    (bridge.admission.after.base.messages bridge.admission.key).claims ≤ 1 ∧
    (bridge.admission.after.base.messages bridge.admission.key).sends ≤ 1 :=
  LlmRouting.original_claim_is_not_recreated bridge

theorem inherited_account_capacity
    (bridge : LlmRouting.AdmissionBridge (routing source registry key template rule) source policy) (account) :
    FiniteDomainMigration.booked source bridge.admission.after.base account ≤ source.capacity account :=
  LlmRouting.original_account_capacity_survives bridge account

theorem missing_registry_fails_closed
    (unknown : registry.resolve (registry.commitment key) = none) :
    ¬ LlmRouting.Eligible (routing source registry key template rule) s m := by
  intro eligible
  have member := selected_target_has_original_contract_membership eligible
  simp [LlmAuthoritativeScope.contract,unknown,LlmAuthoritativeScope.emptyContract] at member

theorem forged_profile_is_not_normalized (forged : RoutineRoutingConfig.Normal) (wrong : forged.profile ≠ registry.commitment key) :
    forged ≠ normalize source registry key template rule := by
  intro same
  apply wrong
  exact congrArg RoutineRoutingConfig.Normal.profile same

theorem inflated_normal_is_not_refinement (rule : NodeRule) (forged : RoutineRoutingConfig.Normal) (excess : source.cost key < forged.allowance) :
    ¬ RoutineRoutingConfig.Refines (original source registry key template) (registry.commitment key) rule.node
      (LlmAuthoritativeScope.contract source registry key).payload.schema forged :=
  RoutineRoutingConfig.enlarged_allowance_rejected excess

#print axioms missing_registry_fails_closed
#print axioms forged_profile_is_not_normalized
#print axioms inflated_normal_is_not_refinement
#print axioms constructed_refinement
#print axioms original_identity
#print axioms root_reservation_bounds_normal
#print axioms extra_requirements_cannot_erase_original
#print axioms original_context_is_preserved
#print axioms eligible_preserves_original
#print axioms selected_target_has_original_contract_membership
#print axioms selected_cost_fits_original_reservation
#print axioms no_catalog_or_target_union
#print axioms normalization_binds_registered_record
#print axioms actual_dispatch_preserves_constructed_parent
#print axioms current_scope_and_normal_share_contract
#print axioms actual_uses_share_registered_contract
#print axioms actual_source_reservation_covers_selected_cost
#print axioms actual_source_claim_not_recreated
#print axioms inherited_account_capacity
end Weaver.SemanticGatewaySlice
