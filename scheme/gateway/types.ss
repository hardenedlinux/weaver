;;; Gateway configuration operations; actual routing compilation remains in Go.
(import (only-in :clan/poo/object .cc)
        (only-in :clan/poo/mop Function Bool)
        (only-in :clan/poo/type Record List)
        (only-in :yuanxu/object-types/contracts YuanxuContract.)
        (only-in :hardenedlinux/weaver/scheme/governance/types GovernanceScopeContract
                 GovernanceContext GovernorState AgenticAILabGovernanceProfile +loop-governor-type-contract+)
        (only-in :hardenedlinux/weaver/scheme/policy/types PolicyScopeContract)
        "./contracts.ss")
(export GatewayScopeContract GovernanceScopeContract PolicyScopeContract GatewaySourceProducer GatewayProgram)
(def GatewaySourceProducer (Function (list GatewayArtifact) (list GatewayArtifact)))
(def GatewayProgram
  (.cc (Record install: (list (Function (list Bool) (list GatewaySourceProducer)))
               capture: (list (Function (list GatewayArtifact) (list GatewayArtifact)))
               close: (list (Function (list Bool) '())))
       identity: 'weaver/gateway/program sealed: #t))
(def GatewayScopeContract
  (.cc YuanxuContract. value-contract: (Record
         compile: (list (Function (list GatewayArtifact)
                                 (list +loop-governor-type-contract+ AgenticAILabGovernanceProfile
                                       GovernanceContext (List GovernorState)
                                       (List TaskContract) (List ProviderPlanContract) PublicationContract)))
         emit: (list (Function (list Bool) (list GatewayArtifact)))
         capture: (list (Function (list GatewayArtifact) (list (Function (list Bool) '())))))
       identity: 'weaver/gateway/scope))
