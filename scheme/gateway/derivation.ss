;;; SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
;;;
;;; SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

;;; Fixed, finite application rules over detached integer projections. ASCENT
;;; owns evaluation/replacement; this adapter owns the existing Gateway image.
(import (only-in :clan/poo/object .o .get .ref seal-object!)
        (only-in :clan/poo/mop validate json<-)
        (only-in :std/encoding/json json->string JSONWriteOptions)
        (only-in :std/crypto/digest sha256)
        (only-in :std/encoding/hex hex-encode)
        (only-in :std/list/list delete-duplicates/hash append-map)
        (only-in :gerbil-ascent/program/session gerbil-ascent-open-session
                 gerbil-ascent-session-run gerbil-ascent-session-replace-sources!)
        "./contracts.ss" "./derivation-types.ss"
        (only-in "./program.ss" gateway-impact-program)
        (only-in "./snapshot.ss" copy-source-data))
(export make-gateway-derivation derive-gateway-source gateway-derivation-request)

;;; These bounds qualify this closed advisory kernel, not the Gateway's budget
;;; or a wall-clock deadline. There are no callbacks, generators or new atoms in
;;; its recursive rule. Existing capture size/depth bounds apply independently.
(def +input-facts+ 4096)
(def +rule-profile+ "weaver.gateway.declared-offers-impact.v1")
(def +limit-profile+ "input:4096;derived:8192;output:12288;capture:existing")
(def (canonical contract value)
  ;; Private callers supply detached values already admitted by owned/Record
  ;; contracts. No foreign callback can mutate them during serialization.
  (json->string (json<- contract value) (JSONWriteOptions sort-keys: #t)))
(def (digest text) (hex-encode (sha256 (string->utf8 text))))
(def (owned contract value) (validate contract (copy-source-data (validate contract value))))
(def (unique-sorted values) (list-sort string<? (delete-duplicates/hash values)))

(def (gateway-derivation-request source-value (dependency-values '()) (changed-values '()))
  (owned GatewayDerivationRequest (.o source: source-value dependencies: dependency-values changed: changed-values)))

(def (project request)
  (def source (.get request source))
  (unless (= (length (.get source tasks)) 1)
    (error "one original family per derivation is required"))
  (def task (car (.get source tasks)))
  (def plans (.get source plans))
  (unless (andmap (lambda (plan) (equal? (.get task family) (.get plan family))) plans)
    (error "derivation plans must share the original family"))
  (def raw
    (list
      (cons 'operation (map (lambda (plan) (list (.get plan node))) plans))
      (cons 'offer
        (append-map (lambda (plan)
                      (map (lambda (route) (list (.get plan node) (.get route target) (.get plan model)))
                           (.get plan routes))) plans))
      (cons 'declared-node (map list (.get task nodes)))
      (cons 'declared-target (map list (.get task targets)))
      (cons 'declared-model (map list (.get task models)))
      (cons 'depends (map (lambda (edge) (list (.get edge dependent) (.get edge dependency)))
                         (.get request dependencies)))
      (cons 'changed (map list (.get request changed)))))
  (when (> (apply + (map (lambda (entry) (length (cdr entry))) raw)) +input-facts+)
    (error "Gateway derivation input fact bound"))
  ;; A per-cut dictionary admits immutable integers into ASCENT. Never intern
  ;; attacker-selected identifiers or retain mutable nested host values. Every
  ;; source relation is replaced together if the dictionary changes.
  (def names (unique-sorted (append-map (lambda (entry) (apply append (cdr entry))) raw)))
  (def ids (make-hash-table))
  (for-each (lambda (name index) (hash-put! ids name index)) names (iota (length names)))
  (values task raw (list->vector names)
          (map (lambda (entry) (cons (car entry)
                                    (map (lambda (row) (map (lambda (name) (hash-ref ids name)) row))
                                         (cdr entry)))) raw)))

(def (make-program inputs)
  (def (rows name) (cdr (assq name inputs)))
  (gateway-impact-program ((rows 'depends) (rows 'changed)) (4096 8192 12288)
    (relation operation (node) (rows 'operation))
    (relation offer (node target model) (rows 'offer))
    (relation declared-node (node) (rows 'declared-node))
    (relation declared-target (target) (rows 'declared-target))
    (relation declared-model (model) (rows 'declared-model))
    (relation candidate (node target model) '())
    (relation affected-node (node) '())
    (rule (candidate ?n ?t ?m) (offer ?n ?t ?m) (declared-node ?n)
          (declared-target ?t) (declared-model ?m))
    (rule (affected-node ?n) (operation ?n) (affected ?n))))

(def (make-report request request-image task raw names result report-generation)
  (unless (eq? (.ref result 'finished) #t)
    (error "Gateway derivation did not complete"))
  (def (rows name) ((.ref result 'rows-of) name))
  (def (decode index) (vector-ref names index))
  (def (member? value values) (if (member value values) #t #f))
  (def (declared? name value) (member? (list value) (cdr (assq name raw))))
  ;; Canonicalize presentation independently of evaluator iteration order.
  (def candidate-rows (rows 'candidate))
  (def offers (delete-duplicates/hash (cdr (assq 'offer raw))))
  (def (row<? left right)
    (let loop ((left left) (right right))
      (and (pair? left)
           (or (string<? (car left) (car right))
               (and (equal? (car left) (car right)) (loop (cdr left) (cdr right)))))))
  (owned GatewayDerivationResult
    (.o source_digest: (digest (canonical GatewayArtifact (.get request source)))
        request_digest: (digest request-image)
        family: (.get task family) generation: report-generation rule_profile: +rule-profile+
        limit_profile: +limit-profile+ complete: #t execution_authorized: #f
        candidates:
        (map (lambda (row) (.o node: (car row) target: (cadr row) model: (caddr row)))
             (list-sort row<? (map (lambda (row) (map decode row)) candidate-rows)))
        explanations:
        (map (lambda (row)
               (.o node: (car row) target: (cadr row) model: (caddr row)
                   declared_node: (declared? 'declared-node (car row))
                   declared_target: (declared? 'declared-target (cadr row))
                   declared_model: (declared? 'declared-model (caddr row)))) (list-sort row<? offers))
        affected: (unique-sorted (map (lambda (row) (decode (car row))) (rows 'affected)))
        affected_nodes: (unique-sorted (map (lambda (row) (decode (car row))) (rows 'affected-node))))))

(def (make-gateway-derivation)
  (def owner (current-thread))
  (def closed? #f)
  (def busy? #f)
  (def session #f)
  (def generation 0)
  (def last-input #f)
  (def last-report #f)
  (def (require-owner!)
    (unless (eq? owner (current-thread)) (error "Gateway derivation requires its serialized owner"))
    (when closed? (error "Gateway derivation is closed"))
    (when busy? (error "Gateway derivation is active")))
  (def (next-generation)
    (when (= generation 9223372036854775807)
      (set! closed? #t)
      (error "Gateway derivation generation exhausted"))
    (1+ generation))
  (def (derive-request request)
    (require-owner!)
    ;; The Function contract admits the input before this private method runs.
    ;; Check the detached image before keeping or evaluating it.
    (def input (validate GatewayDerivationRequest (copy-source-data request)))
    (def image (canonical GatewayDerivationRequest input))
    (if (and last-input (equal? image last-input))
      (owned GatewayDerivationResult last-report)
      (let-values (((task raw names inputs) (project input)))
        (def next (next-generation))
        (def report #f)
        (dynamic-wind
          (lambda () (set! busy? #t))
          (lambda ()
            (with-catch
              (lambda (failure)
                ;; A failed native/local handoff cannot certify engine rollback.
                ;; Discard the engine; the last detached accepted result remains
                ;; exact, and the next changed input starts from a fresh engine.
                (set! session #f)
                (raise failure))
              (lambda ()
                (if session
                  (gerbil-ascent-session-replace-sources! session inputs
                    (lambda (result)
                      (set! report (make-report input image task raw names result next)) #t))
                  (begin
                    (set! session (gerbil-ascent-open-session (make-program inputs)))
                    (set! report (make-report input image task raw names (gerbil-ascent-session-run session) next))))
                (def delivery (owned GatewayDerivationResult report))
                (set! generation next)
                (set! last-input image)
                (set! last-report report)
                delivery)))
          (lambda () (set! busy? #f))))))
  (def (report-matches? request result)
    (require-owner!)
    ;; Full local query/result equality, not an authenticity/freshness receipt.
    (and last-input
         (equal? last-input (canonical GatewayDerivationRequest (owned GatewayDerivationRequest request)))
         (equal? (canonical GatewayDerivationResult last-report)
                 (canonical GatewayDerivationResult (owned GatewayDerivationResult result))) #t))
  (def (invalidate-derivation!)
    (require-owner!)
    (set! generation (next-generation))
    (set! session #f) (set! last-input #f) (set! last-report #f)
    #t)
  (def (close-derivation!)
    (require-owner!)
    (set! session #f) (set! last-input #f) (set! last-report #f)
    (set! closed? #t) #t)
  (seal-object!
    (validate GatewayDerivation
      (seal-object! (.o derive: derive-request matches?: report-matches?
                       invalidate: invalidate-derivation! close: close-derivation!)))))

(def (derive-gateway-source source-value)
  (def owner (make-gateway-derivation))
  (dynamic-wind void
    ;; The closed derive Function admits the request, then its implementation
    ;; detaches the source before retaining or evaluating it.
    (lambda () ((.get owner derive) (.o source: source-value dependencies: '() changed: '())))
    (lambda () ((.get owner close)))))
