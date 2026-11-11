;;; SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
;;;
;;; SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

(import (only-in :yuanxu/module-system/source/declaration .def))
(.def Policy
  identity: 'policy
  tags: '(policy)
  core: (.o requires: (.o) scope-contract: PolicyScopeContract exports: Policy.
            projections: (list Build))
  features: (.o))
