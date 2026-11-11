;;; SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
;;; SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0
(import :std/test
        (only-in :clan/poo/object .get .cc .o)
        (only-in :std/source this-source-file)
        (only-in :std/io/tempfile call-with-temporary-directory)
        (only-in :std/misc/ports read-all-as-u8vector)
        (only-in :std/crypto/digest sha256)
        (only-in :gerbil/tools/gxpkg pkg-root-dir)
        (only-in :yuanxu/ops/interface Ops)
        (only-in :yuanxu/ops/func run-script)
        (only-in :yuanxu/ops/progress execution-progress!)
        (only-in :yuanxu/observability/testing-script make-compiler-progress-reader)
        (only-in :yuanxu/module-system/building/products artifact-files current-build-output-directory)
        (only-in :yuanxu/module-system/source/admission module-source-read call-with-module-source-operation-measurement)
        (only-in "../../../init.ss" hardenedlinux/weaver.init.exports)
        (rename-in (only-in "../../../build.ss" main) (main weaver-build-main)))
(export module-selection-test)
(def (compile-events output)
  (call-with-input-string output
    (lambda (port)
      (let loop ((events '()))
        (let (line (read-line port))
          (cond ((eof-object? line) (list-sort string<? events))
                ((string-prefix? "... compile " line)
                 (loop (cons (substring line 12 (string-length line)) events)))
                (else (loop events))))))))
(def (interfaces directory (prefix ""))
  (list-sort string<?
    (foldl (lambda (name found)
             (let ((path (path-expand name directory)) (id (string-append prefix name)))
               (cond ((eq? (file-info-type (file-info path)) 'directory)
                      (append (interfaces path (string-append id "/")) found))
                     ((string-suffix? ".ssi" name) (cons (path-strip-extension id) found))
                     (else found)))) '() (directory-files directory))))
(def (digests files)
  (map (lambda (path) (cons path (sha256 (call-with-input-file path read-all-as-u8vector)))) files))
(def module-selection-test
  (test-suite "Actual Weaver selects Lab dependencies and owns its products"
    (test-case "native root identities and cold/hot A/B build isolation"
      (def root (path-normalize (path-expand "../../.." (path-directory (this-source-file)))))
      (def provider (path-normalize (path-expand "github.com/tao3k/agentic-ai-lab" (pkg-root-dir))))
      (def prerequisites (load-path))
      (def runtime-options (getenv "GAMBOPT"))
      (defvalues (spec counts)
        (call-with-module-source-operation-measurement
          (lambda () (call-with-output-string
            (lambda (out) (parameterize ((current-output-port out) (current-directory root))
                            (weaver-build-main "spec"))))) accounting?: #f))
      (check-equal? (hash-ref counts '(calls scope-factory) 0) 0)
      (check-equal? (hash-ref counts '(calls candidate-read) 0) 4)
      (def targets (list-sort string<? (map cadr (call-with-input-string spec read))))
      (check-equal? (length targets) 40)
      (for-each (lambda (target) (check-equal? (and (member target targets) #t) #t))
        '("agentic-ai-lab/modules/governance/interface"
          "hardenedlinux/weaver/scheme/governance/interface"
          "hardenedlinux/weaver/scheme/policy/interface"
          "hardenedlinux/weaver/scheme/gateway/interface"
          "hardenedlinux/weaver/scheme/policy/cedar-ffi"))
      ;; Exact foreign targets: one selected owner plus the native libraries
      ;; its consumer imports. A missing dependency and an unrelated Lab
      ;; module are both failures, even if Make agrees with the spec.
      (check-equal?
        (filter (cut string-prefix? "agentic-ai-lab/" <>) targets)
        (map (cut string-append "agentic-ai-lab/modules/" <>)
          '("authorization/providers/cedar/objects"
            "governance/config"
            "governance/funs"
            "governance/interface"
            "governance/objects"
            "governance/types"
            "loop-engine/control/descriptor"
            "loop-engine/control/governor"
            "loop-engine/control/governor-core"
            "loop-engine/control/governor-core-slot-rows"
            "loop-engine/control/governor-policy"
            "loop-engine/control/governor-policy-sets"
            "loop-engine/control/strategy"
            "session/objects-core")))
      (def identities (map string->symbol targets))
      (def (prerequisite-products)
        (foldr append '() (map (lambda (directory) (artifact-files identities directory #f)) prerequisites)))
      (def installed-before (digests (prerequisite-products)))
      (displayln "WEAVER-MODULE-SPEC targets=" (length targets) " scopes=0")
      (def sources
        (append (list (path-expand "init.ss" root) (path-expand "init.ss" provider))
          (map (lambda (target)
                 (let* ((local? (string-prefix? "hardenedlinux/weaver/" target))
                        (prefix (if local? "hardenedlinux/weaver/" "agentic-ai-lab/")))
                   (path-expand (string-append (substring target (string-length prefix) (string-length target)) ".ss")
                                (if local? root provider)))) targets)))
      (def source-before (map module-source-read sources))
      (execution-progress! 'weaver-specification 1)
      (call-with-temporary-directory "weaver-selected-"
        (lambda (temporary)
          (def a (path-expand "a" temporary)) (def b (path-expand "b" temporary))
          (for-each (lambda (state) (create-directory* (path-expand "lib" state))) (list a b))
          (def completed 0)
          (def (action state command)
            (displayln "WEAVER-MODULE-ACTION environment=" (path-strip-directory state) " command=" command)
            (force-output)
            (def result
              (run-script
                (.cc (.get Ops prototypes Script) command: command directory: root
                  timeout: 120 idle-timeout: 60 progress: make-compiler-progress-reader
                  environment: (.o GERBIL_PATH: state GAMBOPT: runtime-options GERBIL_BUILD_VERBOSE: "1"
                    GERBIL_LOADPATH: (string-join (cons (path-expand "lib" state) prerequisites) ":")))
                '() output-port: (current-error-port)))
            (set! completed (1+ completed)) (execution-progress! 'weaver-actions completed)
            (def output (.get result output))
            (when (ormap (cut string-contains output <>)
                         '("*** ERROR" "ERROR CASE" "ERROR CHECK" "ERROR HARNESS" "Heap overflow" "Stack overflow"))
              (error "Weaver action reported failure" command))
            output)
          (def (build-in-state state command)
            ;; Reuse the guarded init plan. The Build entry still admits the
            ;; sources and checks its native products on each invocation.
            (def output
              (call-with-output-string
                (lambda (port)
                  (parameterize ((current-build-output-directory (path-expand "lib" state))
                                 (current-output-port port)
                                 (current-directory root))
                    (weaver-build-main command)))))
            (display output)
            (force-output)
            output)
          (for-each
            (lambda (state)
              (action state (list "gerbil" "pkg" "link" "github.com/tao3k/agentic-ai-lab" provider))
              (def library (path-expand "lib" state))
              (check-equal? (interfaces library) '())
              (check-equal? (compile-events (if (equal? state a)
                                             (action state '("gxi" "build.ss" "compile"))
                                             (build-in-state state "compile"))) targets)
              (check-equal? (interfaces library) targets)) (list a b))
          (def b-lib (path-expand "lib" b))
          (def b-products (digests (artifact-files identities b-lib)))
          (def sentinel (path-expand "lib/unrelated.ssi" a))
          (call-with-output-file sentinel (lambda (port) (display "unrelated" port)))
          (build-in-state a "clean")
          (check-equal? (interfaces (path-expand "lib" a)) '("unrelated"))
          (check-equal? (digests (artifact-files identities b-lib)) b-products)
          (check-equal? (compile-events (build-in-state b "compile")) '())
          (check-equal? (digests (artifact-files identities b-lib)) b-products)
          (def output (action b '("gxi" "t/qualification/module-selection/use.ss")))
          (check-equal? (and (string-contains output "WEAVER-MODULE-USE-OK") #t) #t)
          (check-equal? (map module-source-read sources) source-before)
          (check-equal? (digests (prerequisite-products)) installed-before)
          (displayln "WEAVER-MODULE-SELECTION-OK targets=" (length targets)
                     " roots=Lab/Weaver selected=4 scopes-before-build=0 cold=A/B hot=0 clean-isolation=ok source=unchanged"))))))
