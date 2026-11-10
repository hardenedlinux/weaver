;;; SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
;;;
;;; SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

;;; Weaver's declared provider workflows and Governor strategy.
(import :agentic-ai-lab/modules/loop-engine/control/strategy
        :agentic-ai-lab/modules/loop-engine/control/descriptor
        (only-in :agentic-ai-lab/modules/session/objects-core agentic-ai-lab-session-value
                 agentic-ai-lab-session-lineage agentic-ai-lab-session-placement)
        (only-in :yuanxu/modules/funflow/control-plane/flow flow-compose external-flow flow-steps flow-then flow-branch flow-output-contract Fun String PairValue)
        (only-in :clan/poo/object .o .get .ref object<-alist)
        (only-in :clan/poo/mop validate)
        (only-in :gerbil-ascent/program/scheme-language relational-program)
        (only-in :gerbil-ascent/program/session gerbil-ascent-open-session gerbil-ascent-session-run)
        (only-in "./snapshot.ss" copy-source-data)
        (only-in :agentic-ai-lab/modules/loop-engine/control/governor make-loop-governor)
        (only-in "./func.ss" compose-governor-selection)
        "./contracts.ss")
(export workflow-session nested-workflow-session provider-source-strategy provider-source-budget compose-provider-configuration provider-source-controls)

