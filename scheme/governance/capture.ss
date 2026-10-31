;;; Canonical data capture is independent of caller-owned mutable strings/lists.
;;; It grants neither producer authenticity nor authority over external facts.
(import (only-in :clan/poo/object .o .ref .all-slots)
        (only-in :clan/poo/mop json<- validate)
        (only-in :std/encoding/json json->string JSONWriteOptions)
        (only-in :agentic-ai-lab/modules/governance/types agentic-ai-lab-governance-profile?)
        "./types.ss")
(export governance-profile-snapshot governance-context-snapshot)

(def (snapshot-json descriptor value)
  (let ((text (json->string (json<- descriptor (validate descriptor value))
                          (JSONWriteOptions sort-keys: #t))))
    (unless (< 0 (u8vector-length (string->utf8 text)) 8388609)
      (error "Governance snapshot exceeds source bound"))
    text))

(def (precondition-snapshot value)
  (.o identity: (.ref value 'identity) observed: (.ref value 'observed?)
      evidence: (.ref value 'evidence)))

(def (threat-snapshot value)
  (.o identity: (.ref value 'identity) severity: (.ref value 'severity) phase: (.ref value 'phase)
      preconditions: (map precondition-snapshot (.ref value 'preconditions))
      mitigations: (.ref value 'mitigations)
      acceptance_authority: (.ref value 'acceptance-authority)))

(def (governance-profile-snapshot profile)
  (unless (and (agentic-ai-lab-governance-profile? profile)
               (null? (.all-slots (.ref profile 'ontology))))
    (error "unsupported or invalid Governance source Profile obligations"))
  (let ((model (.ref profile 'threat-model)))
    (snapshot-json GovernanceProfileSnapshot
      (.o profile_identity: (.ref profile 'identity) profile_revision: (.ref profile 'revision)
          profile_owner: (.ref profile 'owner) model_identity: (.ref model 'identity)
          threats: (map threat-snapshot (.ref model 'threats))))))

(def (governance-context-snapshot context)
  (snapshot-json GovernanceAssessmentContext context))
