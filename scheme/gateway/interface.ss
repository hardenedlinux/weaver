(.def Gateway
  identity: 'gateway
  core:
  (.o requires:
      (.o Governance: (.o module-id: 'governance contract: GovernanceScopeContract)
          Policy: (.o module-id: 'policy contract: PolicyScopeContract))
      scope-contract: GatewayScopeContract
      exports:
      (.o (:: @ Gateway.)
          compile: (lambda args (apply compile-gateway Governance Policy args))))
  features: (.o))
