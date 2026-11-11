;;; SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
;;;
;;; SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

;;; Native source fixture for cross-language integration; no Go governance DSL.
(import :agentic-ai-lab/modules/loop-engine/control/governor
        :agentic-ai-lab/modules/governance/interface
        (only-in :agentic-ai-lab/modules/authorization/providers/cedar/objects agentic-ai-lab-cedar-policy)
        :hardenedlinux/weaver/scheme/gateway/provider-source
        (only-in :clan/poo/object .o .ref)
        :hardenedlinux/weaver/scheme/gateway/func)
(export capture-control-fixture prepare-control-fixture)

(trace-gateway-source-phase "fixture-module-ready")

(def (capture-control-fixture init mode tasks plans publication asset-root)
  (control-fixture init mode tasks plans publication asset-root))

(def (prepare-control-fixture init mode tasks plans publication asset-root)
  (control-fixture init mode tasks plans publication asset-root #t))

(def (control-fixture init mode tasks plans publication asset-root (preparation? #f))
  (trace-gateway-source-phase "fixture-enter")
  (def prefixed? (string-prefix? "capture-" mode))
  (when prefixed? (set! mode (substring mode 8 (string-length mode))))
  (def nested? (equal? mode "session-nested"))
  (def choice? (equal? mode "session-choice"))
  (def dag? (or nested? choice? (equal? mode "session-dag")))
  (def session? (or dag? (equal? mode "session-workflow")))
  (def strategy (provider-source-strategy nested? dag? session?))
  (def overrides
    (cond
      ((equal? mode "deny")
       '((shared-denylist . (infer)) (aggregate-budget . ((max-actionable . 2) (max-attempts . 1)))))
      ((equal? mode "clip") '((aggregate-budget . ((max-actionable . 1) (max-attempts . 1)))))
      ((equal? mode "invalid") '((aggregate-budget . ((max-actionable . -1)))))
      (else (provider-source-budget nested? dag? session?))))
  (def states (if (equal? mode "collision") '(((acting_on . infer))) '()))
  (def source-threat-model
    (if (equal? mode "threat")
      (agentic-ai-lab-governance-threat-model "weaver/exposed"
        (list (agentic-ai-lab-governance-threat "weaver/unreviewed" 'high 'exposed
                (list (agentic-ai-lab-governance-precondition "weaver/input" #t "evidence:input")))))
      AgenticAILabGovernanceThreatModel.))
  (def native-policy
    (agentic-ai-lab-cedar-policy "weaver/runtime"
      (if (equal? mode "policy-substitution") "forbid(principal,action,resource);"
        (.ref publication 'policy))))
  (def source-policies
    (cond ((equal? mode "obligation") (.o release: 'review-required))
          ((equal? mode "assets-only") (.o))
          (else (.o runtime: native-policy))))
  (def asset-values
    (if (or session? (equal? mode "policy-only")) '()
      (list (agentic-ai-lab-governance-source
              (if (equal? mode "policy-identity") "weaver/replacement" "weaver/runtime")
              (if (equal? mode "asset-traversal") "../policy.cedar" "policy.cedar")
              (if (equal? mode "asset-language") 'gql 'cedar)))))
  (def original-profile-label (string-copy "weaver/source"))
  (def profile
    (.o (:: @ AgenticAILabGovernanceProfile.)
        identity: original-profile-label revision: "1" owner: "source-owner"
        threat-model: source-threat-model policies: source-policies source-assets: asset-values
        .assess-governance:
        (lambda (assessment-context)
          (when (equal? mode "assessment-profile-mutation")
            (string-set! original-profile-label 0 #\x))
          (let ((assessment (agentic-ai-lab-governance-assessment profile assessment-context)))
            (cond
              ((equal? mode "assessment-context")
               (.o (:: @ assessment) context: (.o (:: @ assessment-context) source: "stale-source")))
              ((equal? mode "assessment-revision")
               (.o (:: @ assessment) context: (.o (:: @ assessment-context) profile_revision: "0")))
              ((equal? mode "assessment-model")
               (.o (:: @ assessment) model-identity: "weaver/other-model"))
              ((equal? mode "assessment-threats")
               (.o (:: @ assessment) assessed-threats:
                   (list (agentic-ai-lab-governance-threat "weaver/other-threat" 'low 'latent
                           (list (agentic-ai-lab-governance-precondition "weaver/input" #f #f))))))
              (else assessment))))))
  (trace-gateway-source-phase "compile-begin")
  (let ((result (parameterize ((gateway-source-phase-observer trace-gateway-source-phase))
                  ((if preparation? prepare-governed-gateway capture-governed-gateway)
                        init (make-loop-governor 'weaver strategy overrides)
                        profile (if session?
                                  (.o request: 'publish source_root: asset-root session: (if nested? (nested-workflow-session) (workflow-session dag? choice?)))
                                  (.o request: 'publish source_root: asset-root))
                        states tasks plans publication))))
    (trace-gateway-source-phase "source-captured")
    result))
