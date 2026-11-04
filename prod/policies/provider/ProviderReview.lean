-- SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
--
-- SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

import CedarPooSpec.Gateway.AuthorizationDelta
import CedarPooSpec.SchemaJson
import CedarPooSpec.PolicyJson

/-! Deployment qualification, executed by the Go development owner. No request
can provide a solver verdict or a replacement policy AST. This module uses the
actual pinned SPEC exact error-free execution analyzer for every schema world.
Its solver result is not a kernel UNSAT certificate. -/
namespace Weaver.ReviewQualification
open Cedar.Spec Cedar.Validation Cedar.Data CedarPooSpec.PolicyModules

def principalType : EntityType := ⟨"Principal", ["Weaver"]⟩
def targetType : EntityType := ⟨"Target", ["Weaver"]⟩
def actionType : EntityType := ⟨"Action", ["Weaver"]⟩
def requiredStrings := ["family", "node", "profile", "model", "profile_digest", "protocol",
  "endpoint", "body_digest", "plan_digest", "format"]
def requiredInts := ["output_token_limit", "message_count", "ceiling", "revision", "fence", "sequence"]
def optionalStrings := ["origin", "budget_domain", "history_domain", "task_key"]
def optionalInts := ["budget_epoch", "history_epoch", "shared_held", "shared_limit", "history_count"]
def context : RecordType := Map.make (
  requiredStrings.map (fun name => (name, Qualified.required CedarType.string)) ++
  requiredInts.map (fun name => (name, Qualified.required CedarType.int)) ++
  optionalStrings.map (fun name => (name, Qualified.optional CedarType.string)) ++
  optionalInts.map (fun name => (name, Qualified.optional CedarType.int)))
def schema : Schema :=
  ⟨Map.make [(principalType, .standard ⟨Set.empty, Map.empty, none⟩),
    (targetType, .standard ⟨Set.empty, Map.empty, none⟩)],
   Map.make (["admitProvider", "invokeProvider", "emitProvider"].map fun name =>
    (EntityUID.mk actionType name, ⟨Set.make [principalType], Set.make [targetType], Set.empty, context⟩))⟩
def allow : Policy := ⟨"policy0", .permit, .principalScope .any,
  .actionScope .any, .resourceScope .any, []⟩
def veto : Policy := { allow with id := "policy1", effect := .forbid }
def deniedTarget : Policy := { allow with
  id := "policy2"
  effect := .forbid
  resourceScope := .resourceScope (.eq ⟨targetType, "denied"⟩) }
def model : Model := ⟨[
  ⟨"Active", [], false, [.extend allow, .extend deniedTarget]⟩,
  ⟨"Revoked", [["Active"]], false, [.extend veto]⟩], none⟩
def scope : CedarPooSpec.Gateway.Scope :=
  ⟨"gateway", "original", "provider", "gateway", "shared", "shared",
    "provider-schema", "deployment", "review-modules", "gateway-projection"⟩

def entry (name before after expected : String) (epoch : Nat) : IO Lean.Json := do
  let .ok plan := CedarPooSpec.Gateway.prepareDelta model before after schema scope scope
    | throw (IO.userError "SPEC preparation refused")
  let .ok report ← plan.analyze | throw (IO.userError "SPEC exact Delta analysis refused")
  if report.classification != expected || !plan.matchesCurrent model scope then
    throw (IO.userError "SPEC qualification control or current model failed")
  if report.environmentsChecked != schema.environments.length || report.environmentsChecked == 0 then
    throw (IO.userError "incomplete SPEC environment coverage")
  let .ok beforeJson := CedarPooSpec.PolicyJson.policySet plan.revision.beforePolicies
    | throw (IO.userError "SPEC predecessor export refused")
  let .ok afterJson := CedarPooSpec.PolicyJson.policySet plan.revision.afterPolicies
    | throw (IO.userError "SPEC candidate export refused")
  let .ok schemaJson := CedarPooSpec.SchemaJson.schema schema
    | throw (IO.userError "SPEC schema export refused")
  return Lean.Json.mkObj [
    ("name", Lean.toJson name), ("before_policy", Lean.toJson beforeJson.compress),
    ("after_policy", Lean.toJson afterJson.compress), ("schema", Lean.toJson schemaJson.compress),
    ("epoch", Lean.toJson epoch), ("environments", Lean.toJson report.environmentsChecked),
    ("gains", Lean.toJson report.gains.length), ("losses", Lean.toJson report.losses.length),
    ("classification", Lean.toJson report.classification)]

def run : IO Lean.Json := do
  let bootstrap ← entry "bootstrap" "Active" "Active" "equivalent-in-schema" 0
  let activate ← entry "activate" "Active" "Active" "equivalent-in-schema" 1
  let revoke ← entry "revoke" "Active" "Revoked" "loss-only" 2
  let expansion ← entry "expansion-refused" "Revoked" "Active" "gain-only" 3
  return Lean.Json.mkObj [("engine", Lean.toJson "cedar-poo-spec.exact-error-free-allow"),
    ("qualification", Lean.toJson "solver-checked"),
    ("entries", Lean.toJson [bootstrap, activate, revoke, expansion])]
end Weaver.ReviewQualification
