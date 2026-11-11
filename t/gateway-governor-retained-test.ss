;;; SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
;;;
;;; SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

(import :std/test
        (only-in :std/error Error? Error-message)
        (only-in :clan/poo/object .o)
        (prefix-in :clan/poo/testing/property/generator generator.)
        (prefix-in :clan/poo/testing/property property.)
        (only-in :clan/poo/testing/property/test check-property)
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
    (test-case "prepared nested rules agree with full fresh snapshots under replacement"
      (def snapshots
        (list
          (cut '("infer") '("gate" "outer-skip") '(("infer" "left")) '())
          (cut '("infer") '("gate" "outer-skip") '(("infer" "right")) '())
          (cut '("infer" "gate") '("side" "next") left-right '(("infer" "left")))
          (cut '("infer" "gate" "side") '("fork-a" "fork-b" "inner-finish") left-right left-right)
          (cut '("infer" "gate" "side" "fork-a") '("fork-b" "inner-finish") left-right left-right)
          (cut '("infer" "gate" "side" "fork-a" "fork-b") '("inner-finish" "finish") left-right left-right)
          (cut '("infer" "gate" "side" "fork-a" "fork-b" "inner-finish") '("finish") left-right left-right)
          (cut '("infer" "gate" "side" "fork-a" "fork-b") '("inner-finish" "finish") left-right left-right
               (filter (lambda (node) (not (equal? node "fork-b"))) graph-nodes))))
      ;; Open the unchanged full fresh program once per snapshot. Generated
      ;; sequences exercise deletion, restoration and replacement in one owner.
      (def expected (map (lambda (value) (list-sort string<? (governor-ready-steps value))) snapshots))
      (def report
        (property.check-property
          (generator.generator-sequence (make-list 8 (generator.generator-integer 0 7)))
          (lambda (commands)
            (def derive (make-retained-governor #t))
            (andmap
              (lambda (command)
                (equal? (list-sort string<? (derive (list-ref snapshots command)))
                        (list-ref expected command))) commands))
          (property.make-specification
            (lambda (commands) (and (list? commands) (= (length commands) 8)
                                   (andmap (lambda (n) (and (exact-integer? n) (<= 0 n 7))) commands)))
            (lambda (commands) (apply + commands)))
          seed: 293 cases: 32 size: 32 shrink-budget: 64))
      (check-property report)
      (check-equal? (property.report-accepted report) 32))
    (test-case "prepared nested rules preserve source budget rejection and recovery"
      (def derive (make-retained-governor #t))
      (def valid (cut '("infer") '("gate") '(("infer" "left")) '()))
      (def excessive (cut (make-list 641 "infer") '("gate") '(("infer" "left")) '()))
      (def (failure action)
        (with-catch
          (lambda (exception) (if (Error? exception) (Error-message exception) (raise exception)))
          (lambda () (action) #f)))
      (check-equal? (derive valid) '("gate"))
      (def fresh-failure (failure (lambda () (governor-ready-steps excessive))))
      (def retained-failure (failure (lambda () (derive excessive))))
      (check-equal? (string? fresh-failure) #t)
      (check-equal? retained-failure fresh-failure)
      (check-equal? (derive valid) '("gate")))
    (test-case "nested selectors, parallel completion, withdrawal and ABA"
      (def derive (make-retained-governor #f))
      (def derive-changed (make-retained-governor #t))
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
          (check-equal? (list-sort string<? (derive (car trial))) expected)
          (check-equal? (list-sort string<? (derive-changed (car trial))) expected))
        trials))
    (test-case "topology replacement and a fresh owner"
      (def derive (make-retained-governor #t))
      (def nested (cut '("infer") '("gate" "outer-skip") '(("infer" "right")) '()))
      (def linear
        (.o nodes: '("infer" "next") edges: '(("next" "infer"))
            complete: '("infer") pending: '("next") available: '("infer" "next")))
      (check-equal? (derive nested) '("outer-skip"))
      (check-equal? (derive linear) '("next"))
      (check-equal? (derive nested) '("outer-skip"))
      (check-equal? ((make-retained-governor) nested) (governor-ready-steps nested)))
    (test-case "a compact cut must name the current binding"
      (def derive (make-retained-governor #t))
      (def (full binding)
        (.o topology_binding: binding nodes: '("root" "next") edges: '(("next" "root"))
            complete: '("root") pending: '("next") available: '("root" "next")))
      (def (compact binding)
        (.o topology_binding: binding complete: '("root")
            pending: '("next") available: '("root" "next")))
      (def (missing-binding? failure)
        (and (Error? failure) (equal? (Error-message failure) "Governor topology binding unavailable")))
      (check-exception (derive (compact 1)) missing-binding?)
      (check-equal? (derive (full 1)) '("next"))
      (check-equal? (derive (compact 1)) '("next"))
      (check-equal? (derive (full 2)) '("next"))
      (check-exception (derive (compact 1)) missing-binding?)
      (check-exception (derive (compact 2)) missing-binding?)
      (check-equal? (derive (full 3)) '("next"))
      (check-equal? (derive (compact 3)) '("next"))
      (def (indexed binding)
        (.o topology_binding: binding indexed_result: 1 complete: '("root")
            pending: '("next") available: '("root" "next")))
      (check-equal? (derive (indexed 3)) '(3 1))
      (check-exception (derive (indexed 2)) missing-binding?)
      (check-exception (derive (indexed 3)) missing-binding?))
    (test-case "packed facts are complete and bounded by the live binding"
      (def derive (make-retained-governor #t))
      (def bound
        (.o topology_binding: 9 indexed_result: 1 nodes: '("root" "next")
            edges: '(("next" "root")) complete: '() available: '() pending: '()))
      (def current (.o topology_binding: 9 indexed_result: 1))
      (def (foreign? failure)
        (and (Error? failure) (equal? (Error-message failure) "Foreign packed Governor node")))
      (def (truncated? failure)
        (and (Error? failure) (equal? (Error-message failure) "Truncated packed Governor cut")))
      (check-equal? (derive bound) '(9))
      (check-equal? (derive current (u8vector 1 0 2 0 1 1 1 0 0 0 0)) '(9 1))
      (check-equal? (derive current (u8vector 1 0 1 1 1 1 0 0 0 0)) '(9))
      (check-equal? (derive current (u8vector 0 2 0 1 1 1 0 0 0 0)) '(9))
      (check-equal? (derive current (u8vector 0 2 0 1 1 1 0 0 0 0)) '(9))
      (check-equal? (derive current (u8vector 1 0 2 0 1 1 1 0 0 0 0)) '(9 1))
      (check-exception (derive current (u8vector 1 2 0 0 0 0 0 0)) foreign?)
      (check-equal? (derive bound) '(9))
      (check-exception (derive current (u8vector 1 0)) truncated?))))
