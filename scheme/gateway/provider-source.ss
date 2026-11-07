;;; SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
;;;
;;; SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

;;; Weaver's declared provider workflows and Governor strategy.
(import :agentic-ai-lab/modules/loop-engine/control/strategy
        :agentic-ai-lab/modules/loop-engine/control/descriptor
        (only-in :agentic-ai-lab/modules/session/objects-core agentic-ai-lab-session-value
                 agentic-ai-lab-session-lineage agentic-ai-lab-session-placement)
        (only-in :yuanxu/modules/funflow/control-plane/flow flow-compose external-flow flow-steps flow-then flow-branch flow-output-contract Fun String PairValue)
        (only-in :clan/poo/object .o))
(export workflow-session nested-workflow-session provider-source-strategy provider-source-budget)

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
