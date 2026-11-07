;;; SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
;;;
;;; SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

;;; One owner-local approved source producer. This is a lifecycle contract,
;;; not a Governance DSL, module loader, publisher or execution authority.
(import (only-in :clan/poo/object .o .get .ref seal-object!)
        (only-in :clan/poo/mop validate)
        (only-in :std/list/list delete-duplicates/hash)
        (only-in :gerbil-ascent/program/scheme-language relational-program)
        (only-in :gerbil-ascent/program/session gerbil-ascent-open-session gerbil-ascent-session-run)
        (only-in "./types.ss" GatewayProgram)
        (only-in "./contracts.ss" GatewayArtifact)
        (only-in "./snapshot.ss" copy-source-data))
(export make-gateway-program hard-fact-affected gateway-impact-program)

(def (make-gateway-program)
  (let ((gate (make-mutex 'weaver-gateway-program))
        (phase 'uninstalled) (busy? #f) (producer #f))
    (def (locked operation)
      (dynamic-wind (lambda () (mutex-lock! gate)) operation (lambda () (mutex-unlock! gate))))
    (def (install-program! candidate)
      (locked
        (lambda ()
          ;; A duplicate cannot replace or retire a valid installed producer.
          (unless (eq? phase 'uninstalled) (error "Gateway program installation is sealed"))
          ;; The Function contract rejects invalid arguments before this body.
          ;; Once an admitted installation enters, internal failure is terminal.
          (set! phase 'closed)
          ;; GatewayProgram.install's Function contract already admitted and
          ;; wrapped this producer. Revalidating here would wrap every later
          ;; argument/result traversal a second time. Raw methods stay private.
          (set! producer candidate)
          (set! phase 'active)
          #t)))
    (def (close-program!)
      (locked (lambda () (set! phase 'closed) (set! producer #f) #t)))
    (def (capture-source original)
      (let* ((input (copy-source-data (validate GatewayArtifact original)))
             (selected
              (locked
                (lambda ()
                  (unless (eq? phase 'active) (error "Gateway program is not active"))
                  (when busy?
                    ;; A caught reentry must not let the outer call promote data.
                    (set! phase 'closed)
                    (set! producer #f)
                    (error "Gateway program capture is active"))
                  (set! busy? #t)
                  producer))))
        ;; Do not retain the lifecycle lock across approved application code.
        ;; Close fences delivery but cannot acknowledge natural call/VM cleanup.
        (dynamic-wind
          void
          (lambda ()
            ;; The approved producer performs its existing scoped capture and
            ;; returns one typed Record. An ambient sink outside the admitted
            ;; Yuanxu scope need not share that scope's parameter identity.
            (let ((result (copy-source-data (validate GatewayArtifact (selected input)))))
              (locked
                (lambda ()
                  (unless (eq? phase 'active) (error "Gateway program closed during capture"))
                  result))))
          (lambda () (locked (lambda () (set! busy? #f)))))))
    (seal-object!
      (validate GatewayProgram
        (seal-object! (.o install: install-program! capture: capture-source close: close-program!))))))

;;; Expand shared clauses into one ASCENT program. Each consumer supplies its
;;; own admitted rows, limits and optional views over the impact relation.
(defrules gateway-impact-program ()
  ((_ (edges seeds) (input-bound derived-bound output-bound) clause ...)
   (relational-program
     (relation depends (dependent dependency) edges)
     (relation changed (subject) seeds)
     (relation affected (subject) '())
     (rule (affected ?s) (changed ?s))
     (rule (affected ?d) (depends ?d ?s) (affected ?s))
     clause ...
     (limits input-bound derived-bound output-bound))))

;;; The Rust ledger supplies the detached graph after persisting the intent.
;;; Dense IDs keep external names out of the evaluator's atom space.
(def (hard-fact-affected cut)
  (def root (.get cut root))
  (def dependencies (.get cut dependencies))
  (unless (<= (length dependencies) 64) (error "Hard fact dependency bound"))
  (def names (list->vector (list-sort string<?
    (delete-duplicates/hash (cons root (apply append dependencies))))))
  (def ids (make-hash-table))
  (for-each (lambda (index) (hash-put! ids (vector-ref names index) index))
    (iota (vector-length names)))
  (def changed (list (list (hash-ref ids root))))
  (def edges (map (lambda (edge) (map (lambda (name) (hash-ref ids name)) edge)) dependencies))
  (def program (gateway-impact-program (edges changed) (65 65 130)))
  (def result (gerbil-ascent-session-run (gerbil-ascent-open-session program)))
  (unless (eq? (.ref result 'finished) #t) (error "Hard fact derivation incomplete"))
  (list-sort string<?
    (map (lambda (row) (vector-ref names (car row))) ((.ref result 'rows-of) 'affected))))
