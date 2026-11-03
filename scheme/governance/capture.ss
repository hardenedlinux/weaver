;;; SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
;;;
;;; SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

;;; Canonical data capture is independent of caller-owned mutable strings/lists.
;;; It grants neither producer authenticity nor authority over external facts.
(import (only-in :clan/poo/object .o .ref .all-slots)
        (only-in :clan/poo/mop json<- validate)
        (only-in :std/encoding/json json->string JSONWriteOptions)
        (only-in :agentic-ai-lab/modules/governance/types agentic-ai-lab-governance-profile?
                 agentic-ai-lab-governance-source?)
        (only-in :agentic-ai-lab/modules/authorization/providers/cedar/objects agentic-ai-lab-cedar-policy?)
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
  (def policies (.ref profile 'policies))
  (def names (.all-slots policies))
  (def assets (.ref profile 'source-assets))
  (unless (<= (length names) 64) (error "Governance policy inventory bound"))
  (unless (<= (length assets) 64) (error "Governance asset inventory bound"))
  (def policy-values
    (map (lambda (slot-name)
           (let ((value (.ref policies slot-name)))
             (unless (and (agentic-ai-lab-cedar-policy? value) (eq? (.ref value 'runtime-executed?) #f))
               (error "unsupported Governance policy value"))
             (.o name: (symbol->string slot-name) identity: (.ref value 'identity) source: (.ref value 'source))))
         (list-sort (lambda (left right) (string<? (symbol->string left) (symbol->string right))) names)))
  (def asset-values
    (map (lambda (value)
           (unless (agentic-ai-lab-governance-source? value) (error "unsupported Governance source asset"))
           (.o identity: (.ref value 'identity) path: (.ref value 'path) language: (.ref value 'language))) assets))
  (let ((model (.ref profile 'threat-model)))
    (snapshot-json GovernanceProfileSnapshot
      (.o profile_identity: (.ref profile 'identity) profile_revision: (.ref profile 'revision)
          profile_owner: (.ref profile 'owner) model_identity: (.ref model 'identity)
          threats: (map threat-snapshot (.ref model 'threats))
          policies: policy-values source_assets: asset-values))))

(def (governance-context-snapshot context)
  (snapshot-json GovernanceAssessmentContext context))
