;;; SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
;;;
;;; SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

;;; Data-only advisory derivation. No field is an execution capability.
(import (only-in :clan/poo/object .cc)
        (only-in :clan/poo/mop Function Bool)
        (only-in :clan/poo/type Record List String Enum)
        "./contracts.ss")
(export GatewayDependency GatewayDerivationRequest GatewayDerivationResult
        GatewayDerivation GatewayPreparation)

(def GatewayDependency
  (.cc (Record dependent: (list Identifier) dependency: (list Identifier))
       identity: 'weaver/gateway/dependency sealed: #t))
(def GatewayDerivationRequest
  (.cc (Record source: (list GatewayArtifact)
               dependencies: (list (List GatewayDependency)) changed: (list (List Identifier)))
       identity: 'weaver/gateway/derivation-request sealed: #t))
(def DeclaredCandidate
  (.cc (Record node: (list Identifier) target: (list Identifier) model: (list String))
       identity: 'weaver/gateway/declared-candidate sealed: #t))
(def OfferExplanation
  (.cc (Record node: (list Identifier) target: (list Identifier) model: (list String)
               declared_node: (list Bool) declared_target: (list Bool) declared_model: (list Bool))
       identity: 'weaver/gateway/offer-explanation sealed: #t))
(def GatewayDerivationResult
  (.cc (Record source_digest: (list Digest) request_digest: (list Digest)
               family: (list Identifier) generation: (list Counter)
               rule_profile: (list String) limit_profile: (list String)
               complete: (list (Enum #t)) execution_authorized: (list (Enum #f))
               candidates: (list (List DeclaredCandidate)) explanations: (list (List OfferExplanation))
               affected: (list (List Identifier)) affected_nodes: (list (List Identifier)))
       identity: 'weaver/gateway/advisory-result sealed: #t))
(def GatewayDerivation
  (.cc (Record derive: (list (Function (list GatewayDerivationResult) (list GatewayDerivationRequest)))
               matches?: (list (Function (list Bool) (list GatewayDerivationRequest GatewayDerivationResult)))
               invalidate: (list (Function (list Bool) '())) close: (list (Function (list Bool) '())))
       identity: 'weaver/gateway/derivation sealed: #t))
(def GatewayPreparation
  (.cc (Record source: (list GatewayArtifact) derivation: (list GatewayDerivationResult))
       identity: 'weaver/gateway/preparation sealed: #t))
