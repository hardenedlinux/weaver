;;; SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
;;;
;;; SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

;;; Exact POO records for the shared wire contract. Go and Rust revalidate it.
(import (only-in :clan/poo/object .cc)
        (only-in :clan/poo/mop MonomorphicObject)
        (only-in :clan/poo/type Record List String)
        (only-in :clan/poo/number UIntN)
        (only-in :hardenedlinux/weaver/scheme/policy/types CedarPolicySource CedarSchemaSource))
(export GatewayArtifact GatewaySourceInput TaskContract ProviderPlanContract PublicationContract
        ProviderProfileContract ProviderRouteContract Identifier Counter Credits)

;;; Preserve exact JSON integer tokens above 2^53; the default Integer JSON
;;; encoder intentionally uses strings there, which this wire schema forbids.
(def Counter (.cc (UIntN 63) sexp: 'GatewayCounter '.json<- identity))
(def Credits (.cc Counter sexp: 'BudgetCredits
                 '.element? (lambda (value) (and (exact-integer? value) (< 0 value (expt 2 63))))))
(def (bounded-string-type name bound)
  (.cc String sexp: name '.element?
       (lambda (value) (and (string? value) (< 0 (u8vector-length (string->utf8 value)) (+ bound 1))))))
(def Identifier
  (.cc String sexp: 'GatewayIdentifier '.element?
       (lambda (value)
         (and (string? value) (< 0 (string-length value) 129)
              (andmap (lambda (character)
                        (or (char<=? #\a character #\z) (char<=? #\A character #\Z)
                            (char<=? #\0 character #\9) (memv character '(#\. #\_ #\: #\-))))
                      (string->list value))))))
(def ModelName (bounded-string-type 'ProviderModelName 128))
(def Endpoint (bounded-string-type 'ProviderEndpoint 2048))
(def RequestBody (bounded-string-type 'ProviderRequestBody 1048576))
(def Digest
  (.cc String sexp: 'CommitmentDigest '.element?
       (lambda (value)
         (and (string? value) (= (string-length value) 64)
              (andmap (lambda (character)
                        (or (char<=? #\a character #\f) (char<=? #\0 character #\9)))
                      (string->list value))))))
(def TokenLimit (.cc Counter sexp: 'OutputTokenLimit '.element?
                    (lambda (value) (and (exact-integer? value) (<= 1 value 4096)))))
(def MessageLimit (.cc Counter sexp: 'MessageLimit '.element?
                      (lambda (value) (and (exact-integer? value) (<= 1 value 64)))))
(def BodyLimit (.cc Counter sexp: 'BodyByteLimit '.element?
                   (lambda (value) (and (exact-integer? value) (<= 1 value 1048576)))))
(def ProviderProtocol
  (.cc String sexp: 'OpenAIChatTextSseV1 '.element?
       (lambda (value) (equal? value "openai.chat-text-sse.v1"))))
(def ProviderProfileContract
  (.cc (Record id: (list Identifier) protocol: (list ProviderProtocol)
               max_output_tokens: (list TokenLimit) max_messages: (list MessageLimit)
               max_body_bytes: (list BodyLimit)) identity: 'weaver/provider-profile sealed: #t))
(def ProviderRouteContract
  (.cc (Record target: (list Identifier) endpoint: (list Endpoint))
       identity: 'weaver/provider-route sealed: #t))
(def ProviderPlanContract
  (.cc (Record family: (list Identifier) node: (list Identifier) profile: (list Identifier)
               profile_commitment: (list Digest) model: (list ModelName) body: (list RequestBody)
               routes: (list (List ProviderRouteContract)) ceiling: (list Credits)
               revision: (list Counter) fence: (list Counter))
       identity: 'weaver/provider-plan sealed: #t))
(def TaskContract
  (.cc (Record provider_profile: (list ProviderProfileContract)
               family: (list Identifier) principal: (list Identifier) profile: (list Identifier)
               nodes: (list (List Identifier)) targets: (list (List Identifier))
               endpoints: (list (MonomorphicObject Endpoint))
               body_digests: (list (MonomorphicObject Digest))
               node_cost_bounds: (list (MonomorphicObject Credits))
               stream_contracts: (list (MonomorphicObject Digest))
               models: (list (List ModelName)) budget: (list Credits))
       identity: 'weaver/task sealed: #t))
(def PublicationContract
  (.cc (Record operation_id: (list Identifier) expected_revision: (list Counter optional: #t)
               fence: (list Counter) policy: (list CedarPolicySource) schema: (list CedarSchemaSource))
       identity: 'weaver/publication sealed: #t))
;;; Private preparation shape before Governor selection; no handoff or authority.
(def GatewaySourceInput
  (.cc (Record tasks: (list (List TaskContract)) plans: (list (List ProviderPlanContract))
               publication: (list PublicationContract))
       identity: 'weaver/gateway/source-input sealed: #t))
(def GovernorHandoff
  (.cc (Record schema: (list String) family: (list Identifier)
               open_nodes: (list (List Identifier))) identity: 'weaver/governor-handoff sealed: #t))
(def GatewayArtifact
  (.cc (Record governance: (list GovernorHandoff) tasks: (list (List TaskContract))
               plans: (list (List ProviderPlanContract)) publication: (list PublicationContract))
       identity: 'weaver/gateway-artifact sealed: #t))
