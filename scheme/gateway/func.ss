;;; Compose admitted module capabilities into the existing typed wire artifact.
(import (only-in :clan/poo/object .get .o .slot?)
        (only-in :clan/poo/mop validate json<-)
        (only-in :std/encoding/json json->string JSONWriteOptions)
        (only-in :yuanxu/module-system/interface yuanxu-load-modules)
        (only-in :hardenedlinux/weaver/scheme/governance/types GovernanceAssessmentContext)
        (only-in :hardenedlinux/weaver/scheme/policy/types PolicyProjection)
        (only-in "./capture.ss" deliver-gateway-source gateway-source-json)
        (only-in "./program.ss" make-gateway-program)
        "./contracts.ss")
(export compile-gateway emit-gateway emit-governed-gateway capture-governed-gateway gateway-source-json make-gateway-program)

(def (compile-gateway governance policy governor profile context states task-values plan-values publication-value)
  (unless (= (length task-values) 1)
    (error "one original family per Governor source handoff is required"))
  (let* ((nodes ((.get governance open) governor states))
         (source-family (.get (car task-values) family))
         (asset-root (if (.slot? context 'source_root) (.get context source_root) "")))
    (def (same-node-set? actual)
      (and (= (length nodes) (length actual))
           (andmap (lambda (node) (member node actual)) nodes)
           (let unique ((remaining actual))
             (or (null? remaining)
                 (and (not (member (car remaining) (cdr remaining)))
                      (unique (cdr remaining)))))))
    (unless (and (pair? nodes) (same-node-set? (map (lambda (plan) (.get plan node)) plan-values))
                 (same-node-set? (.get (car task-values) nodes))
                 (andmap (lambda (plan)
                           (and (equal? (.get plan family) source-family)
                                (member (.get plan node) nodes))) plan-values))
      (error "provider plans must exactly match the Governor source handoff"))
    (def projection ((.get policy project) profile (.get publication-value policy) asset-root))
    (def (projection-json value)
      (json->string (json<- PolicyProjection value) (JSONWriteOptions sort-keys: #t)))
    (def policy-inputs (projection-json projection))
    (unless ((.get policy validate) (.get projection policy) (.get publication-value schema))
      (error "Policy preflight declined the source handoff"))
    (let* ((bundle (validate GatewayArtifact
                     (.o governance: (.o schema: "agentic-ai-lab.loop-governor.v1" family: source-family open_nodes: nodes)
                         tasks: task-values plans: plan-values publication: publication-value)))
           (source-text (gateway-source-json bundle))
           (bound-context (validate GovernanceAssessmentContext
                            (.o request: (.get context request) source: source-text
                                policy_inputs: policy-inputs
                                profile_identity: (.get profile identity)
                                profile_revision: (.get profile revision)
                                profile_owner: (.get profile owner)
                                model_identity: (.get profile threat-model identity)))))
      (unless ((.get governance assess) profile bound-context)
        (error "Governance declined the source handoff"))
      (unless (equal? source-text (gateway-source-json bundle))
        (error "Governance source changed during assessment"))
      (unless (equal? policy-inputs
                      (projection-json ((.get policy project) profile (.get publication-value policy) asset-root)))
        (error "Governance Policy inputs changed during assessment"))
      bundle)))

(def (emit-gateway bundle)
  (deliver-gateway-source bundle))

;;; Both delivery modes use one admitted module view and one semantic producer.
(def (with-current-gateway init operation)
  ;; Use the public callable value rather than a compiler-private keyword entry.
  (let* ((view (apply yuanxu-load-modules (list init)))
         (gateway (.get view modules Weaver gateway))
         (admit-current (.get view admit-current)))
    (admit-current)
    (let ((result (operation gateway admit-current)))
      (admit-current)
      result)))

(def (produce-governed-source gateway admit-current governor profile context states tasks plans publication)
  (let ((bundle ((.get gateway compile) governor profile context states tasks plans publication)))
    (admit-current)
    ((.get gateway emit) bundle)))

;;; Native source-generation guards qualify compilation, not final execution.
(def (emit-governed-gateway init governor profile context states tasks plans publication)
  (with-current-gateway init
    (lambda (gateway admit-current)
      (produce-governed-source gateway admit-current governor profile context states tasks plans publication))))

(def (capture-governed-gateway init governor profile context states tasks plans publication)
  (with-current-gateway init
    (lambda (gateway admit-current)
      ((.get gateway capture)
       (lambda ()
         (produce-governed-source gateway admit-current governor profile context states tasks plans publication))))))
