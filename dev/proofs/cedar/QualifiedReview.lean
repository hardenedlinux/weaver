-- SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
--
-- SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

import SpecProofClosure
import PublicationRecovery

/-! Deployment qualification refines the existing publication owner. Catalogue
membership is an authenticated Host premise. ExactCoverage remains an explicit
query/UNSAT premise: executable CVC5 output is not a kernel certificate. -/
namespace Weaver.QualifiedReview
open CedarPooSpec.Gateway Weaver.PublicationRecovery

structure Selection where
  catalog : Nat
  entry : Nat
  parent : Nat
  plan : DeltaPlan

def Bound (trusted : Nat) (catalog : Nat → Option DeltaPlan)
    (parent : Nat) (selection : Selection) : Prop :=
  selection.catalog = trusted ∧ catalog selection.entry = some selection.plan ∧
  selection.parent = parent

theorem changed_parent_cannot_reuse_qualification
    (changed : selection.parent ≠ parent) : ¬ Bound trusted catalog parent selection := by
  intro bound; exact changed bound.2.2

theorem changed_deployment_cannot_self_qualify
    (changed : selection.catalog ≠ trusted) : ¬ Bound trusted catalog parent selection := by
  intro bound; exact changed bound.1

/-- Composition reuses SPEC's actual error-free execution theorem and the
existing arbitrary-key recovery induction. Native code must refine both guards
at final use; this statement does not derive UNSAT from a signed report. -/
theorem qualified_execution_and_recovery_preserve_original
    {Key E S : Type} [DecidableEq Key]
    {s t : State Key} {held calls : Nat}
    {projection : E → S → Cedar.Spec.Request} {prepared : Prepared E S projection}
    {model : CedarPooSpec.PolicyModules.Model} {effect : E} {state : S}
    {context : Context} {checks : List Assessment} {entities : Cedar.Spec.Entities}
    (selection : Selection) (trusted : Nat) (catalog : Nat → Option DeltaPlan)
    (selected : Bound trusted catalog s.head selection)
    (run : Run s t) (safe : Safe held calls s)
    (receipt : Receipt prepared model effect state context checks entities)
    (binding : AdmissionBinding receipt selection.plan)
    (coverage : ExactCoverage selection.plan.schema
      selection.plan.revision.beforePolicies selection.plan.revision.afterPolicies)
    (envWellFormed : (Cedar.Spec.Env.mk (projection effect state) entities).StronglyWellFormed)
    (beforeWellFormed : (Cedar.Spec.Env.mk (projection effect state) entities).StronglyWellFormedForPolicies
      selection.plan.revision.beforePolicies)
    (afterWellFormed : (Cedar.Spec.Env.mk (projection effect state) entities).StronglyWellFormedForPolicies
      selection.plan.revision.afterPolicies) :
    selection.parent = s.head ∧ PreservesIntents s t ∧ Extends s t ∧ Safe held calls t ∧
      CedarPooSpec.Authorization.Delta.errorFreeAllow selection.plan.revision.beforePolicies
        (Cedar.Spec.Env.mk (projection effect state) entities) = true :=
  ⟨selected.2.2, run_preserves_original_intents run,
    run_preserves_original_decisions run, run_preserves_accounting safe run,
    Weaver.SpecProofClosure.bound_admitted_execution_preserves_delta receipt selection.plan binding coverage
      envWellFormed beforeWellFormed afterWellFormed⟩

#print axioms changed_parent_cannot_reuse_qualification
#print axioms changed_deployment_cannot_self_qualify
#print axioms qualified_execution_and_recovery_preserve_original
end Weaver.QualifiedReview
