;;; Native Governor selection belongs to Scheme's standard test suite.
(import :std/test
        :agentic-ai-lab/modules/loop-engine/control/governor
        :agentic-ai-lab/modules/loop-engine/control/strategy
        :agentic-ai-lab/modules/loop-engine/control/descriptor
        ../scheme/governance/func)
(export governance-test)

(def (governor overrides)
  (make-loop-governor 'weaver
    (make-loop-strategy-plan 'weaver-routing
      (list (make-loop-pattern-descriptor 'infer "Original inference" '((level . l2)))
            (make-loop-pattern-descriptor 'next "Original continuation" '((level . l2)))))
    overrides))

(def governance-test
  (test-suite "Native Governor handoff"
    (test-case "original open patterns are selected"
      (check-equal? (governor-open-nodes
                     (governor '((aggregate-budget . ((max-actionable . 2))))) '())
                    '("infer" "next")))
    (test-case "denylist removes candidates from the final handoff"
      (check-equal? (governor-open-nodes
                     (governor '((shared-denylist . (infer))
                                 (aggregate-budget . ((max-actionable . 2))))) '())
                    '("next")))
    (test-case "an active source snapshot excludes the occupied pattern"
      (check-equal? (governor-open-nodes
                     (governor '((aggregate-budget . ((max-actionable . 2)))))
                     '(((acting_on . infer)))) '("next")))
    (test-case "aggregate clipping applies to the final handoff"
      (check-equal? (length (governor-open-nodes
                             (governor '((aggregate-budget . ((max-actionable . 1))))) '())) 1))))
