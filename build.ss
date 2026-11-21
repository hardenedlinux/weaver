#!/usr/bin/env gxi
;;; SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
;;;
;;; SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

;;; The init projection owns module selection and compiler input admission.
(import (only-in :clan/poo/object .call .get)
        (only-in :std/source this-source-file)
        (only-in :std/build-script defbuild-script)
        (only-in :tao3k/yuanxu/module-system/building/products build-output-directory)
        (only-in :tao3k/yuanxu/module-system/building/source-package call-with-build-input-path)
        (only-in :gerbil/expander import-module expander-context-id)
        (only-in :gerbil/compiler compile-module)
        (only-in :tao3k/yuanxu/module-system/source/observations current-module-source-observer)
        (only-in "./scheme/c-abi/build.ss" Build)
        (only-in "./init.ss" hardenedlinux/weaver.init.exports std-make-spec))

(export main)

(def (run-standard-build targets root args)
  ;; STD owns argument parsing and Make dispatch. The admitted source view is
  ;; the native source directory; it must not be reconstructed by this package.
  (def (this-source-file) (path-expand "build.ss" root))
  (defbuild-script targets libdir: (build-output-directory))
  (apply main args))

(def (compile-package args)
  (match args
    ([] (compile-package '("compile")))
    (["compile" . _]
     ;; The init owner supplies the admitted cross-package source view and
     ;; guards Make's input path and outputs for the entire native dispatch.
     (.call hardenedlinux/weaver.init.exports .compile-selection '() '(Lab Weaver)
       (lambda (targets root) (run-standard-build targets root args))))
    (["clean"]
     (.call hardenedlinux/weaver.init.exports .clean-selection '() '(Lab Weaver)
       (lambda (targets root) (run-standard-build targets root args))))
    (else
     (let ()
       (defbuild-script std-make-spec libdir: (build-output-directory))
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

(def (dispatch . args)
  (match args
    (["compile-approved-program" source expected-module]
     ;; An operator can approve a source in a different package.
     (compile-module source [output-dir: (path-expand "lib" (gerbil-path))
                             invoke-gsc: #f optimize: #t static: #t])
     (unless (equal? (symbol->string (expander-context-id (import-module source)))
                     expected-module)
       (error "approved application root mismatch")))
    (["compile" . _]
     (if (getenv "CARGO_FEATURE_SCHEME_PROGRAM" #f)
       (compile-package-for-cargo args)
       (compile-package args)))
    (else (compile-package args))))

;;; Core publishes the compiler loader plan and its activation metadata.
(def (main . args)
  ;; Admit this package before preparing that plan, including the first build
  ;; where no installed Weaver interface can supply its public identity.
  (call-with-build-input-path (build-output-directory)
    (lambda ()
      (apply (.call hardenedlinux/weaver.init.exports .with-link (.get Build with-link) dispatch)
             args))
    source-roots: (list (path-directory (this-source-file)))))
