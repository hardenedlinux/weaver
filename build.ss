#!/usr/bin/env gxi
;;; Yuanxu owns module selection; Gerbil builds the FFI-loaded libraries.
(import (for-syntax
          (only-in :std/source this-source-file)
          (only-in :yuanxu/module-system/building/source-package register-module-build-source!)))
(begin-syntax
  (register-module-build-source! (path-directory (this-source-file)) 'hardenedlinux/weaver))
(import (only-in :clan/poo/object .get)
        (only-in :std/make pkg-config-cflags pkg-config-libs)
        (only-in :gerbil/expander import-module expander-context-id)
        (only-in :gerbil/compiler compile-module)
        (only-in :yuanxu/module-system/building/script defbuild-script)
        (only-in "./init.ss" hardenedlinux/weaver.init.exports))

(def policy-package (getenv "WEAVER_POLICY_PKG_CONFIG_PACKAGE" "weaver-policy-ffi"))
(def (package-spec (extra '()))
  ((.get hardenedlinux/weaver.init.exports std-make-spec)
   (append (list `(gxc: "scheme/policy/cedar-ffi"
                "-cc-options" ,(pkg-config-cflags policy-package)
                "-ld-options" ,(pkg-config-libs policy-package))
         ;; Cross-language fixtures are libraries too: the standard package build
         ;; owns their expansion instead of repeating it during each bootstrap.
         '(gxc: "t/fixtures/governed-control")
         '(gxc: "t/fixtures/control-inputs")) extra)))

;; The native SDK invokes this same package entry with typed arguments.
;; Compilation stays in the package declaration; no Rust-generated Scheme code.
(def (main . args)
  (match args
    (["program" source expected-module]
     (let ()
       (defbuild-script
         (package-spec (list '(gxc: "scheme/gateway/compiled")))
         force: #t)
       (main "compile"))
     ;; The explicit operator application may live in a different source package.
     ;; It is compiled as that source, never relabeled as a Weaver retained module.
     (compile-module source [output-dir: (path-expand "lib" (gerbil-path))
                             invoke-gsc: #f optimize: #t static: #t])
     (unless (equal? (symbol->string (expander-context-id (import-module source)))
                     expected-module)
       (error "approved application root mismatch")))
    (else
     (let ()
       (defbuild-script (package-spec))
       (apply main args)))))
