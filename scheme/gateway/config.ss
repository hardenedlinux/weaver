;;; SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
;;;
;;; SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

;;; The same typed publication is consumed by the Module and compiled ABI.
(import (only-in :clan/poo/object .o)
        (only-in :clan/poo/type validate)
        (only-in "./types.ss" GatewayScopeContract)
        (only-in "./objects.ss" Gateway.)
        (only-in "./func.ss" compile-gateway prepare-gateway)
        (only-in "../governance/objects.ss" Governance.)
        (only-in "../policy/objects.ss" Policy.))
(export GatewayScope gateway-scope)
(def GatewayOperations
  (.o (:: @ Gateway.)
        compile: (lambda args (apply compile-gateway Governance. Policy. args))
        prepare: (lambda args (apply prepare-gateway Governance. Policy. args))))
(def GatewayScope
  (validate GatewayScopeContract
    (if (and (getenv "CARGO_FEATURE_SCHEME_PROGRAM" #f)
             (or (getenv "CARGO_FEATURE_SCHEME_QUALIFICATION" #f)
                 (equal? (getenv "WEAVER_GOVERNANCE_APPLICATION" "")
                         "hardenedlinux/weaver/scheme/gateway/provider-program")))
      (.o (:: @ GatewayOperations)
          program-entry:
          (if (getenv "CARGO_FEATURE_SCHEME_QUALIFICATION" #f)
            'hardenedlinux/weaver/scheme/gateway/qualification-program
            'hardenedlinux/weaver/scheme/gateway/provider-program)
          program-runtime-imports: '())
      GatewayOperations)))
(def (gateway-scope) GatewayScope)
