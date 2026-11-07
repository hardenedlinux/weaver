;;; SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
;;;
;;; SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

(import :std/test
        (only-in :clan/poo/object .o)
        (only-in ../scheme/gateway/program hard-fact-affected))
(export gateway-fact-impact-test)

(def gateway-fact-impact-test
  (test-suite "Gateway hard fact impact"
    (test-case "transitive impact terminates on cycles and excludes unrelated nodes"
      (check-equal?
        (hard-fact-affected
          (.o root: "root" dependencies: '(("direct" "root") ("transitive" "direct")
                                           ("root" "transitive") ("unrelated" "other"))))
        '("direct" "root" "transitive")))))
