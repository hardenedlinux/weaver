;;; Native POO scope Contract for inert governance semantics.
(import (only-in :clan/poo/object .cc)
        (only-in :clan/poo/mop Function Bool)
        (only-in :clan/poo/type Record List String Symbol Pair Or Enum)
        (only-in :agentic-ai-lab/modules/governance/types AgenticAILabGovernanceProfile)
        (only-in :agentic-ai-lab/modules/loop-engine/control/governor +loop-governor-type-contract+))
(export GovernanceScopeContract GovernanceContext GovernorState ActionKey
        AgenticAILabGovernanceProfile +loop-governor-type-contract+)
(def GovernanceContext
  (.cc (Record request: (list (Enum publish)))
       identity: 'weaver/governance/context sealed: #t))
(def ActionKey (Or Symbol String (Enum #f)))
(def GovernorState (List (Pair Symbol ActionKey)))
(def GovernanceScopeContract
  (.cc (Record
         assess: (list (Function (list Bool) (list AgenticAILabGovernanceProfile GovernanceContext)))
         open: (list (Function (list (List String))
                              (list +loop-governor-type-contract+ (List GovernorState)))))
       identity: 'weaver/governance/scope))
