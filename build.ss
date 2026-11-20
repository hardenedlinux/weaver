#!/usr/bin/env gxi
;;; SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
;;;
;;; SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

;;; The init projection owns module selection and compiler input admission.
(import (only-in :clan/poo/object .get .call)
        (only-in :std/source this-source-file)
        (only-in :std/build-script defbuild-script)
        (only-in :std/make make make-clean)
        (only-in :gerbil/expander import-module expander-context-id)
        (only-in :gerbil/compiler compile-module)
        (only-in :tao3k/yuanxu/module-system/source/observations current-module-source-observer)
        (only-in "./init.ss" hardenedlinux/weaver.init.exports))

(export main)

(def (build-options flags)
  (foldr (lambda (flag options)
           (match flag
             ("--release" (cons* build-release: #t options))
             ("--optimized" (cons* build-optimized: #t options))
             ("--debug" (cons* debug: #t options))
             (else (error "Unexpected build option" flag))))
         '() flags))

(def (compile-package args)
  (match args
    ([] (compile-package '("compile")))
    (["compile" . flags]
     ;; The init owner supplies the admitted cross-package source view and
     ;; guards Make's input path and outputs for the entire native dispatch.
     (.call hardenedlinux/weaver.init.exports .compile-selection '() '(Lab Weaver)
       (lambda (targets root) (apply make targets srcdir: root (build-options flags)))))
    (["clean"]
     (.call hardenedlinux/weaver.init.exports .clean-selection '() '(Lab Weaver)
       (lambda (targets root) (make-clean targets srcdir: root))))
    (else
     (let ()
       (defbuild-script (.get hardenedlinux/weaver.init.exports std-make-spec))
       (apply main args)))))

;; Cargo needs the inputs already read by the package owner to invalidate its
;; build script. Files created under OUT_DIR are products of the same build.
(def (compile-package-for-cargo args)
  (def outputs (path-expand "" (getenv "OUT_DIR")))
  (def inputs (make-hash-table))
  (def (observe key _)
    (match key
      (['file-read _ path]
       (unless (string-prefix? outputs path)
         (hash-put! inputs path #t)))
      (else (void))))
  (begin0
    (parameterize ((current-module-source-observer observe))
      (compile-package args))
    (hash-for-each
      (lambda (path _)
        (when (file-exists? path)
          (displayln "cargo:rerun-if-changed=" path)))
      inputs)))

(def (main . args)
  (match args
    (["compile-approved-program" source expected-module]
     ;; An operator can approve a source in a different package.
     (compile-module source [output-dir: (path-expand "lib" (gerbil-path))
                             invoke-gsc: #f optimize: #t static: #t])
     (unless (equal? (symbol->string (expander-context-id (import-module source)))
                     expected-module)
       (error "approved application root mismatch")))
    (["compile"]
     (if (getenv "CARGO_FEATURE_SCHEME_PROGRAM" #f)
       (compile-package-for-cargo args)
       (compile-package args)))
    (else (compile-package args))))
