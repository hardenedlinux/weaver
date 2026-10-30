;;; Gateway configuration operations; actual routing compilation remains in Go.
(import (only-in :clan/poo/object .cc)
        (only-in :clan/poo/mop Function Bool)
        (only-in :clan/poo/type Record List)
        (only-in :hardenedlinux/weaver/scheme/governance/types GovernanceScopeContract
                 GovernanceContext GovernorState AgenticAILabGovernanceProfile +loop-governor-type-contract+)
        (only-in :hardenedlinux/weaver/scheme/policy/types PolicyScopeContract)
        "./contracts.ss")
(export GatewayScopeContract GovernanceScopeContract PolicyScopeContract)
(def GatewayScopeContract
  (.cc (Record
         compile: (list (Function (list GatewayArtifact)
                                 (list +loop-governor-type-contract+ AgenticAILabGovernanceProfile
                                       GovernanceContext (List GovernorState)
                                       (List TaskContract) (List ProviderPlanContract) PublicationContract)))
         emit: (list (Function (list Bool) (list GatewayArtifact))))
       identity: 'weaver/gateway/scope))
