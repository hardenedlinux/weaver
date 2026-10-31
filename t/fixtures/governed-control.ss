;;; Native source fixture for cross-language integration; no Go governance DSL.
(import :agentic-ai-lab/modules/loop-engine/control/governor
        :agentic-ai-lab/modules/loop-engine/control/strategy
        :agentic-ai-lab/modules/loop-engine/control/descriptor
        :agentic-ai-lab/modules/governance/interface
        (only-in :agentic-ai-lab/modules/authorization/providers/cedar/objects agentic-ai-lab-cedar-policy)
        (only-in :clan/poo/object .o .ref)
        (only-in :hardenedlinux/weaver/scheme/gateway/capture deliver-gateway-source)
        :hardenedlinux/weaver/scheme/gateway/func)
(export emit-control-fixture)

;;; Local phase evidence only. Labels and SDK clocks contain no source data;
;;; their presence cannot admit an artifact or certify natural process exit.
(def (trace-phase label)
  (let ((port (current-error-port)) (observed (time->seconds (current-time))))
    (display "weaver scheme phase=" port) (display label port)
    (display " real=" port) (display (real-time) port)
    (display " cpu=" port) (display (cpu-time) port)
    (display " wall-us=" port) (display (inexact->exact (floor (* observed 1000000))) port)
    (newline port) (force-output port)))

(trace-phase "fixture-module-ready")

(def (emit-control-fixture init mode tasks plans publication asset-root)
  (trace-phase "fixture-enter")
  (def captured? (string-prefix? "capture-" mode))
  (when captured? (set! mode (substring mode 8 (string-length mode))))
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
  (def native-policy
    (agentic-ai-lab-cedar-policy "weaver/runtime"
      (if (equal? mode "policy-substitution") "forbid(principal,action,resource);"
        (.ref publication 'policy))))
  (def source-policies
    (cond ((equal? mode "obligation") (.o release: 'review-required))
          ((equal? mode "assets-only") (.o))
          (else (.o runtime: native-policy))))
  (def asset-values
    (if (equal? mode "policy-only") '()
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
  (trace-phase "compile-begin")
  (def (produce)
    (emit-governed-gateway init (make-loop-governor 'weaver strategy overrides)
                          profile (.o request: 'publish source_root: asset-root) states tasks plans publication))
  (let ((result
         (if captured?
           (let ((text (capture-governed-gateway init (make-loop-governor 'weaver strategy overrides)
                                               profile (.o request: 'publish source_root: asset-root)
                                               states tasks plans publication)))
             (when (file-exists? (getenv "WEAVER_CONTROL_ARTIFACT"))
               (error "In-memory capture wrote a source artifact"))
             ;; The current Go bridge still needs its artifact. Native VM
             ;; assembly will consume text directly; this write is outside capture.
             (deliver-gateway-source text))
           (produce))))
    (trace-phase "artifact-written")
    result))
