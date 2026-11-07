;;; SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
;;;
;;; SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

(import (only-in :yuanxu/module-system/source/declaration .def))
(.def Gateway
  identity: 'gateway
  tags: '(gateway)
  core:
  (.o requires:
      (.o Governance: (.o module-id: 'governance contract: GovernanceScopeContract)
          Policy: (.o module-id: 'policy contract: PolicyScopeContract))
      scope-contract: GatewayScopeContract
      exports:
      (.o (:: @ Gateway.)
          compile: (lambda args (apply compile-gateway Governance Policy args))
          prepare: (lambda args (apply prepare-gateway Governance Policy args)))
      projections: (list Build))
  features: (.o))
