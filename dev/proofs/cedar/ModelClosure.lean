-- SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
--
-- SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

import Lean
import DomainMigrationComposition
import QualifiedReview
import DynamicLoaderPublication
import FencedIntentContinuation
import GambitLocatorClosure
import LlmSubjectAuthority
import ProviderRpc
import PublicationRecovery
import RuntimeAdmission
import SharedDomains
import StreamingExecution

open Lean Elab Command
run_cmd do
  let env ← getEnv
  logInfo m!"WEAVER_MODEL_MODULES {Json.compress (toJson (env.header.moduleNames.toList.map Name.toString))}"
  let mut checked : Nat := 0
  for (name, info) in env.constants.toList do
    if name.toString.startsWith "Weaver." && info.isTheorem then
      let axioms ← Lean.collectAxioms name
      let values := String.intercalate ", " (axioms.toList.map Name.toString)
      logInfo m!"'{name}' depends on axioms: [{values}]"
      checked := checked + 1
  unless checked > 0 do throwError "Empty model proof closure"
  logInfo m!"WEAVER_MODEL_THEOREMS {checked}"
