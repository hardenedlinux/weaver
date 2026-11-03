-- SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
--
-- SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

import Lean
import CedarPooSpec.Gateway.ZeroTrust

/-! Read the imported SPEC environment. This file defines no security model.
The JSON projection is consumed by Go alongside the OpenSysML allocation view.
Pretty-printed types are explanatory data, never executable authorization. -/
open Lean Elab Command Meta

run_cmd do
  let declarations ← liftTermElabM do
    let env ← getEnv
    let names := #[
      ``CedarPooSpec.ZeroTrust.Framework,
      ``CedarPooSpec.ZeroTrust.Framework.required,
      ``CedarPooSpec.Gateway.Context,
      ``CedarPooSpec.Gateway.ProfileObject.Publication,
      ``CedarPooSpec.Gateway.Receipt,
      ``CedarPooSpec.Gateway.ZeroTrust.Host,
      ``CedarPooSpec.Gateway.ZeroTrust.Proposal,
      ``CedarPooSpec.Gateway.ZeroTrust.FinalUse,
      ``CedarPooSpec.Gateway.ZeroTrust.CommittedPrefix,
      ``CedarPooSpec.Gateway.ZeroTrust.continuing,
      ``CedarPooSpec.ZeroTrust.UsageControl,
      ``CedarPooSpec.ZeroTrust.UsageControl.step,
      ``CedarPooSpec.ZeroTrust.UsageControl.close]
    names.mapM fun name => do
      let info ← getConstInfo name
      let fields ← match getStructureInfo? env name with
        | none => pure #[]
        | some layout => layout.fieldNames.mapM fun field => do
          let projection ← getConstInfo (name ++ field)
          let condition ← forallTelescopeReducing projection.type fun _ result => isProp result
          return Json.mkObj [("name", toJson field.toString),
            ("type", toJson (← ppExpr projection.type).pretty),
            ("condition", toJson condition)]
      let mut values := [("name", toJson name.toString),
        ("type", toJson (← ppExpr info.type).pretty), ("fields", Json.arr fields)]
      if let .defnInfo definition := info then
        values := values ++ [("value", toJson (← ppExpr definition.value).pretty)]
      return Json.mkObj values
  logInfo (Json.mkObj [("schema", toJson "weaver.lean.environment.v1"),
    ("declarations", Json.arr declarations)]).compress

#print axioms CedarPooSpec.Gateway.ZeroTrust.final_use_satisfies_framework
#print axioms CedarPooSpec.Gateway.ZeroTrust.zero_trust_final_use
#print axioms CedarPooSpec.Gateway.ZeroTrust.continuing_use_preserves_original_consumption
#print axioms CedarPooSpec.Gateway.ZeroTrust.changed_complete_view_cannot_finalize
#print axioms CedarPooSpec.ZeroTrust.usage_rechecks_after_recovery
