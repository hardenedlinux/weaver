-- SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
--
-- SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

import CedarPooSpec.Gateway.AuthorizationDelta
import Lean

/-! Reuse the pinned SPEC proof terms. Replace only closed compiler arithmetic
obligations with kernel proofs, and kernel-check every rebuilt declaration.
No upstream cache patch, new axiom, solver premise or policy law is introduced. -/
open Lean Elab Command Meta Term
namespace Weaver.SpecProofClosure
structure RecheckState where
  memo : Std.HashMap Name Name := {}
  count : Nat := 0
  arithmetic : Nat := 0
abbrev RecheckM := StateRefT RecheckState TermElabM

def isCompilerOracle (name : Name) : Bool := decide ((name.toString.splitOn "native_decide").length > 1)
/-- Build a closed proof with the standard kernel decision procedure. -/
def proveClosedArithmetic (type : Expr) : TermElabM Expr := do
  let value ← elabTermEnsuringType (← `(by decide)) type
  synthesizeSyntheticMVarsNoPostponing
  let value ← instantiateMVars value
  if value.hasMVar || value.hasSorry then throwError "Arithmetic proof is incomplete"
  return value

partial def repair (expression : Expr) : RecheckM Expr := do
  Core.transform expression (pre := fun e => do
    let .const name levels := e | return .continue
    if let some checked := (← get).memo[name]? then return .done (.const checked levels)
    let axioms ← Lean.collectAxioms name
    if !axioms.any isCompilerOracle then
      modify fun s => {s with memo := s.memo.insert name name}
      return .continue
    let info ← getConstInfo name
    let index := (← get).count
    let target := Name.mkStr `Weaver.SpecProofClosure s!"checked_{index}"
    modify fun s => {s with count := s.count+1, memo := s.memo.insert name target}
    if info.isAxiom then
      unless isCompilerOracle name do throwError "Unapproved axiom {name}"
      let value ← proveClosedArithmetic info.type
      addDecl (.thmDecl {name := target,levelParams := info.levelParams,type := info.type,value})
      modify fun s => {s with arithmetic := s.arithmetic+1}
      logInfo m!"ARITHMETIC {name} → {target}"
    else
      let some value := info.value? (allowOpaque := true) | throwError "No proof body: {name}"
      let type ← repair info.type
      let value ← repair value
      addDecl (.thmDecl {name := target,levelParams := info.levelParams,type,value})
    return .done (.const target levels))

run_cmd do
  let (value, state) ← liftTermElabM do
    (repair (.const ``CedarPooSpec.Gateway.bound_admitted_execution_preserves_delta [])).run {}
  unless state.arithmetic == 9 do throwError "Unexpected SPEC arithmetic dependency closure"
  logInfo m!"RECHECKED {state.count} declarations, {state.arithmetic} arithmetic obligations"
  let info ← getConstInfo ``CedarPooSpec.Gateway.bound_admitted_execution_preserves_delta
  liftCoreM <| addDecl (.thmDecl {name := `Weaver.SpecProofClosure.bound_admitted_execution_preserves_delta,levelParams := info.levelParams,type := info.type,value})
#print axioms Weaver.SpecProofClosure.bound_admitted_execution_preserves_delta
end Weaver.SpecProofClosure
