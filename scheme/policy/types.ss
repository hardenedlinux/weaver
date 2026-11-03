;;; SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
;;;
;;; SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

;;; This Contract describes an inert Rust preflight, not an authorization grant.
(import (only-in :clan/poo/object .cc)
        (only-in :clan/poo/mop Function Bool)
        (only-in :yuanxu/object-types/contracts YuanxuContract.)
        (only-in :clan/poo/type Record String)
        (only-in "./source-bytes.ss" bounded-cedar-source?))
(import (only-in :clan/poo/type List)
        (only-in :agentic-ai-lab/modules/governance/types AgenticAILabGovernanceProfile))
(export PolicyScopeContract CedarPolicySource CedarSchemaSource PolicyDocument PolicyProjection)
(def CedarPolicySource (.cc String sexp: 'CedarPolicySource '.element? bounded-cedar-source?))
(def CedarSchemaSource (.cc String sexp: 'CedarSchemaSource '.element? bounded-cedar-source?))
(def PolicyDocument
  (.cc (Record identity: (list CedarPolicySource) source: (list CedarPolicySource)
               path: (list String) digest: (list String))
       identity: 'weaver/policy/document sealed: #t))
(def PolicyProjection
  (.cc (Record policy: (list CedarPolicySource) inputs: (list (List PolicyDocument)) root: (list String))
       identity: 'weaver/policy/projection sealed: #t))
(def PolicyScopeContract
  (.cc YuanxuContract. value-contract:
       (Record validate: (list (Function (list Bool) (list CedarPolicySource CedarSchemaSource)))
               project: (list (Function (list PolicyProjection)
                                        (list AgenticAILabGovernanceProfile CedarPolicySource String))))
       identity: 'weaver/policy/scope))
