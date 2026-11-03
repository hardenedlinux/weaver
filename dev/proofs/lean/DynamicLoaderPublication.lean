-- SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
--
-- SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

import GerbilExitQualification
namespace Weaver.DynamicLoaderPublication

-- This AST is the closed recognizer language, not arbitrary Scheme.
inductive Stub where
  | empty
  | require (moduleId : Nat)
  | seq (first rest : Stub)
  deriving DecidableEq

def loads : Stub → List Nat
  | .empty => []
  | .require m => [m]
  | .seq a b => loads a ++ loads b

inductive Image where
  | wrapper (id : Nat)
  | body (id : Nat)
  deriving DecidableEq

def bodyTrace : List Image → List Nat
  | [] => []
  | .wrapper _ :: rest => bodyTrace rest
  | .body m :: rest => m :: bodyTrace rest

def eraseWrappers : List Image → List Image
  | [] => []
  | .wrapper _ :: rest => eraseWrappers rest
  | .body m :: rest => .body m :: eraseWrappers rest

theorem erasure_preserves_body_order (xs : List Image) :
    bodyTrace (eraseWrappers xs) = bodyTrace xs := by
  induction xs with
  | nil => rfl
  | cons x xs ih => cases x <;> simp [eraseWrappers,bodyTrace,ih]

theorem source_dependency_composition (a b : Stub) :
    loads (.seq a b) = loads a ++ loads b := rfl

-- The trusted bridge must be supplied independently by actual runtime evidence.
-- The theorem does not assert correctness of Gambit eval or its compiler.
structure Publication (s : Stub) where
  compiledCalls : List Nat
  sourceCalls : List Nat
  compilerFaithful : compiledCalls = loads s
  interpreterFaithful : sourceCalls = loads s
  interfaceDigest : Nat
  publishedInterfaceDigest : Nat
  interfacesUnchanged : publishedInterfaceDigest = interfaceDigest
  bodySourceDigest : Nat
  publishedBodyDigest : Nat
  bodiesUnchanged : publishedBodyDigest = bodySourceDigest

theorem publication_preserves_calls (p : Publication s) :
    p.sourceCalls = p.compiledCalls := p.interpreterFaithful.trans p.compilerFaithful.symm

theorem publication_preserves_interface_identity (p : Publication s) :
    p.publishedInterfaceDigest = p.interfaceDigest := p.interfacesUnchanged

theorem publication_preserves_body_identity (p : Publication s) :
    p.publishedBodyDigest = p.bodySourceDigest := p.bodiesUnchanged

def acquireOnce (m : Nat) (loaded : List Nat) : List Nat :=
  if m ∈ loaded then loaded else m :: loaded

theorem repeated_import_does_not_duplicate (m : Nat) (loaded : List Nat) :
    acquireOnce m (acquireOnce m loaded) = acquireOnce m loaded := by
  by_cases h : m ∈ loaded <;> simp [acquireOnce,h]

theorem native_completion_still_needs_cleanup
    (pass : GerbilExitQualification.Qualified c receipt) :
    receipt.returned = true ∧ receipt.handles = [] :=
  GerbilExitQualification.qualification_preserves_cleanup pass

theorem dynamic_pass_still_needs_gateway_policy
    (_pass : GerbilExitQualification.Qualified c receipt)
    (event : LlmRouting.Step router owner before after)
    (changed : after.dispatches ≠ before.dispatches) :
    ∃ p, owner.wireValid p ∧ owner.finalPolicyValid p (LlmRouting.view before) :=
  GerbilExitQualification.natural_pass_still_needs_gateway_policy _pass event changed

#print axioms erasure_preserves_body_order
#print axioms source_dependency_composition
#print axioms publication_preserves_calls
#print axioms publication_preserves_interface_identity
#print axioms publication_preserves_body_identity
#print axioms repeated_import_does_not_duplicate
#print axioms native_completion_still_needs_cleanup
#print axioms dynamic_pass_still_needs_gateway_policy
end Weaver.DynamicLoaderPublication
