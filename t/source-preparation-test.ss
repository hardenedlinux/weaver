;;; SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
;;;
;;; SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0
prelude: :gerbil/core
(import :std/test (only-in "../dev/prepare-scheme.ss" dependency-pin))
(export source-preparation-test)

(def source-preparation-test
  (test-suite "Native package source selection"
    (def package "github.com/tao3k/source")
    (def pin (string-append package "@0123456789abcdef0123456789abcdef01234567"))
    (test-case "accept the sole exact declared revision"
      (check-equal? (dependency-pin [depend: ["github.com/other/source@main" pin]] package) pin))
    (test-case "reject absent, duplicate, mutable and malformed source revisions"
      (for-each
        (lambda (dependencies)
          (check-exception (dependency-pin [depend: dependencies] package) error?))
        [[] [pin pin] [(string-append package "@main")]
         [(string-append package "@0123456789abcdef")]
         [(string-append package "@0123456789abcdef0123456789abcdef0123456g")]]))))
