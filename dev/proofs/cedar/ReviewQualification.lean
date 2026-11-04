-- SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
--
-- SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0


import ProviderReview

def main : IO Unit := do
  let catalog ← Weaver.ReviewQualification.run
  IO.println catalog.compress
