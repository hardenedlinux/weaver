;;; Compose admitted module capabilities into the existing typed wire artifact.
(import (only-in :clan/poo/object .get .o .slot?)
        (only-in :clan/poo/mop validate json<-)
        (only-in :std/encoding/json json->string JSONWriteOptions)
        (only-in :yuanxu/module-system/interface yuanxu-load-modules)
        (only-in :hardenedlinux/weaver/scheme/governance/types GovernanceAssessmentContext)
        (only-in :hardenedlinux/weaver/scheme/governance/capture governance-profile-snapshot)
        (only-in :hardenedlinux/weaver/scheme/policy/types PolicyProjection)
        (only-in "./capture.ss" deliver-gateway-source gateway-source-json)
        (only-in "./snapshot.ss" copy-source-data)
        (only-in "./program.ss" make-gateway-program)
        "./contracts.ss")
(export compile-gateway emit-gateway emit-governed-gateway capture-governed-gateway gateway-source-json make-gateway-program)

(def (compile-gateway governance policy governor profile context states task-values plan-values publication-value)
  (unless (= (length task-values) 1)
    (error "one original family per Governor source handoff is required"))
  (def input-image
    (validate GatewaySourceInput
      (copy-source-data
        (validate GatewaySourceInput
          (.o tasks: task-values plans: plan-values publication: publication-value)))))
  (def retained-tasks (.get input-image tasks))
  (def retained-plans (.get input-image plans))
  (def retained-publication (.get input-image publication))
  (def asset-root (string-copy (if (.slot? context 'source_root) (.get context source_root) "")))
  (def profile-image (governance-profile-snapshot profile))
  (def profile-assessor (.get profile .assess-governance))
  (def threat-assessor (.get (.get profile threat-model) .assess-threats))
  (def (require-profile-current!)
    (unless (and (equal? profile-image (governance-profile-snapshot profile))
                 (eq? profile-assessor (.get profile .assess-governance))
                 (eq? threat-assessor (.get (.get profile threat-model) .assess-threats)))
      (error "Governance source changed during assessment")))
  (let* ((nodes ((.get governance open) governor states))
         (source-family (.get (car retained-tasks) family)))
    (def (same-node-set? actual)
      (and (= (length nodes) (length actual))
           (andmap (lambda (node) (member node actual)) nodes)
           (let unique ((remaining actual))
             (or (null? remaining)
                 (and (not (member (car remaining) (cdr remaining)))
                      (unique (cdr remaining)))))))
    (unless (and (pair? nodes) (same-node-set? (map (lambda (plan) (.get plan node)) retained-plans))
                 (same-node-set? (.get (car retained-tasks) nodes))
                 (andmap (lambda (plan)
                           (and (equal? (.get plan family) source-family)
                                (member (.get plan node) nodes))) retained-plans))
      (error "provider plans must exactly match the Governor source handoff"))
    ;; Retain caller data separately from the image assessed and returned. No
    ;; Policy/Governance callback receives a mutable alias into this image.
    (def original
      (validate GatewayArtifact
        (.o governance: (.o schema: "agentic-ai-lab.loop-governor.v1" family: source-family open_nodes: nodes)
            tasks: task-values plans: plan-values publication: publication-value)))
    (def bundle
      (validate GatewayArtifact
        (copy-source-data
          (.o governance: (.get original governance) tasks: retained-tasks
              plans: retained-plans publication: retained-publication))))
    (def publication-image (.get bundle publication))
    (def source-text (gateway-source-json bundle))
    (def projection ((.get policy project) profile (string-copy (.get publication-image policy)) (string-copy asset-root)))
    (def (projection-json value)
      (json->string (json<- PolicyProjection value) (JSONWriteOptions sort-keys: #t)))
    (def policy-inputs (projection-json projection))
    (unless ((.get policy validate) (string-copy (.get projection policy))
                                  (string-copy (.get publication-image schema)))
      (error "Policy preflight declined the source handoff"))
    (require-profile-current!)
    (let ((bound-context (validate GovernanceAssessmentContext
                            (.o request: (.get context request) source: (string-copy source-text)
                                policy_inputs: (string-copy policy-inputs)
                                profile_identity: (.get profile identity)
                                profile_revision: (.get profile revision)
                                profile_owner: (.get profile owner)
                                model_identity: (.get profile threat-model identity)))))
      (unless ((.get governance assess) profile bound-context)
        (error "Governance declined the source handoff"))
      (unless (equal? policy-inputs
                      (projection-json ((.get policy project) profile
                                        (string-copy (.get publication-image policy)) (string-copy asset-root))))
        (error "Governance Policy inputs changed during assessment"))
      (require-profile-current!)
      ;; All delegated callbacks finish before the final caller/image comparison.
      (unless (and (equal? source-text (gateway-source-json bundle))
                   (equal? source-text (gateway-source-json original))
                   (equal? asset-root (if (.slot? context 'source_root) (.get context source_root) "")))
        (error "Governance source changed during assessment"))
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
