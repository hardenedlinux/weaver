#!/usr/bin/env gxi
;;; SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
;;;
;;; SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

;;; Yuanxu owns module selection; Gerbil builds the FFI-loaded libraries.
(import (for-syntax
          (only-in :std/source this-source-file)
          (only-in :yuanxu/module-system/building/source-package register-module-build-source!)))
(begin-syntax
  (register-module-build-source! (path-directory (this-source-file)) 'hardenedlinux/weaver))
(import (only-in :clan/poo/object .get)
        (only-in :std/source this-source-file)
        (only-in :std/build-script defbuild-script)
        (only-in :gerbil/expander import-module expander-context-id)
        (only-in :gerbil/compiler compile-module)
        (only-in :yuanxu/module-system/building/interface call-with-init-build-spec)
        (only-in :yuanxu/module-system/building/products build-output-directory current-build-source-directory)
        (only-in :yuanxu/module-system/source/observations current-module-source-observer)
        (only-in "./init.ss" hardenedlinux/weaver.init.exports))

(export main)

(def (compile-package args)
  (def output (build-output-directory))
  (def entry (this-source-file))
  (def (dispatch spec native-args (prefix #f))
    (def (this-source-file)
      (let (directory (current-build-source-directory))
        (if directory (path-expand (path-strip-directory entry) directory) entry)))
    (defbuild-script spec libdir: output prefix: prefix)
    (apply main native-args))
  (call-with-init-build-spec
    (lambda () ((.get hardenedlinux/weaver.init.exports std-make-spec) '()))
    dispatch args output entry))

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
