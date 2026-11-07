;;; SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
;;;
;;; SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

(import :std/test
        (only-in :clan/poo/object .o)
        (only-in "../scheme/gateway/func.ss" governor-ready-steps make-retained-governor))
(export gateway-governor-retained-test)

(def graph-nodes '("infer" "gate" "next" "side" "fork-a" "fork-b" "inner-finish" "outer-skip" "finish"))
(def graph-edges
  '(("finish" "inner-finish") ("finish" "outer-skip") ("fork-a" "side") ("fork-b" "side")
    ("gate" "infer") ("inner-finish" "fork-a") ("inner-finish" "fork-b")
    ("inner-finish" "next") ("next" "gate") ("outer-skip" "infer") ("side" "gate")))
(def selectors '(("gate" "next" "side") ("infer" "gate" "outer-skip")))
(def left-right '(("infer" "left") ("gate" "right")))

(def (cut released waiting observations selected (eligible graph-nodes))
  (.o nodes: graph-nodes edges: graph-edges complete: released
      available: eligible pending: waiting nested_selectors: selectors
      nested_results: observations nested_decisions: selected))

(def gateway-governor-retained-test
  (test-suite "Retained Governor cut equivalence"
    (test-case "nested selectors, parallel completion, withdrawal and ABA"
      (def derive (make-retained-governor))
      (def outer-left (cut '("infer") '("gate" "outer-skip") '(("infer" "left")) '()))
      (def unavailable
        (cut '("infer") '("gate" "outer-skip") '(("infer" "left")) '() '("gate" "outer-skip")))
      (def trials
        (list
          (cons outer-left '("gate"))
          (cons unavailable '())
          (cons outer-left '("gate"))
          (cons outer-left '("gate"))
          (cons (cut '("infer") '("gate" "outer-skip") '(("infer" "right")) '()) '("outer-skip"))
          (cons (cut '("infer" "gate") '("side" "next") left-right '(("infer" "left"))) '("side"))
          (cons (cut '("infer" "gate" "side") '("fork-a" "fork-b" "inner-finish") left-right left-right)
                '("fork-a" "fork-b"))
          (cons (cut '("infer" "gate" "side" "fork-a") '("fork-b" "inner-finish") left-right left-right)
                '("fork-b"))
          (cons (cut '("infer" "gate" "side" "fork-a" "fork-b") '("inner-finish" "finish") left-right left-right)
                '("inner-finish"))
          (cons (cut '("infer" "gate" "side" "fork-a" "fork-b" "inner-finish") '("finish") left-right left-right)
                '("finish"))))
      (for-each
        (lambda (trial)
          (def expected (cdr trial))
          (def fresh (list-sort string<? (governor-ready-steps (car trial))))
          (check-equal? fresh expected)
          (check-equal? (list-sort string<? (derive (car trial))) expected))
        trials))
    (test-case "topology replacement and a fresh owner"
      (def derive (make-retained-governor))
      (def nested (cut '("infer") '("gate" "outer-skip") '(("infer" "right")) '()))
      (def linear
        (.o nodes: '("infer" "next") edges: '(("next" "infer"))
            complete: '("infer") pending: '("next") available: '("infer" "next")))
      (check-equal? (derive nested) '("outer-skip"))
      (check-equal? (derive linear) '("next"))
      (check-equal? (derive nested) '("outer-skip"))
      (check-equal? ((make-retained-governor) nested) (governor-ready-steps nested)))))
