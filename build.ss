;;; Root package build. Yuanxu owns selection/guards; the SDK owns compilation.
(import (for-syntax
          (only-in :std/source this-source-file)
          (only-in :yuanxu/module-system/building/source-package register-module-build-source!)))
(begin-syntax
  (register-module-build-source! (path-directory (this-source-file)) 'hardenedlinux/weaver))
(import (only-in :clan/poo/object .get)
        (only-in :std/make pkg-config-cflags pkg-config-libs)
        (prefix-in (only-in :std/build-script defbuild-script) gerbil-build.)
        (only-in :agentic-ai-lab/build-spec agentic-ai-lab-build-spec)
        (only-in :yuanxu/module-system/building/source-closure package-library-spec)
        (only-in :std/source this-source-file)
        (only-in :yuanxu/module-system/building/script defbuild-script)
        (only-in "./init.ss" hardenedlinux/weaver.init.exports))

(def root (path-directory (this-source-file)))
(def policy-package (getenv "WEAVER_POLICY_PKG_CONFIG_PACKAGE" "weaver-policy-ffi"))
(def policy-ffi-spec
  `(gxc: "scheme/policy/cedar-ffi"
         "-cc-options" ,(pkg-config-cflags policy-package)
         "-ld-options" ,(pkg-config-libs policy-package)))
(def library-spec (list policy-ffi-spec))
(def modules-spec (.get hardenedlinux/weaver.init.exports std-make-spec))
(def package-main
  (let ()
    (defbuild-script (modules-spec library-spec))
    main))

;;; The upstream package owns both import-graph projection and FFI options.
;;; Its roots come from Weaver's selected native Make targets, not init metadata
;;; alone: init intentionally does not eagerly import its runtime scopes.
(def (main . arguments)
  (if (and (pair? arguments) (equal? (car arguments) "dependencies"))
    (let (source (getenv "WEAVER_SCHEME_AGENTIC_SOURCE"))
      ;; Publish the selected consumer metadata through its existing owner first.
      ;; Dependency graph projection can then import the lowered runtime roles.
      (package-main "compile")
      (def runtime-spec (modules-spec library-spec))
      (def consumer (path-expand "weaver-dependency-consumer.ss" (gerbil-path)))
      (def identities
        (map (lambda (entry)
               (let (target
                      (cond ((string? entry) entry)
                            ((and (pair? entry) (eq? (car entry) gxc:)) (cadr entry))
                            (else (error "selected runtime dependency root is not a Gerbil library" entry))))
                 (string->symbol (string-append ":hardenedlinux/weaver/" target))))
             runtime-spec))
      (call-with-output-file consumer
        (lambda (port)
          (display "prelude: :gerbil/core\n" port)
          ;; Retain actual runtime import edges without colliding public exports.
          (write (cons 'import
                   (let loop ((rest identities) (index 0))
                     (if (null? rest) '()
                       (cons (list 'prefix-in (car rest)
                               (string->symbol (string-append "dependency-" (number->string index) ".")))
                             (loop (cdr rest) (+ index 1)))))) port)
          (newline port)))
      ;; Match the upstream package's compiler-child heap envelope.
      (let (options (getenv "GAMBOPT" #f))
        (setenv "GAMBOPT" (string-append (if options (string-append options ",") "")
                                       "max-heap=2G,debug=q")))
      (parameterize ((current-directory source))
        (let* ((actual (package-library-spec source 'agentic-ai-lab (list consumer)))
               ;; Reuse upstream production admission and compiler/FFI options;
               ;; keep only targets reachable from the selected runtime roots.
               (declared (agentic-ai-lab-build-spec (list consumer)))
               (spec (filter (lambda (entry)
                               (member (if (string? entry) entry (cadr entry)) actual)) declared)))
          (unless (= (length actual) (length spec))
            (error "runtime dependency projection lost an upstream library target" actual spec))
          (displayln "Agentic AI Lab dependency library targets=" (length spec))
          (let ()
            (def (this-source-file) (path-expand "build.ss" source))
            (gerbil-build.defbuild-script spec)
            (apply main (cdr arguments))))))
    (apply package-main arguments)))
