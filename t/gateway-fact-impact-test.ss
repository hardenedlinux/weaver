;;; SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
;;;
;;; SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

(import :std/test
        (only-in :clan/poo/object .o .ref)
        (only-in :gerbil-ascent/program/session gerbil-ascent-open-session
                 gerbil-ascent-session-run gerbil-ascent-session-replace-sources!)
        (only-in ../scheme/gateway/program hard-fact-affected gateway-impact-program))
(export gateway-fact-impact-test)

(def gateway-fact-impact-test
  (test-suite "Gateway hard fact impact"
    (test-case "transitive impact terminates on cycles and excludes unrelated nodes"
      (check-equal?
        (hard-fact-affected
          (.o root: "root" dependencies: '(("direct" "root") ("transitive" "direct")
                                           ("root" "transitive") ("unrelated" "other"))))
        '("direct" "root" "transitive")))
    (test-case "the shared rule composes with a view and replaces its source cut"
      (def program
        (gateway-impact-program ('((2 1) (3 2)) '((1))) (8 8 16)
          (relation deployed (node) '((1) (3) (4)))
          (relation invalidated (node) '())
          (rule (invalidated ?n) (affected ?n) (deployed ?n))))
      (def session (gerbil-ascent-open-session program))
      (def (invalidated result)
        (check-equal? (.ref result 'finished) #t)
        (list-sort < (map car ((.ref result 'rows-of) 'invalidated))))
      (check-equal? (invalidated (gerbil-ascent-session-run session)) '(1 3))
      (check-equal? (invalidated (gerbil-ascent-session-replace-sources! session '((changed (4))))) '(4))
      (check-equal? (invalidated (gerbil-ascent-session-replace-sources! session '((changed (1))))) '(1 3)))))
