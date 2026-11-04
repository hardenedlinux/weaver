;;; SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
;;;
;;; SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

;;; One owner-local approved source producer. This is a lifecycle contract,
;;; not a Governance DSL, module loader, publisher or execution authority.
(import (only-in :clan/poo/object .o seal-object!)
        (only-in :clan/poo/mop validate)
        (only-in "./types.ss" GatewayProgram)
        (only-in "./contracts.ss" GatewayArtifact)
        (only-in "./snapshot.ss" copy-source-data))
(export make-gateway-program)

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
