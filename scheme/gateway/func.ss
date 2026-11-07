;;; SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
;;;
;;; SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

;;; Compose admitted module capabilities into the existing typed wire artifact.
(import (only-in :clan/poo/object .get .o .slot?)
        (only-in :clan/poo/mop validate json<-)
        (only-in :std/encoding/json json->string JSONWriteOptions)
        (only-in :yuanxu/module-system/interface yuanxu-load-modules)
        (only-in :yuanxu/module-system/source/admission module-source-measure-operation)
        (only-in :agentic-ai-lab/modules/loop-engine/control/governor loop-governor->contract)
        (only-in :agentic-ai-lab/modules/session/objects-core agentic-ai-lab-session? agentic-ai-lab-session-id)
        (only-in :yuanxu/modules/funflow/control-plane/flow admit-flow flow-name flow-steps branch-step? branch-step-name branch-step-left branch-step-right)
        (only-in :yuanxu/modules/funflow/control-plane/task task? task-name task-kind task-request-operation)
        (only-in :hardenedlinux/weaver/scheme/governance/types GovernanceAssessmentContext)
        (only-in :hardenedlinux/weaver/scheme/governance/capture governance-profile-snapshot)
        (only-in :hardenedlinux/weaver/scheme/policy/types PolicyProjection)
        (only-in :hardenedlinux/weaver/scheme/policy/func validate-policy-projection!)
        (only-in :gerbil-ascent/program/scheme-language relational-program)
        (only-in :gerbil-ascent/program/session gerbil-ascent-open-session gerbil-ascent-session-run
                 gerbil-ascent-session-replace-sources!)
        (only-in "./capture.ss" deliver-gateway-source)
        (only-in "./snapshot.ss" copy-source-data)
        (only-in "./program.ss" make-gateway-program)
        (only-in "./derivation.ss" derive-gateway-source)
        (only-in "./derivation-types.ss" GatewayPreparation)
        "./contracts.ss")
(export compile-gateway prepare-gateway prepare-governed-gateway emit-gateway emit-governed-gateway capture-governed-gateway make-gateway-program governor-open-nodes governor-ready-steps)
(export gateway-source-phase-observer gateway-source-cancelled? make-retained-governor trace-gateway-source-phase)

;;; Each source-loaded role has its own parameter. Enable the same numeric
;;; diagnostic in both the linked entry and the role only when requested.
(def (trace-gateway-source-phase label)
  (let ((port (current-error-port)) (observed (time->seconds (current-time))))
    (display "weaver scheme phase=" port) (display label port)
    (display " real=" port) (display (real-time) port)
    (display " cpu=" port) (display (cpu-time) port)
    (display " wall-us=" port) (display (inexact->exact (floor (* observed 1000000))) port)
    (newline port) (force-output port)))