(def (workflow-session dag? choice?)
  (def signature (Fun String <- String))
  (def (step node (type signature))
    (external-flow node 'weaver-provider-response #f type))
  (def routine
    (if dag?
      (flow-then 'control
        (flow-then 'fork (step 'infer) (flow-branch 'branches (step 'next) (step 'side)))
        (step 'finish (Fun String <- (PairValue String String))))
      (flow-compose 'control
        (apply append (map (lambda (node) (flow-steps (step node))) '(infer next finish)))
        signature)))
  (.o (:: @ (agentic-ai-lab-session-value 'control '()
              (agentic-ai-lab-session-lineage 'control '() 'root)
              (agentic-ai-lab-session-placement 'provider)))
      workflow: routine workflow-choice: choice?))

(def (nested-workflow-session)
  (def (provider node (input String))
    (external-flow node 'weaver-provider-response #f (Fun String <- input)))
  (def (then-provider name preceding node)
    (flow-then name preceding (provider node (flow-output-contract preceding))))
  (def parallel
    (flow-then 'parallel-arm (provider 'side)
      (flow-branch 'parallel (provider 'fork-a) (provider 'fork-b))))
  (def inner
    (then-provider 'inner-join
      (flow-then 'inner-start (provider 'gate)
        (flow-branch 'inner (provider 'next) parallel))
      'inner-finish))
  (def routine
    (then-provider 'control
      (flow-then 'outer-start (provider 'infer)
        (flow-branch 'outer inner (provider 'outer-skip)))
      'finish))
  (.o (:: @ (agentic-ai-lab-session-value 'control '()
              (agentic-ai-lab-session-lineage 'control '() 'root)
              (agentic-ai-lab-session-placement 'provider)))
      workflow: routine workflow-choices: '(outer inner)))

(def (provider-source-strategy nested? dag? session?)
    (make-loop-strategy-plan 'weaver-routing
      (append (list (make-loop-pattern-descriptor 'infer "Original inference" '((level . l2)))
                    (make-loop-pattern-descriptor 'next "Original continuation" '((level . l2))))
              (if nested?
                (map (lambda (name) (make-loop-pattern-descriptor name "Nested provider step" '((level . l2))))
                  '(gate fork-a fork-b inner-finish outer-skip))
                '())
              (if dag? (list (make-loop-pattern-descriptor 'side "Parallel continuation" '((level . l2)))) '())
              (if session?
                (list (make-loop-pattern-descriptor 'finish "Original final inference" '((level . l2))))
                '()))))

(def (provider-source-budget nested? dag? session?)
  (cond (nested? '((aggregate-budget . ((max-actionable . 9) (max-attempts . 1)))))
        (dag? '((aggregate-budget . ((max-actionable . 4) (max-attempts . 1)))))
        (session? '((aggregate-budget . ((max-actionable . 3) (max-attempts . 1)))))
        (else '((aggregate-budget . ((max-actionable . 2) (max-attempts . 1)))))))

(def (provider-source-controls schema)
  (def nested? (equal? schema "weaver.session-nested.v1"))
  (def choice? (equal? schema "weaver.session-choice.v1"))
  (def dag? (or nested? choice? (equal? schema "weaver.session-dag.v1")))
  (def session? (or dag? (equal? schema "weaver.session-workflow.v1")))
  (unless (or session? (equal? schema "agentic-ai-lab.loop-governor.v1"))
    (error "unsupported Weaver provider workflow"))
  (list (make-loop-governor 'weaver (provider-source-strategy nested? dag? session?)
            (provider-source-budget nested? dag? session?))
        (if session?
          (.o request: 'publish session: (if nested? (nested-workflow-session) (workflow-session dag? choice?)))
          (.o request: 'publish))))

;;; Startup composition precedes sealing the original; no authority crosses here.
;;; Rust supplies canonical commitments and independently checked request facts.
(def (compose-provider-configuration input)
  (def configuration (validate ProviderComposition (copy-source-data input)))
  (def original (.get configuration source))
  (def routing (.get configuration routing))
  (unless (and (= (length (.get original tasks)) 1) (null? (.get original plans))
               (<= 1 (length routing) 64))
    (error "Routing requires one unmaterialized original task"))
  (def task (car (.get original tasks)))
  (def bodies '())
  (def chosen-nodes '())
  (def streams '())
  (def selected-plans '())
  (def (charge rates tokens)
    (unless (and (= (length rates) 4) (= (length tokens) 4)
                 (andmap (lambda (n) (and (exact-integer? n) (<= 0 n 9223372036854775807)))
                         (append rates tokens)))
      (error "Routing token/rate bound"))
    (let (amount (quotient (+ (apply + (map * rates tokens)) 999999) 1000000))
      (and (<= amount 9223372036854775807) amount)))
  (for-each
    (lambda (selection)
      (def node (.get selection node))
      (def candidates (list->vector (.get selection candidates)))
      (unless (and (member node (.get task nodes)) (not (member node chosen-nodes))
                   (< 0 (.get selection max_latency_ms)) (<= (vector-length candidates) 8))
        (error "Routing node or candidate bound"))
      (def offers '())
      (def allowed '())
      (def capable '())
      (for-each
        (lambda (id)
          (def candidate (vector-ref candidates id))
          (def plan (.get candidate plan))
          (def price (charge (.get candidate procurement_rates) (.get candidate token_bounds)))
          (def debit (charge (.get selection user_token_rates) (.get candidate token_bounds)))
          (when (and (equal? (.get plan family) (.get task family))
                     (equal? (.get plan node) node) price debit
                     (< 0 (.get candidate latency_ms))
                     (<= (.get candidate latency_ms) (.get selection max_latency_ms))
                     (<= price (.get selection max_procurement_cost))
                     (<= debit (.get plan ceiling)))
            (set! offers (cons (list id price (.get candidate latency_ms)) offers)))
          (when (member (.get candidate module) (.get selection allowed_modules))
            (set! allowed (cons (list id) allowed)))
          (when (andmap (lambda (capability) (member capability (.get candidate capabilities)))
                        (.get selection required))
            (set! capable (cons (list id) capable))))
        (iota (vector-length candidates)))
      (def program
        (relational-program
          (relation offer (id price latency) offers)
          (relation allowed (id) allowed)
          (relation capable (id) capable)
          (relation eligible (id price latency) '())
          (rule (eligible ?id ?price ?latency) (offer ?id ?price ?latency)
                (allowed ?id) (capable ?id))
          (limits 24 8 32)))
      (def result (gerbil-ascent-session-run (gerbil-ascent-open-session program)))
      (unless (eq? (.ref result 'finished) #t) (error "Routing derivation incomplete"))
      (def eligible ((.ref result 'rows-of) 'eligible))
      (when (null? eligible) (error "No eligible model candidate"))
      (def (before? a b)
        (or (< (cadr a) (cadr b))
            (and (= (cadr a) (cadr b))
                 (or (< (caddr a) (caddr b))
                     (and (= (caddr a) (caddr b))
                          (string<? (.get (vector-ref candidates (car a)) digest)
                                    (.get (vector-ref candidates (car b)) digest)))))))
      (def chosen (vector-ref candidates (caar (list-sort before? eligible))))
      (set! selected-plans (cons (.get chosen plan) selected-plans))
      (set! chosen-nodes (cons node chosen-nodes))
      (set! bodies (cons (cons (string->symbol node) (.get chosen body_digest)) bodies))
      (set! streams (cons (cons (string->symbol node) (.get chosen digest)) streams))) routing)
  (def schema (.get (.get original governance) schema))
  (def topology
    (if (equal? schema "agentic-ai-lab.loop-governor.v1")
      (.get original governance)
      (let (controls (provider-source-controls schema))
        (compose-governor-selection (car controls) (cadr controls) '() (.get task family)))))
  (validate GatewayArtifact
    (copy-source-data
      (.o (:: @ original) governance: topology
          tasks: (list (.o (:: @ task) body_digests: (object<-alist bodies)
                            stream_contracts: (object<-alist streams)))
          plans: (reverse selected-plans)))))
