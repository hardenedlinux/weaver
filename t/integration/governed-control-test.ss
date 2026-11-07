;;; SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
;;;
;;; SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

;;; Actual AA semantic failures belong to the standard Scheme suite.
(import :std/test
        (only-in :std/source this-source-file)
        (only-in :std/error Error? Error-message)
        (only-in :std/io/tempfile call-with-temporary-directory)
        (only-in :yuanxu/module-system/interface yuanxu-load-modules)
        (only-in :yuanxu/module-system/source/admission call-with-module-source-read-cache)
        (only-in :std/misc/ports read-all-as-string)
        (only-in :clan/poo/object .o .get)
        (only-in :clan/poo/mop TypeError?)
        (only-in "../fixtures/control-inputs.ss" control-inputs)
        (only-in "../fixtures/governed-control.ss" capture-control-fixture prepare-control-fixture))
(export governed-control-test)

(def refusal-cases
  '(("deny" . "provider plans must exactly match the Governor source handoff")
    ("collision" . "provider plans must exactly match the Governor source handoff")
    ("clip" . "provider plans must exactly match the Governor source handoff")
    ("invalid" . "provider plans must exactly match the Governor source handoff")
    ("policy" . "Rust rejected inert source Policy/schema")
    ("threat" . "Scheme Governance assessment does not admit an inert source handoff")
    ("obligation" . "unsupported Governance policy value")
    ("duplicate-plan" . "provider plans must exactly match the Governor source handoff")
    ("assessment-context" . "Scheme Governance assessment does not admit an inert source handoff")
    ("assessment-revision" . "Scheme Governance assessment does not admit an inert source handoff")
    ("assessment-model" . "Scheme Governance assessment does not admit an inert source handoff")
    ("assessment-threats" . "Scheme Governance assessment does not admit an inert source handoff")
    ("assessment-profile-mutation" . "Governance source changed during assessment")
    ("capture-assessment-profile-mutation" . "Governance source changed during assessment")
    ("asset-mismatch" . "Governance policies and assets must match exactly")
    ("asset-traversal" . "Governance asset path must stay inside its root")
    ("asset-language" . "unsupported Governance asset language")
    ("policy-substitution" . "Governance policies and assets must match exactly")
    ("policy-identity" . "Governance policies and assets must match exactly")))

(def governed-control-test
  (test-suite "Actual AA source admission"
    (test-case "semantic failures reject without producing a captured artifact"
      (def schema
        (call-with-input-file
          (path-expand "../../prod/policies/provider/schema.json" (path-directory (this-source-file)))
          read-all-as-string))
      (def input (control-inputs schema "permit(principal,action,resource);"))
      (def init (path-expand "../../init.ss" (path-directory (this-source-file))))
      (call-with-temporary-directory "weaver-control-"
        (lambda (directory)
          (def (invoke mode)
            (def original-task (car (.get input tasks)))
            (def original-publication (.get input publication))
            (def task (if (equal? mode "task-type")
                        (.o (:: @ original-task) budget: "8") original-task))
            (def plans (if (equal? mode "duplicate-plan")
                         (list (car (.get input plans)) (car (.get input plans)))
                         (.get input plans)))
            (def publication (if (equal? mode "policy")
                               (.o (:: @ original-publication) policy: "not a Cedar policy")
                               original-publication))
            (call-with-output-file (path-expand "policy.cedar" directory)
              (lambda (port)
                (display (if (equal? mode "asset-mismatch")
                           "forbid(principal,action,resource);" (.get publication policy)) port)))
            (capture-control-fixture init mode (list task) plans publication directory))
          ;; Only framework Scheme sources are fixed within this inert batch.
          ;; Profile data and Policy assets still vary and are read per case.
          ;; Independent currentness guards bracket the upstream read window.
          (def view (yuanxu-load-modules init))
          ((.get view admit-current))
          (dynamic-wind
            void
            (lambda ()
              (call-with-module-source-read-cache
                (lambda ()
                  (for-each
                    (lambda (row)
                      (def result
                        (with-catch
                          (lambda (failure) (if (Error? failure) (Error-message failure) (raise failure)))
                          (lambda () (invoke (car row)) #f)))
                      (check-equal? (list (car row) (and (string? result) (string-prefix? (cdr row) result)))
                                    (list (car row) #t)))
                    refusal-cases)
                  (check-exception (invoke "task-type") TypeError?)
                  ;; Refusal must not poison a subsequent legitimate capture on this VM.
                  (def valid (invoke "valid"))
                  (check-equal? (.get valid governance open_nodes) '("infer" "next"))
                  (check-equal? (.get (car (.get input tasks)) budget) 8)
                  ;; Preparation and source capture use the same declared
                  ;; semantic producer, while evidence stays outside wire data.
                  (def prepared (prepare-control-fixture init "valid" (.get input tasks) (.get input plans)
                                                        (.get input publication) directory))
                  (check-equal? (.get prepared source governance open_nodes) '("infer" "next"))
                  (check-equal? (.get prepared derivation complete) #t)
                  (check-equal? (.get prepared derivation execution_authorized) #f)
                  (check-equal? (length (.get prepared derivation candidates)) 4)
                  (def gateway (.get view modules Weaver gateway))
                  (def advice ((.get gateway derive) (.get prepared source)))
                  (check-equal? (.get advice request_digest) (.get prepared derivation request_digest))
                  (def owner ((.get gateway open-derivation)))
                  (def query (.o source: (.get prepared source) dependencies: '() changed: '()))
                  (def retained ((.get owner derive) query))
                  (check-equal? ((.get owner matches?) query retained) #t)
                  ((.get owner close))
                  #t)))
            (lambda () ((.get view admit-current))))
          directory)))))
