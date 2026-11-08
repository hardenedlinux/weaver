;;; SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
;;;
;;; SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0
prelude: :gerbil/core

;;; Bootstrap before Yuanxu's prelude exists. Package metadata and installation
;;; stay with gxpkg; build.ss owns the selected ASCENT Program library.
(import (only-in :gerbil/tools/gxpkg pkg-plist pkg-link pkg-install)
        (only-in :gerbil/tools/env setup-local-pkg-env!)
        (only-in :std/misc/process run-process run-process/batch)
        (only-in :std/text/pregexp pregexp-match))
(export main dependency-pin)

(def (dependency-pin properties package)
  (def prefix (string-append package "@"))
  (def matches
    (filter (lambda (pin) (and (string? pin) (string-prefix? prefix pin)))
            (pgetq depend: properties '())))
  (unless (and (= (length matches) 1)
               (pregexp-match "^[0-9a-f]{40}$"
                 (substring (car matches) (string-length prefix)
                            (string-length (car matches)))))
    (error "expected one exact source revision in package dependencies" package matches))
  (car matches))

(def (phase! name)
  (displayln "Scheme preparation: " name)
  (when (getenv "GITHUB_OUTPUT" #f)
    (call-with-output-file (list path: (getenv "GITHUB_OUTPUT") append: #t)
      (lambda (port)
        (display (string-append "phase=" name "\n") port)))))

(def (fetch-source! properties package destination)
  (def pin (dependency-pin properties package))
  (def revision (substring pin (+ (string-length package) 1) (string-length pin)))
  (run-process/batch ["git" "init" "--quiet" destination])
  (run-process/batch ["git" "-C" destination "fetch" "--quiet" "--depth=1" "--no-tags"
                      (string-append "https://" package ".git") revision])
  (run-process/batch ["git" "-C" destination "checkout" "--quiet" "--detach" "FETCH_HEAD"])
  (unless (string=? (string-append revision "\n")
                     (run-process ["git" "-C" destination "rev-parse" "HEAD"]))
    (error "source checkout does not match declared revision" package revision))
  (pkg-link package destination))

(def (main . args)
  (unless (null? args) (error "usage: gxi prepare.ss" args))
  (setup-local-pkg-env! #t)
  (def root (path-expand "" (getenv "WEAVER_SCHEME_SOURCE_ROOT"
                              ".cache/verification/scheme-sources")))
  (def lab "github.com/tao3k/agentic-ai-lab")
  (def ascent "github.com/tao3k/gerbil-ascent")
  (create-directory* (path-expand "imports" root))
  (phase! "resolve-pins")
  (fetch-source! (pkg-plist ".") lab (path-expand "lab" root))
  (fetch-source! (pkg-plist lab) ascent (path-expand "imports/gerbil-ascent" root))
  (phase! "core-and-poo")
  (pkg-install (dependency-pin (pkg-plist ascent) "github.com/tao3k/gebril-yuanxu"))
  (setenv "GERBIL_LOADPATH"
    (string-append (path-expand "lib" (gerbil-path)) ":" (path-expand "imports" root)))
  (phase! "ascent-program")
  (run-process/batch ["gxi" "build.ss" "prepare-governor-library"]))
