;;; This Contract describes an inert Rust preflight, not an authorization grant.
(import (only-in :clan/poo/object .cc)
        (only-in :clan/poo/mop Function Bool)
        (only-in :clan/poo/type Record String))
(export PolicyScopeContract CedarPolicySource CedarSchemaSource)
(def (bounded-cedar-source? value)
  (and (string? value) (< 0 (u8vector-length (string->utf8 value)) 65537)))
(def CedarPolicySource (.cc String sexp: 'CedarPolicySource '.element? bounded-cedar-source?))
(def CedarSchemaSource (.cc String sexp: 'CedarSchemaSource '.element? bounded-cedar-source?))
(def PolicyScopeContract
  (.cc (Record validate: (list (Function (list Bool) (list CedarPolicySource CedarSchemaSource))))
       identity: 'weaver/policy/scope))
