;;; Scheme owns source contract assertions; Go only schedules this standard suite.
(import :std/test
        (only-in :clan/poo/object .o .get)
        (only-in :clan/poo/mop validate json<- TypeError?)
        (only-in :std/encoding/json json->string)
        ../scheme/gateway/contracts
        ../scheme/governance/types)
(export gateway-contracts-test)

(def gateway-contracts-test
  (test-suite "Gateway source contracts"
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
