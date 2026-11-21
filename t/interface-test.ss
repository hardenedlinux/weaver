;;; SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
;;; SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

(import :std/test
        (only-in :clan/poo/object .o .get)
        (only-in "../scheme/interface.ss" LabGovernance LabSession LabGovernor LabCedar)
        (only-in "../scheme/gateway/provider-source.ss" make-session-turn-selector)
        (only-in "../scheme/gateway/config.ss" GatewayScope gateway-scope)
        (only-in "../scheme/gateway/interface.ss" Gateway)
        (only-in :tao3k/agentic-ai-lab/modules/governance/interface
                 Governance AgenticAILabGovernanceProfile agentic-ai-lab-governance-evaluate)
        (only-in :tao3k/agentic-ai-lab/modules/session/objects-core
                 agentic-ai-lab-session? agentic-ai-lab-session-id agentic-ai-lab-session-lineage)
        (only-in :tao3k/agentic-ai-lab/modules/loop-engine/control/governor make-loop-governor)
        (only-in :tao3k/agentic-ai-lab/modules/authorization/providers/cedar/objects
                 agentic-ai-lab-cedar-policy)
        (prefix-in :clan/poo/testing/property/generator generator.)
        (prefix-in :clan/poo/testing/property property.)
        (only-in :clan/poo/testing/property/test check-property))
(export interface-test)

(def interface-test
  (test-suite "Weaver dependency interface preserves its actual owners"
    (test-case "Gateway Module and factory share the canonical publication"
      (check-equal? (eq? (gateway-scope) GatewayScope) #t)
      (check-equal? (eq? (gateway-scope) (.get Gateway core exports)) #t))
    (test-case "Types, prototypes and procedures retain native identity"
      (check-equal? (eq? (.get LabGovernance Profile) (.get Governance core exports Profile)) #t)
      (check-equal? (eq? (.get LabGovernance profile-type) AgenticAILabGovernanceProfile) #t)
      (check-equal? (eq? (.get LabGovernance evaluate) agentic-ai-lab-governance-evaluate) #t)
      (check-equal? (eq? (.get LabSession lineage) agentic-ai-lab-session-lineage) #t)
      (check-equal? (eq? (.get LabGovernor make) make-loop-governor) #t)
      (check-equal? (eq? (.get LabCedar policy) agentic-ai-lab-cedar-policy) #t))
    (test-case "a descendant override neither replaces its owner nor hides a refusal"
      (def child (.o (:: @ LabGovernance) (evaluate := (lambda (_profile _context) 'local))))
      (check-equal? ((.get child evaluate) #f #f) 'local)
      (check-equal? (eq? (.get child Profile) (.get LabGovernance Profile)) #t)
      (check-equal? (eq? (.get LabGovernance evaluate) agentic-ai-lab-governance-evaluate) #t)
      (check-exception ((.get LabSession lineage) "invalid-id" '() 'root) error?))
    (test-case "an unread selection retains its original scope across owner rebind"
      (def select (make-session-turn-selector))
      (def facts (.o principal: "alice" model: "model-a" output_token_limit: 32
                    message_count: 1 body_bytes: 100))
      (def scope (.o principal: "alice" models: '("model-a") max_output_tokens: 32
                    max_messages: 4 max_body_bytes: 1024 route_count: 3))
      (def key (make-string 64 #\a))
      (def other (make-string 64 #\b))
      (def first (select (.o (scope_commitment := key) (scope := scope) (facts := facts))))
      (select (.o (scope_commitment := other)
                  (scope := (.o (:: @ scope) route_count: 1)) (facts := facts)))
      (check-equal? (.get first scope_commitment) key)
      (check-equal? (.get first route_indices) '(0 1 2)))
    (test-case "mutating a returned selection cannot poison the retained owner"
      (def select (make-session-turn-selector))
      (def facts (.o principal: "alice" model: "model-a" output_token_limit: 32
                    message_count: 1 body_bytes: 100))
      (def scope (.o principal: "alice" models: '("model-a") max_output_tokens: 32
                    max_messages: 4 max_body_bytes: 1024 route_count: 3))
      (def key (make-string 64 #\a))
      (def first (select (.o (scope_commitment := key) (scope := scope) (facts := facts))))
      (string-set! (.get first scope_commitment) 0 #\z)
      (set-car! (.get first route_indices) 7)
      (def again (select (.o (scope_commitment := key) (facts := facts))))
      (check-equal? (.get again scope_commitment) key)
      (check-equal? (.get again route_indices) '(0 1 2)))
    (test-case "generated Session values satisfy the independent Lab predicates"
      (def report
        (property.check-property
          (generator.generator-integer 0 128)
          (lambda (number)
            (def id (string->symbol (string-append "session-" (number->string number))))
            (def session
              ((.get LabSession value) id '()
                ((.get LabSession lineage) id '() 'root)
                ((.get LabSession placement) 'provider)))
            (and (agentic-ai-lab-session? session)
                 (eq? (agentic-ai-lab-session-id session) id)
                 (eq? ((.get LabSession id) session) id)))
          (property.make-specification
            (lambda (number) (and (exact-integer? number) (<= 0 number 128)))
            (lambda (number) number))
          seed: 293 cases: 64 size: 128 shrink-budget: 32))
      (check-property report)
      (check-equal? (property.report-accepted report) 64))))
