;;; Native POO scope Contract for inert governance semantics.
(import (only-in :clan/poo/object .cc)
        (only-in :clan/poo/mop Function Bool)
        (only-in :clan/poo/type Record List String Symbol Pair Or Enum)
        (only-in :yuanxu/object-types/contracts YuanxuContract.)
        (only-in :agentic-ai-lab/modules/governance/types AgenticAILabGovernanceProfile)
        (only-in :agentic-ai-lab/modules/loop-engine/control/governor +loop-governor-type-contract+))
(export GovernanceScopeContract GovernanceContext GovernanceAssessmentContext GovernorState ActionKey
        AgenticAILabGovernanceProfile +loop-governor-type-contract+ GovernanceProfileSnapshot)
(def GovernanceContext
  (.cc (Record request: (list (Enum publish)) source_root: (list String optional: #t))
       identity: 'weaver/governance/context sealed: #t))
(def GovernanceSource
  (.cc String sexp: 'GovernanceSource
       '.element? (lambda (value)
                    (and (string? value)
                         (< 0 (u8vector-length (string->utf8 value)) 8388609)))))
;;; The gateway supplies the exact typed source projection, never a caller scope.
(def GovernanceAssessmentContext
  (.cc (Record request: (list (Enum publish)) source: (list GovernanceSource)
               policy_inputs: (list GovernanceSource)
               profile_identity: (list String) profile_revision: (list String)
               profile_owner: (list String) model_identity: (list String))
       identity: 'weaver/governance/assessment-context sealed: #t))
(def OptionalEvidence (Or String (Enum #f)))
(def PreconditionSnapshot
  (.cc (Record identity: (list String) observed: (list Bool) evidence: (list OptionalEvidence))
       identity: 'weaver/governance/precondition-snapshot sealed: #t))
(def ThreatSnapshot
  (.cc (Record identity: (list String) severity: (list (Enum low moderate high critical))
               phase: (list (Enum latent exposed realized mitigated accepted))
               preconditions: (list (List PreconditionSnapshot)) mitigations: (list (List String))
               acceptance_authority: (list OptionalEvidence))
       identity: 'weaver/governance/threat-snapshot sealed: #t))
(def PolicySourceSnapshot
  (.cc (Record name: (list String) identity: (list String) source: (list GovernanceSource))
       identity: 'weaver/governance/policy-source-snapshot sealed: #t))
(def SourceAssetSnapshot
  (.cc (Record identity: (list String) path: (list String) language: (list Symbol))
       identity: 'weaver/governance/source-asset-snapshot sealed: #t))
(def GovernanceProfileSnapshot
  (.cc (Record profile_identity: (list String) profile_revision: (list String)
               profile_owner: (list String) model_identity: (list String)
               threats: (list (List ThreatSnapshot)) policies: (list (List PolicySourceSnapshot))
               source_assets: (list (List SourceAssetSnapshot)))
       identity: 'weaver/governance/profile-snapshot sealed: #t))
(def ActionKey (Or Symbol String (Enum #f)))
(def GovernorState (List (Pair Symbol ActionKey)))
(def GovernanceScopeContract
  (.cc YuanxuContract. value-contract: (Record
         assess: (list (Function (list Bool) (list AgenticAILabGovernanceProfile GovernanceAssessmentContext)))
         open: (list (Function (list (List String))
                              (list +loop-governor-type-contract+ (List GovernorState)))))
       identity: 'weaver/governance/scope))
