;;; Native Governor selection belongs to Scheme's standard test suite.
(import :std/test
        (only-in :std/error Error?)
        :agentic-ai-lab/modules/loop-engine/control/governor
        :agentic-ai-lab/modules/loop-engine/control/strategy
        :agentic-ai-lab/modules/loop-engine/control/descriptor
        :agentic-ai-lab/modules/governance/interface
        (only-in :clan/poo/object .o .get)
        (only-in ../scheme/governance/objects Governance.)
        (only-in ../scheme/governance/func governor-open-nodes))
(export governance-test)
(def (assess-governance! profile context) ((.get Governance. assess) profile context))

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
                             (governor '((aggregate-budget . ((max-actionable . 1))))) '())) 1))
    (test-case "a ready assessment is bound to its exact source context"
      (def context (.o request: 'publish source: "{\"original\":true}"
                      profile_identity: "weaver/test" profile_revision: "1" profile_owner: "operator"
                      model_identity: "agentic-ai-lab/governance/threat-model/empty"))
      (def profile
        (.o (:: @ AgenticAILabGovernanceProfile.)
            identity: "weaver/test" revision: "1" owner: "operator"))
      (check (assess-governance! profile context) => #t)
      (check-exception (assess-governance! profile (.o request: 'publish)) Error?))
    (test-case "a typed ready assessment cannot omit an original blocking threat"
      (def context (.o request: 'publish source: "{\"original\":true}"
                      profile_identity: "weaver/test" profile_revision: "1" profile_owner: "operator"
                      model_identity: "weaver/blocking"))
      (def model
        (agentic-ai-lab-governance-threat-model "weaver/blocking"
          (list (agentic-ai-lab-governance-threat "weaver/exposed" 'critical 'realized
                  (list (agentic-ai-lab-governance-precondition "weaver/input" #t "evidence:input"))))))
      (def profile
        (.o (:: @ AgenticAILabGovernanceProfile.)
            identity: "weaver/test" revision: "1" owner: "operator"
            threat-model: model
            .assess-governance:
            (lambda (current)
              (agentic-ai-lab-governance-assessment-value profile model '() current))))
      (check-exception (assess-governance! profile context) Error?))))