(def gateway-source-phase-observer
  (make-parameter (and (getenv "WEAVER_TEST_GOVERNOR_TIMING" #f) trace-gateway-source-phase)))
(def gateway-source-cancelled? (make-parameter #f))
(def (source-phase! phase)
  (let ((observe (gateway-source-phase-observer)))
    (when observe (observe phase))))

(def (require-source-open!)
  (let ((cancelled? (gateway-source-cancelled?)))
    (when (and cancelled? (cancelled?))
      (source-phase! "source-preparation-cancelled")
      (error "Gateway source preparation cancelled"))))

;;; Private canonical text for the upstream assessment context and mutation guard.
;;; It is neither an exported artifact nor the Scheme-to-Rust transport.
(def (source-assessment-text value)
  (json->string (json<- GatewayArtifact value)
               (JSONWriteOptions sort-keys: #t)))

;;; Only project upstream symbolic node names to the gateway's wire identifiers.
;;; Governor owns selection; Governance assessment cannot replace its result.
(def (governor-open-nodes governor states)
  (map symbol->string (cdr (assq 'open-patterns (loop-governor->contract governor states)))))

;;; Compile sequential and fan-out/fan-in Funflow steps into a sealed topology.
;;; Each recursive walk returns the set of leaves needed by the next step.
(def (session-workflow-path context family)
  (and (.slot? context 'session)
       (let* ((session (.get context session))
              (identity (string->symbol family)))
         (unless (and (agentic-ai-lab-session? session)
                      (eq? identity (agentic-ai-lab-session-id session)))
           (error "Workflow Session must name the original family"))
         (def workflow (admit-flow (.get session workflow)))
         (def nodes '())
         (def edges '())
         (def branched? #f)
         (def selectors '())
         (def choice-names (if (.slot? session 'workflow-choices) (.get session workflow-choices) '()))
         (def (walk steps previous)
           (if (null? steps) previous
             (let ((step (car steps)))
               (cond
                 ((branch-step? step)
                  (set! branched? #t)
                  (unless (pair? previous) (error "Workflow requires one provider root"))
                  (let* ((left-steps (flow-steps (branch-step-left step)))
                         (right-steps (flow-steps (branch-step-right step)))
                         (name (branch-step-name step))
                         (conditional? (memq name choice-names)))
                    (when conditional?
                      (unless (and (null? (cdr previous)) (pair? left-steps) (pair? right-steps)
                                   (task? (car left-steps)) (task? (car right-steps)))
                        (error "Each conditional fork requires a selector and one entry per arm"))
                      (set! choice-names (remq name choice-names))
                      (set! selectors (cons (list (car previous)
                                                  (symbol->string (task-name (car left-steps)))
                                                  (symbol->string (task-name (car right-steps))))
                                             selectors)))
                    (let* ((left (walk left-steps previous))
                           (right (walk right-steps previous)))
                      (when (or (equal? left previous) (equal? right previous))
                        (error "Workflow branch requires two nonempty paths"))
                      (walk (cdr steps) (append left right)))))
                 ((and (task? step) (eq? (task-kind step) 'external)
                       (eq? (task-request-operation step) 'weaver-provider-response))
                  (let ((node (symbol->string (task-name step))))
                    (when (or (member node nodes) (>= (length nodes) 64))
                      (error "Workflow node identity"))
                    (set! nodes (cons node nodes))
                    (for-each (lambda (parent) (set! edges (cons (list node parent) edges))) previous)
                    (walk (cdr steps) (list node))))
                 (else (error "Workflow requires external provider tasks"))))))
         (unless (eq? (flow-name workflow) identity) (error "Workflow identity"))
         (walk (flow-steps workflow) '())
         (unless (and (<= 2 (length nodes) 64) (<= (length edges) 64))
           (error "Workflow bounds"))
         (unless (null? choice-names) (error "Unbound conditional fork"))
         (def conditional? (and (.slot? session 'workflow-choice) (eq? (.get session workflow-choice) #t)))
         (when (and conditional? (not branched?)) (error "Conditional Workflow requires a fork and join"))
         (list (reverse nodes)
               (and branched? (list-sort
                 (lambda (a b) (or (string<? (car a) (car b))
                                   (and (equal? (car a) (car b)) (string<? (cadr a) (cadr b)))))
                 edges))
               conditional?
               (list-sort (lambda (a b) (string<? (car a) (car b))) selectors)))))

;;; All values are detached observations from the Rust ledger. Derived nodes
;;; carry no authority across the subsequent ledger admission transaction.
(def (governor-ready-steps cut)
  (derive-governor-steps cut #f))

;;; The linked owner retains at most one graph and one completed ASCENT session.
;;; The linked image fixes the rules. Each new cut replaces every dynamic input.
(def (make-retained-governor)
  (def topology #f)
  (def session #f)
  (def (forget!)
    (set! topology #f)
    (set! session #f))
  (def (derive graph sources build-program)
    (if (and session (equal? topology graph))
      (values (gerbil-ascent-session-replace-sources! session sources) 'replace)
      (begin
        (forget!)
        (let* ((candidate (gerbil-ascent-open-session (build-program)))
               (result (gerbil-ascent-session-run candidate)))
          (when (.ref result 'finished)
            (set! topology (copy-source-data graph))
            (set! session candidate))
          (values result 'open)))))
  (lambda (cut)
    (with-catch
      (lambda (failure)
        (forget!)
        (raise failure))
      (lambda () (derive-governor-steps cut derive)))))

(def (derive-governor-steps cut retained)
  (def timing? (getenv "WEAVER_TEST_GOVERNOR_TIMING" #f))
  (def nodes (.get cut nodes))
  (def ids (make-hash-table))
  (for-each (lambda (node index) (hash-put! ids node index)) nodes (iota (length nodes)))
  (def (rows slot)
    (map (lambda (node) (list (hash-ref ids node))) (.ref cut slot)))
  (def edges
    (map (lambda (edge) (map (lambda (node) (hash-ref ids node)) edge))
         (.get cut edges)))
  (def arms (if (.slot? cut 'choice_arms) (.get cut choice_arms) '()))
  (def (choice-rows slot) (if (.slot? cut slot) (rows slot) '()))
  (def route
    (if (.slot? cut 'choice_result)
      (map (lambda (value) (list (if (equal? value "left") 0 1))) (.get cut choice_result))
      '()))
  (def selectors (if (.slot? cut 'nested_selectors) (.get cut nested_selectors) '()))
  (def (routes slot)
    (if (.slot? cut slot)
      (map (lambda (row) (list (hash-ref ids (car row)) (if (equal? (cadr row) "left") 0 1))) (.ref cut slot))
      '()))
  (def arm
    (map (lambda (node tag) (list (hash-ref ids node) tag)) arms (iota (length arms))))
  (def join (choice-rows 'choice_join))
  (def nested-nodes (if (null? selectors) '() (map list (iota (length nodes)))))
  (def nested-root (if (null? selectors) '() '((0))))
  (def gate
    (apply append (map (lambda (row)
      (let ((selector (hash-ref ids (car row))))
        (list (list (hash-ref ids (cadr row)) selector 0)
              (list (hash-ref ids (caddr row)) selector 1)))) selectors)))
  (def sources
    (list (cons 'complete (rows 'complete))
          (cons 'available (rows 'available))
          (cons 'pending (rows 'pending))
          (cons 'route route)
          (cons 'decided (choice-rows 'choice_decided))
          (cons 'selector-result (routes 'nested_results))
          (cons 'selector-decision (routes 'nested_decisions))))
  (def (source name) (cdr (assq name sources)))
  (def setup 0)
  (def (build-program)
    (def started (and timing? (real-time)))
    (begin0
      (relational-program
        (relation edge (child parent) edges)
        (relation complete (node) (source 'complete))
        (relation available (node) (source 'available))
        (relation pending (node) (source 'pending))
        (relation arm (node tag) arm)
        (relation route (tag) (source 'route))
        (relation join (node) join)
        (relation decided (node) (source 'decided))
        (relation choice-made (node) '())
        (relation skip (child parent) '())
        (relation missing (node) '())
        (relation successor (node) '())
        (relation ready (node) '())
        (relation nested-node (node) nested-nodes)
        (relation nested-root (node) nested-root)
        (relation gate (child selector tag) gate)
        (relation selector-result (selector tag) (source 'selector-result))
        (relation selector-decision (selector tag) (source 'selector-decision))
        (relation gated (child parent) '())
        (relation decided-selector (selector) '())
        (relation enabled (child parent) '())
        (relation active (node) '())
        (relation unresolved (node) '())
        (relation blocked (node) '())
        (rule (successor ?n) (edge ?n ?p))
        (rule (choice-made ?n) (join ?n) (decided ?p))
        (rule (skip ?n ?p) (edge ?n ?p) (choice-made ?n) (not (decided ?p)))
        (rule (missing ?n) (join ?n) (not (choice-made ?n)))
        (rule (missing ?n) (arm ?n ?tag) (not (route ?tag)))
        (rule (missing ?n) (edge ?n ?p) (not (skip ?n ?p)) (not (complete ?p)))
        (rule (missing ?n) (edge ?n ?p) (not (skip ?n ?p)) (not (available ?p)))
        (rule (ready ?n) (successor ?n) (pending ?n) (available ?n) (not (nested-node ?n)) (not (missing ?n)))
        (rule (gated ?n ?p) (gate ?n ?p ?tag))
        (rule (decided-selector ?p) (selector-decision ?p ?tag))
        (rule (enabled ?n ?p) (edge ?n ?p) (not (gated ?n ?p)))
        (rule (enabled ?n ?p) (gate ?n ?p ?tag) (selector-decision ?p ?tag))
        (rule (active ?n) (nested-root ?n))
        (rule (active ?n) (enabled ?n ?p) (active ?p))
        (rule (unresolved ?n) (gate ?n ?p ?tag) (active ?p) (not (decided-selector ?p)))
        (rule (unresolved ?n) (edge ?n ?p) (unresolved ?p))
        (rule (blocked ?n) (edge ?n ?p) (unresolved ?p))
        (rule (blocked ?n) (enabled ?n ?p) (active ?p) (not (complete ?p)))
        (rule (blocked ?n) (enabled ?n ?p) (active ?p) (not (available ?p)))
        (rule (ready ?n) (nested-node ?n) (active ?n) (successor ?n) (pending ?n) (available ?n) (not (blocked ?n)))
        (rule (ready ?n) (gate ?n ?p ?tag) (selector-result ?p ?tag) (active ?p)
              (complete ?p) (available ?p) (available ?n) (pending ?n) (not (decided-selector ?p)))
        (limits 640 768 1408))
      (when started (set! setup (- (real-time) started)))))
  (def run-start (and timing? (real-time)))
  (defvalues (result mode)
    (if retained
      (retained (list nodes edges arm join nested-nodes nested-root gate) sources build-program)
      (values (gerbil-ascent-session-run (gerbil-ascent-open-session (build-program))) 'fresh)))
  (when timing?
    (let ((end (real-time)) (port (current-error-port)))
      (display "weaver-governor-ascent setup_s=" port)
      (display setup port)
      (display " open_run_s=" port)
      (display (- end run-start setup) port)
      (display " mode=" port)
      (display mode port)
      (newline port)
      (force-output port)))
  (unless (eq? (.ref result 'finished) #t) (error "Session derivation incomplete"))
  (map (lambda (row) (list-ref nodes (car row))) ((.ref result 'rows-of) 'ready)))

(def (compile-gateway-source governance policy governor profile context states task-values plan-values publication-value)
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
  (let* ((nodes (governor-open-nodes governor states))
         (source-family (.get (car retained-tasks) family))
         (workflow (session-workflow-path context source-family)))
    (def (same-node-set? actual)
      (and (= (length nodes) (length actual))
           (andmap (lambda (node) (member node actual)) nodes)
           (let unique ((remaining actual))
             (or (null? remaining)
                 (and (not (member (car remaining) (cdr remaining)))
                      (unique (cdr remaining)))))))
    (unless (and (pair? nodes) (same-node-set? (map (lambda (plan) (.get plan node)) retained-plans))
                 (same-node-set? (.get (car retained-tasks) nodes))
                 (or (not workflow) (same-node-set? (car workflow)))
                 (andmap (lambda (plan)
                           (and (equal? (.get plan family) source-family)
                                (member (.get plan node) nodes))) retained-plans))
      (error "provider plans must exactly match the Governor source handoff"))
    ;; Retain caller data separately from the image assessed and returned. No
    ;; Policy/Governance callback receives a mutable alias into this image.
    (def selection
      (cond
        ((not workflow)
         (.o schema: "agentic-ai-lab.loop-governor.v1" family: source-family open_nodes: nodes))
        ((pair? (cadddr workflow))
         (.o schema: "weaver.session-nested.v1" family: source-family open_nodes: (car workflow)
             workflow_edges: (cadr workflow) workflow_selectors: (cadddr workflow)))
        ((cadr workflow)
         (.o schema: (if (caddr workflow) "weaver.session-choice.v1" "weaver.session-dag.v1")
             family: source-family open_nodes: (car workflow)
             workflow_edges: (cadr workflow)))
        (else
         (.o schema: "weaver.session-workflow.v1" family: source-family open_nodes: (car workflow)))))
    (def original
      (validate GatewayArtifact
        (.o governance: selection tasks: task-values plans: plan-values publication: publication-value)))
    (def bundle
      (validate GatewayArtifact
        (copy-source-data
          (.o governance: (.get original governance) tasks: retained-tasks
              plans: retained-plans publication: retained-publication))))
    (def publication-image (.get bundle publication))
    (def source-text (source-assessment-text bundle))
    (source-phase! "source-contract-input-captured")
    (def projection ((.get policy project) profile (string-copy (.get publication-image policy)) (string-copy asset-root)))
    (def (projection-json value)
      (json->string (json<- PolicyProjection value) (JSONWriteOptions sort-keys: #t)))
    (def policy-inputs (projection-json projection))
    (validate-policy-projection! projection (.get publication-image schema) (.get policy validate))
    (source-phase! "source-contract-policy-validated")
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
      (source-phase! "source-contract-governance-assessed")
      (unless (equal? policy-inputs
                      (projection-json ((.get policy project) profile
                                        (string-copy (.get publication-image policy)) (string-copy asset-root))))
        (error "Governance Policy inputs changed during assessment"))
      (require-profile-current!)
      ;; All delegated callbacks finish before the final caller/image comparison.
      (unless (and (equal? source-text (source-assessment-text (validate GatewayArtifact bundle)))
                   (equal? source-text (source-assessment-text (validate GatewayArtifact original)))
                   (equal? workflow (session-workflow-path context source-family))
                   (equal? asset-root (if (.slot? context 'source_root) (.get context source_root) "")))
        (error "Governance source changed during assessment"))
      bundle)))

;;; The ordinary source path now executes the same bounded advisory derivation
;;; exposed by prepare. The typed wire artifact remains exactly the original;
;;; derived candidates never rewrite plans, authorize an effect or settle usage.
(def (prepare-gateway governance policy governor profile context states tasks plans publication)
  (def source-image
    (module-source-measure-operation 'gateway-source-contracts
      (lambda () (compile-gateway-source governance policy governor profile context states tasks plans publication))))
  (source-phase! "source-contracts-checked")
  (def advisory
    (module-source-measure-operation 'gateway-source-advisory
      (lambda () (derive-gateway-source source-image))))
  (source-phase! "source-advisory-derived")
  (validate GatewayPreparation (.o source: source-image derivation: advisory)))

(def (compile-gateway governance policy governor profile context states tasks plans publication)
  (.get (prepare-gateway governance policy governor profile context states tasks plans publication) source))

(def (emit-gateway bundle)
  (deliver-gateway-source bundle))

;;; Accept a source path or a retained Yuanxu view from a Scheme caller.
;;; Every use still checks the view's source generation before and after delivery.
(def (with-current-gateway source operation)
  (require-source-open!)
  (let* ((view (cond
                ((not (string? source)) source)
                ((gateway-source-cancelled?)
                 (yuanxu-load-modules source module-view:
                   (lambda (_ resolve)
                     (require-source-open!)
                     (let ((scope (resolve)))
                       (require-source-open!)
                       scope))))
                (else (apply yuanxu-load-modules (list source)))))
         (gateway (begin
                    (source-phase! "source-selection-loaded")
                    (.get view modules Weaver gateway)))
         (admit-current (.get view admit-current)))
    (source-phase! "source-module-view-loaded")
    (require-source-open!)
    (admit-current)
    (source-phase! "source-admitted-before-prepare")
    (let ((result (operation gateway admit-current)))
      (source-phase! "source-delivery-prepared")
      (require-source-open!)
      (admit-current)
      (source-phase! "source-admitted-after-prepare")
      result)))

(def (produce-governed-source gateway admit-current governor profile context states tasks plans publication)
  (let ((bundle ((.get gateway compile) governor profile context states tasks plans publication)))
    (source-phase! "source-object-and-advisory-prepared")
    (require-source-open!)
    (admit-current)
    (source-phase! "source-admitted-before-delivery")
    ((.get gateway emit) bundle)))

;;; Scheme source-generation guards qualify compilation, not final execution.
(def (emit-governed-gateway source governor profile context states tasks plans publication)
  (with-current-gateway source
    (lambda (gateway admit-current)
      (produce-governed-source gateway admit-current governor profile context states tasks plans publication))))

(def (capture-governed-gateway source governor profile context states tasks plans publication)
  (with-current-gateway source
    (lambda (gateway admit-current)
      ((.get gateway capture)
       (lambda ()
         (produce-governed-source gateway admit-current governor profile context states tasks plans publication))))))

;;; Rich preparation remains inside the same admitted Yuanxu view. The caller
;;; may inspect advisory evidence; existing emit/capture still accept only source.
(def (prepare-governed-gateway source governor profile context states tasks plans publication)
  (with-current-gateway source
    (lambda (gateway admit-current)
      ((.get gateway prepare) governor profile context states tasks plans publication))))
