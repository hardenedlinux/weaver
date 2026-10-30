;;; Native source fixture for cross-language integration; no Go governance DSL.
(import :agentic-ai-lab/modules/loop-engine/control/governor
        :agentic-ai-lab/modules/loop-engine/control/strategy
        :agentic-ai-lab/modules/loop-engine/control/descriptor
        :agentic-ai-lab/modules/governance/interface
        (only-in :clan/poo/object .o)
        ../../scheme/gateway/func)
(export emit-control-fixture)

(def (emit-control-fixture init mode tasks plans publication)
  (def strategy
    (make-loop-strategy-plan 'weaver-routing
      (list (make-loop-pattern-descriptor 'infer "Original inference" '((level . l2)))
            (make-loop-pattern-descriptor 'next "Original continuation" '((level . l2))))))
  (def overrides
    (cond
      ((equal? mode "deny")
       '((shared-denylist . (infer)) (aggregate-budget . ((max-actionable . 2) (max-attempts . 1)))))
      ((equal? mode "clip") '((aggregate-budget . ((max-actionable . 1) (max-attempts . 1)))))
      ((equal? mode "invalid") '((aggregate-budget . ((max-actionable . -1)))))
      (else '((aggregate-budget . ((max-actionable . 2) (max-attempts . 1)))))))
  (def states (if (equal? mode "collision") '(((acting_on . infer))) '()))
  (def source-threat-model
    (if (equal? mode "threat")
      (agentic-ai-lab-governance-threat-model "weaver/exposed"
        (list (agentic-ai-lab-governance-threat "weaver/unreviewed" 'high 'exposed
                (list (agentic-ai-lab-governance-precondition "weaver/input" #t "evidence:input")))))
      AgenticAILabGovernanceThreatModel.))
  (def source-policies (if (equal? mode "obligation") (.o release: 'review-required) (.o)))
  (def profile
    (.o (:: @ AgenticAILabGovernanceProfile.)
        identity: "weaver/source" revision: "1" owner: "source-owner"
        threat-model: source-threat-model policies: source-policies))
  (emit-governed-gateway init (make-loop-governor 'weaver strategy overrides)
                        profile (.o request: 'publish) states tasks plans publication))
