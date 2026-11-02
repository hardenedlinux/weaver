;;; POO owns deferred compiled-module loading; source discovery never runs C FFI.
(import (only-in :clan/poo/io module-action)
        (only-in :clan/poo/object .ref .all-slots .o)
        (only-in :clan/poo/mop validate)
        (only-in :agentic-ai-lab/modules/authorization/providers/cedar/objects agentic-ai-lab-cedar-policy?)
        "./types.ss"
        (only-in "./assets.ss" policy-document))
(export validate-source-policy! validate-policy-projection! project-policy)
(def cedar-validation
  (module-action "hardenedlinux/weaver/scheme/policy/cedar-ffi"
                 'hardenedlinux/weaver/scheme/policy/cedar-ffi#validate-source-policy!))
(def (validate-source-policy! policy-source schema-source)
  (cedar-validation (list policy-source schema-source)))

;;; Each named input is a complete Cedar policy set, never a syntax fragment.
;;; Reuse the admitted Rust validator; no second Cedar parser lives in Scheme.
(def (validate-policy-projection! projection schema-source validator)
  (validate PolicyProjection projection)
  (unless (<= (length (.ref projection 'inputs)) 64)
    (error "Governance policy inventory bound"))
  (for-each
    (lambda (document)
      (unless (validator (string-copy (.ref document 'source)) (string-copy schema-source))
        (error "Policy document preflight declined the source handoff" (.ref document 'identity))))
    (.ref projection 'inputs))
  (unless (validator (string-copy (.ref projection 'policy)) (string-copy schema-source))
    (error "Policy preflight declined the source handoff"))
  #t)

;;; Pure projection of Scheme Cedar values and already-read asset documents.
(def (project-policy profile expected asset-documents root-value)
  (def policies (.ref profile 'policies))
  (def names (.all-slots policies))
  (unless (<= (length names) 64) (error "Governance policy inventory bound"))
  (def inline
    (map (lambda (name)
           (let ((value (.ref policies name)))
             (unless (and (agentic-ai-lab-cedar-policy? value)
                          (eq? (.ref value 'runtime-executed?) #f))
               (error "unsupported Governance policy value"))
             (policy-document (.ref value 'identity) (.ref value 'source) ""))) names))
  (def (unique! documents)
    (let loop ((rest documents) (seen '()))
      (unless (null? rest)
        (let ((id (.ref (car rest) 'identity)))
          (when (member id seen) (error "duplicate Governance policy identity"))
          (loop (cdr rest) (cons id seen))))))
  (unique! inline)
  (unique! asset-documents)
  (when (and (pair? inline) (pair? asset-documents))
    (unless (and (= (length inline) (length asset-documents))
                 (andmap (lambda (document)
                           (ormap (lambda (asset)
                                    (and (equal? (.ref document 'identity) (.ref asset 'identity))
                                         (equal? (.ref document 'source) (.ref asset 'source))))
                                  asset-documents)) inline))
      (error "Governance policies and assets must match exactly")))
  (def documents
    (list-sort (lambda (left right) (string<? (.ref left 'identity) (.ref right 'identity)))
               (if (pair? asset-documents) asset-documents inline)))
  (def projected
    (if (null? documents) expected
      (let loop ((rest documents) (text ""))
        (if (null? rest) text
          (let ((next (string-append text (if (string=? text "") "" "\n") (.ref (car rest) 'source))))
            (unless (< (u8vector-length (string->utf8 next)) 65537)
              (error "Governance aggregate Policy byte bound"))
            (loop (cdr rest) next))))))
  (unless (equal? projected expected)
    (error "Governance projection differs from publication Policy"))
  (validate PolicyProjection (.o policy: projected inputs: documents root: root-value)))
