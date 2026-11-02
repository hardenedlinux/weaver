;;; Standard Cedar Policy values compose without an additional policy language.
(import :std/test
        (only-in :std/error Error?)
        (only-in :std/srfi/13 string-join)
        (only-in :clan/poo/object .o .get)
        (only-in :agentic-ai-lab/modules/governance/interface AgenticAILabGovernanceProfile.)
        (only-in :agentic-ai-lab/modules/authorization/providers/cedar/objects agentic-ai-lab-cedar-policy)
        (prefix-in :clan/poo/testing/property/generator generator.)
        (prefix-in :clan/poo/testing/property property.)
        (only-in :clan/poo/testing/property/test check-property)
        ../scheme/policy/func
        (only-in ../scheme/policy/assets policy-document))
(export policy-projection-test)
(def allow-source "permit(principal,action,resource);")
(def deny-source "forbid(principal,action,resource);")
(def (profile policy-values)
  (.o (:: @ AgenticAILabGovernanceProfile.) identity: "weaver/policy-test"
      revision: "1" owner: "operator" policies: policy-values))
(def policy-projection-test
  (test-suite "Governance Cedar projection"
    (test-case "native policy identities define stable standard Cedar composition"
      (def native (.o later: (agentic-ai-lab-cedar-policy "b" deny-source)
                       earlier: (agentic-ai-lab-cedar-policy "a" allow-source)))
      (def expected (string-append allow-source "\n" deny-source))
      (check-equal? (.get (project-policy (profile native) expected '() "") policy) expected)
      (check-exception (project-policy (profile native) allow-source '() "") Error?))
    (test-case "file documents bind identities and exact bytes to native policies"
      (def native (.o runtime: (agentic-ai-lab-cedar-policy "runtime" allow-source)))
      (def asset (policy-document "runtime" allow-source "runtime.cedar"))
      (check-equal? (length (.get (project-policy (profile native) allow-source (list asset) "/root") inputs)) 1)
      (check-equal? (.get (project-policy (profile (.o)) allow-source (list asset) "/root") policy) allow-source)
      (check-exception (project-policy (profile native) allow-source
                         (list (policy-document "runtime" deny-source "runtime.cedar")) "/root") Error?))
    (test-case "unknown obligations and duplicate policy identities reject"
      (check-exception (project-policy (profile (.o release: 'review-required)) allow-source '() "") Error?)
      (check-exception (project-policy
                         (profile (.o first: (agentic-ai-lab-cedar-policy "same" allow-source)
                                      second: (agentic-ai-lab-cedar-policy "same" deny-source)))
                         allow-source '() "") Error?))
    (test-case "every named document precedes aggregate validation"
      (def expected (string-append allow-source "\n" deny-source))
      (def projection
        (project-policy (profile (.o)) expected
          (list (policy-document "a" allow-source "")
                (policy-document "b" deny-source "")) ""))
      (def calls '())
      (check-equal?
        (validate-policy-projection! projection "schema"
          (lambda (text schema)
            (check-equal? schema "schema")
            (set! calls (append calls (list (string-copy text))))
            ;; Validator callbacks cannot mutate retained source documents.
            (string-set! text 0 #\x)
            #t)) #t)
      (check-equal? calls (list allow-source deny-source expected))
      (check-equal? (.get projection policy) expected))
    (test-case "document refusal stops before aggregate preflight"
      (def fragment "permit(principal,action,resource)")
      (def aggregate (string-append fragment "\n;"))
      (def projection
        (project-policy (profile (.o)) aggregate
          (list (policy-document "a" fragment "") (policy-document "b" ";" "")) ""))
      (def calls 0)
      (check-exception
        (validate-policy-projection! projection "schema"
          (lambda (text _schema)
            (set! calls (1+ calls))
            (equal? text aggregate))) Error?)
      (check-equal? calls 1))
    (test-case "publication-only projection validates exactly once"
      (def projection (project-policy (profile (.o)) allow-source '() ""))
      (def calls 0)
      (check-equal?
        (validate-policy-projection! projection "schema"
          (lambda (text _schema)
            (set! calls (1+ calls))
            (equal? text allow-source))) #t)
      (check-equal? calls 1))
    (test-case "PBT refuses at every document or aggregate validation boundary"
      (def report
        (property.check-property
          (generator.generator-sequence
            (list (generator.generator-integer 1 8) (generator.generator-integer 0 8)))
          (lambda (row)
            (let* ((count (car row)) (failure (modulo (cadr row) (1+ count)))
                   (documents (map (lambda (i)
                                     (policy-document (number->string i)
                                       (string-append allow-source " // " (number->string i)) ""))
                                   (iota count)))
                   (sources (map (lambda (document) (.get document source)) documents))
                   (projection (project-policy (profile (.o)) (string-join sources "\n") documents ""))
                   (calls 0))
              (def refused?
                (with-catch (lambda (error-value) (if (Error? error-value) #t (raise error-value)))
                  (lambda ()
                    (validate-policy-projection! projection "schema"
                      (lambda (_text _schema)
                        (set! calls (1+ calls))
                        (not (= calls (1+ failure)))))
                    #f)))
              (and refused? (= calls (1+ failure)))))
          (property.make-specification
            (lambda (row) (and (list? row) (= (length row) 2)
                              (andmap exact-integer? row)
                              (<= 1 (car row) 8) (<= 0 (cadr row) 8)))
            (lambda (row) (apply + row)))
          seed: 293 cases: 128 size: 128 shrink-budget: 64
          policy: (property.make-policy name: 'complete-policy-document-preflight)))
      (check-property report)
      (check-equal? (property.report-accepted report) 128))))
