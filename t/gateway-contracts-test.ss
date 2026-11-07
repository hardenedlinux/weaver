;;; SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
;;;
;;; SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

;;; Scheme owns source contract assertions; Go only schedules this standard suite.
(import :std/test
        (only-in :clan/poo/object .o .get .cc)
        (only-in :clan/poo/mop validate json<- TypeError? element?)
        (only-in :yuanxu/module-system/source/publication ModulePublicationContract)
        (only-in ../scheme/gateway/types GatewayScopeContract)
        (only-in ../scheme/policy/types PolicyScopeContract)
        (only-in :std/encoding/json json->string)
        ../scheme/gateway/contracts
        ../scheme/governance/types)
(export gateway-contracts-test)

(def gateway-contracts-test
  (test-suite "Gateway source contracts"
    (test-case "module scopes use native POO Types and refuse evidence protocol hooks"
      (def (publication scope-type)
        (.o identity: 'gateway-contract-fixture features: (.o)
            core: (.o requires: (.o) scope-contract: scope-type link: void)))
      (for-each
        (lambda (scope-type)
          (check-equal? (element? ModulePublicationContract (publication scope-type)) #t)
          (for-each
            (lambda (hook)
              (check-equal?
                (element? ModulePublicationContract (publication (.cc scope-type hook void))) #f))
            '(.classify .obligations .admit)))
        (list GovernanceScopeContract PolicyScopeContract GatewayScopeContract))
      (check-exception (validate GovernanceScopeContract (.o assess: #f)) TypeError?)
      (check-exception (validate PolicyScopeContract (.o validate: #t project: void)) TypeError?)
      (check-exception (validate GatewayScopeContract (.o compile: void)) TypeError?))
    (test-case "credits preserve exact JSON numbers above the JavaScript integer range"
      (check-equal? (validate Credits 9007199254740993) 9007199254740993)
      (check-equal? (json->string (json<- Credits 9007199254740993)) "9007199254740993")
      (check-equal? (validate Counter 9223372036854775807) 9223372036854775807))
    (test-case "credit values reject strings, nonpositive amounts and overflow"
      (check-exception (validate Credits "8") TypeError?)
      (check-exception (validate Credits 0) TypeError?)
      (check-exception (validate Credits -1) TypeError?)
      (check-exception (validate Credits 9223372036854775808) TypeError?))
    (test-case "counters reject fractions and Booleans"
      (check-exception (validate Counter 0.5) TypeError?)
      (check-exception (validate Counter #f) TypeError?))
    (test-case "governance requests use the declared publication symbol"
      (check-equal? (.get (validate GovernanceContext (.o request: 'publish)) request) 'publish)
      (check-exception (validate GovernanceContext (.o request: "publish")) TypeError?)
      (check-exception (validate GovernanceContext (.o request: 'execute)) TypeError?))
    (test-case "route records reject undeclared fields and invalid identifiers"
      (def route (.o target: "primary" endpoint: "https://provider.example/v1/chat/completions"))
      (check-equal? (.get (validate ProviderRouteContract route) target) "primary")
      (check-exception (validate ProviderRouteContract (.o (:: @ route) unchecked: #t)) TypeError?)
      (check-exception (validate ProviderRouteContract (.o (:: @ route) target: 42)) TypeError?))))
