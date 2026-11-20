;;; SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
;;;
;;; SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

(import (only-in "../governance/objects.ss" Governance.)
        (only-in "../policy/objects.ss" Policy.))
(.def Gateway
  identity: 'gateway
  tags: '(gateway)
  core:
  (.o scope-contract: GatewayScopeContract
      exports:
      (.o (:: @ Gateway.)
          compile: (lambda args (apply compile-gateway Governance. Policy. args))
          prepare: (lambda args (apply prepare-gateway Governance. Policy. args))))
  features: (.o))
