;;; SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
;;;
;;; SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

(import (only-in :yuanxu/module-system/source/declaration .def))
(.def Governance
  identity: 'governance
  tags: '(governance)
  core: (.o requires: (.o) scope-contract: GovernanceScopeContract exports: Governance.)
  features: (.o))
