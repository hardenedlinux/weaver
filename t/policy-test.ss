;;; SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
;;;
;;; SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

;;; These checks exercise the real compiled Cedar FFI without any execution grant.
(import :std/test
        (only-in :std/error Error? Error-message)
        (only-in :std/misc/ports read-all-as-string)
        (only-in :std/source this-source-file)
        (only-in :clan/poo/object .o)
        (only-in :agentic-ai-lab/modules/governance/interface AgenticAILabGovernanceProfile.)
        (only-in ../scheme/policy/assets policy-document)
        (prefix-in :clan/poo/testing/property/generator generator.)
        (prefix-in :clan/poo/testing/property property.)
        (only-in :clan/poo/testing/property/test check-property)
        (only-in ../scheme/policy/source-bytes cedar-source-utf8 bounded-cedar-source?)
        ../scheme/policy/func)
(export policy-test)

(def policy-test
  (test-suite "Inert Cedar Policy preflight"
    (test-case "a well-typed forbid policy passes inert preflight"
      (def schema
        (call-with-input-file
          (path-expand "../prod/policies/provider/schema.json" (path-directory (this-source-file)))
          read-all-as-string))
      (check-equal? (validate-source-policy! "forbid(principal,action,resource);" schema) #t))
    (test-case "invalid Cedar and schema input reject naturally"
      (check-exception (validate-source-policy! "not Cedar" "{}") Error?)
      (check-exception (validate-source-policy! "" "{}") Error?))
    (test-case "real Rust preflight refuses cross-document syntax assembly"
      (def schema
        (call-with-input-file
          (path-expand "../prod/policies/provider/schema.json" (path-directory (this-source-file)))
          read-all-as-string))
      (def aggregate "permit(principal,action,resource)\n;")
      (def profile (.o (:: @ AgenticAILabGovernanceProfile.)
                        identity: "weaver/policy-test" revision: "1" owner: "operator"))
      (def projection
        (project-policy profile aggregate
          (list (policy-document "a" "permit(principal,action,resource)" "")
                (policy-document "b" ";" "")) ""))
      (check-equal? (validate-source-policy! aggregate schema) #t)
      (check-exception
        (validate-policy-projection! projection schema validate-source-policy!) Error?))
    (test-case "the actual FFI entry refuses oversized Unicode before foreign preflight"
      (for-each
        (lambda (inputs)
          (check-equal?
            (with-catch (lambda (failure) (if (Error? failure) (Error-message failure) (raise failure)))
              (lambda () (apply validate-source-policy! inputs) 'accepted))
            "Policy and schema require bounded UTF-8 source"))
        (list (list (make-string 65537 #\a) "{}")
              (list "forbid(principal,action,resource);" (make-string 65537 #\a))
              (list (make-string 32769 (integer->char 233)) "{}")
              (list "forbid(principal,action,resource);" (make-string 32769 (integer->char 233))))))
    (test-case "native PBT checks Unicode source bounds before the C ABI"
      (def widths '(1 2 3 4))
      (def width-labels '(ascii two-byte three-byte four-byte))
      (def kinds '(empty small before-limit maximal-fit overflow))
      (def characters (map integer->char '(97 233 20013 128512)))
      (def report
        (property.check-property
          (generator.generator-sequence
            (list (generator.generator-integer 0 3) (generator.generator-integer 0 4)))
          (lambda (row)
            (let* ((width (list-ref widths (car row)))
                   (limit (quotient 65536 width))
                   (count (list-ref (list 0 1 (1- limit) limit (1+ limit)) (cadr row)))
                   (text (make-string count (list-ref characters (car row))))
                   (expected (and (> count 0) (<= (* count width) 65536)))
                   (bytes (cedar-source-utf8 text)))
              (and (eq? (bounded-cedar-source? text) expected)
                   (if expected
                     (and (u8vector? bytes) (= (u8vector-length bytes) (* count width))
                          (string=? (utf8->string bytes) text))
                     (eq? bytes #f)))))
          (property.make-specification
            (lambda (row) (and (list? row) (= (length row) 2) (andmap exact-integer? row)
                              (<= 0 (car row) 3) (<= 0 (cadr row) 4)))
            (lambda (row) (apply + row)))
          seed: 293 cases: 128 size: 128 shrink-budget: 64
          policy: (property.make-policy name: 'bounded-cedar-utf8
                    labels: (lambda (row) (list (list-ref width-labels (car row))
                                               (list-ref kinds (cadr row))))
                    required: (map (lambda (label) (cons label 1)) (append width-labels kinds)))))
      (check-property report)
      (check-equal? (property.report-accepted report) 128)
      (check-equal? (cedar-source-utf8 #f) #f)
      (check-equal? (cedar-source-utf8 65536) #f))))
