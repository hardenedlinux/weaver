;;; SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
;;; SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

;;; Inert dependencies for Weaver's roles; never import Weaver init here.
(import (only-in :clan/poo/object .o)
        (only-in :tao3k/agentic-ai-lab/modules/governance/types
                 AgenticAILabGovernanceProfile
                 agentic-ai-lab-governance-profile? agentic-ai-lab-governance-assessment?
                 agentic-ai-lab-governance-source?)
        (only-in :tao3k/agentic-ai-lab/modules/governance/objects
                 AgenticAILabGovernanceProfile. agentic-ai-lab-governance-source
                 agentic-ai-lab-governance-threat-blocking?)
        (only-in :tao3k/agentic-ai-lab/modules/governance/funs agentic-ai-lab-governance-evaluate)
        (only-in :tao3k/agentic-ai-lab/modules/session/objects-core
                 agentic-ai-lab-session-value agentic-ai-lab-session?
                 agentic-ai-lab-session-lineage agentic-ai-lab-session-placement
                 agentic-ai-lab-session-id)
        (only-in :tao3k/agentic-ai-lab/modules/loop-engine/control/governor
                 make-loop-governor loop-governor->contract +loop-governor-type-contract+)
        (only-in :tao3k/agentic-ai-lab/modules/loop-engine/control/strategy make-loop-strategy-plan)
        (only-in :tao3k/agentic-ai-lab/modules/loop-engine/control/descriptor make-loop-pattern-descriptor)
        (only-in :tao3k/agentic-ai-lab/modules/authorization/providers/cedar/objects
                 agentic-ai-lab-cedar-policy agentic-ai-lab-cedar-policy?))
(export LabGovernance LabSession LabGovernor LabCedar)

(def LabGovernance
  (.o (Profile := AgenticAILabGovernanceProfile.)
      (evaluate := agentic-ai-lab-governance-evaluate)
      (profile-type := AgenticAILabGovernanceProfile)
      (profile? := agentic-ai-lab-governance-profile?)
      (assessment? := agentic-ai-lab-governance-assessment?)
      (source := agentic-ai-lab-governance-source)
      (source? := agentic-ai-lab-governance-source?)
      (threat-blocking? := agentic-ai-lab-governance-threat-blocking?)))

(def LabSession
  (.o (value := agentic-ai-lab-session-value)
      (session? := agentic-ai-lab-session?)
      (lineage := agentic-ai-lab-session-lineage)
      (placement := agentic-ai-lab-session-placement)
      (id := agentic-ai-lab-session-id)))

(def LabGovernor
  (.o (make := make-loop-governor)
      (contract := loop-governor->contract)
      (type := +loop-governor-type-contract+)
      (strategy := make-loop-strategy-plan)
      (pattern := make-loop-pattern-descriptor)))

(def LabCedar
  (.o (policy := agentic-ai-lab-cedar-policy)
      (policy? := agentic-ai-lab-cedar-policy?)))
