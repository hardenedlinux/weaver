;;; SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
;;;
;;; SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

(import (only-in "./types.ss" GovernanceScopeContract)
        (only-in "./objects.ss" Governance.))
(export Governance)
(.def Governance
  identity: 'governance
  tags: '(governance)
  core: (.o scope-contract: GovernanceScopeContract exports: Governance.)
  features: (.o))
