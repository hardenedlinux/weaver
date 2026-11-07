;;; SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
;;;
;;; SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

(import :std/test
        (only-in :std/error Error?)
        (only-in :clan/poo/object .o .get object-slots-set!)
        (only-in :clan/poo/mop validate sexp<- TypeError?)
        (only-in :std/list/list delete-duplicates/hash)
        (only-in "./fixtures/control-inputs.ss" control-inputs)
        (only-in ../scheme/gateway/contracts GatewayArtifact)
        (only-in ../scheme/gateway/derivation-types GatewayDerivationResult GatewayDerivationRequest)
        ../scheme/gateway/derivation
        (prefix-in :clan/poo/testing/property/generator generator.)
        (prefix-in :clan/poo/testing/property property.)
        (only-in :clan/poo/testing/property/test check-property))
(export gateway-derivation-test)

(def (source)
  (def input (control-inputs "{}" "permit(principal,action,resource);"))
  (validate GatewayArtifact
    (.o (:: @ input) governance: (.o schema: "agentic-ai-lab.loop-governor.v1"
                                     family: "control" open_nodes: '("infer" "next")))))
(def (data contract value) (sexp<- contract (validate contract value)))
(def (edge dependent-value dependency-value) (.o dependent: dependent-value dependency: dependency-value))
(def (candidate-rows result)
  (map (lambda (row) (list (.get row node) (.get row target) (.get row model))) (.get result candidates)))
(def (attempt thunk)
  (with-catch (lambda (failure) (if (Error? failure) #f (raise failure))) thunk))

;;; Independent graph traversal oracle, not a second relational rule evaluator.
(def (reachable dependencies changed)
  (let walk ((pending changed) (seen '()))
    (cond ((null? pending) (list-sort string<? seen))
          ((member (car pending) seen) (walk (cdr pending) seen))
          (else
           (walk (append (cdr pending)
                         (filter-map (lambda (row) (and (equal? (cadr row) (car pending)) (car row))) dependencies))
                 (cons (car pending) seen))))))

(def gateway-derivation-test
  (test-suite "Bounded inherited ASCENT source derivation"
    (test-case "declared candidates are complete advisory data and preserve the source"
      (def original (source))
      (def before (data GatewayArtifact original))
      (def result (derive-gateway-source original))
      (check-equal? (candidate-rows result)
                    '(("infer" "backup" "model-a") ("infer" "primary" "model-a")
                      ("next" "backup" "model-a") ("next" "primary" "model-a")))
      (check-equal? (.get result complete) #t)
      (check-equal? (.get result execution_authorized) #f)
      (check-equal? (.get result affected_nodes) '())
      (check-equal? (data GatewayArtifact original) before))
    (test-case "an undeclared model has explicit reasons and never gains a candidate"
      (def original (source))
      (def bad (.o (:: @ original) plans:
                  (map (lambda (plan) (.o (:: @ plan) model: "undeclared")) (.get original plans))))
      (def result (derive-gateway-source bad))
      (check-equal? (.get result candidates) '())
      (check-equal? (map (lambda (row) (.get row declared_model)) (.get result explanations)) '(#f #f #f #f))
      (check-equal? (.get result execution_authorized) #f))
    (test-case "recursive impact handles cycles and propagates only to dependent operations"
      (def owner (make-gateway-derivation))
      (def query (gateway-derivation-request (source)
                    (list (edge "infer" "policy") (edge "next" "infer") (edge "infer" "next")
                          (edge "other" "untouched")) '("policy")))
      (def result ((.get owner derive) query))
      (check-equal? (.get result affected) '("infer" "next" "policy"))
      (check-equal? (.get result affected_nodes) '("infer" "next"))
      ((.get owner close)))
    (test-case "retained replacement retracts impact and equals fresh evaluation"
      (def owner (make-gateway-derivation))
      (def original (source))
      (def first-query (gateway-derivation-request original
                          (list (edge "infer" "policy") (edge "next" "infer")) '("policy")))
      (def next-query (gateway-derivation-request original (list (edge "infer" "policy")) '("policy")))
      (def first ((.get owner derive) first-query))
      (def same ((.get owner derive) first-query))
      (check-equal? (.get same generation) (.get first generation))
      (def next ((.get owner derive) next-query))
      (def fresh-owner (make-gateway-derivation))
      (def fresh ((.get fresh-owner derive) next-query))
      (check-equal? (.get next affected_nodes) '("infer"))
      (check-equal? (.get next affected) (.get fresh affected))
      (check-equal? (candidate-rows next) (candidate-rows fresh))
      (check-equal? (.get next request_digest) (.get fresh request_digest))
      (check-equal? (.get first affected_nodes) '("infer" "next"))
      (check-equal? ((.get owner matches?) first-query first) #f)
      (check-equal? ((.get owner matches?) next-query next) #t)
      ((.get owner close)) ((.get fresh-owner close)))
    (test-case "owned inputs and returned results cannot mutate retained state"
      (def owner (make-gateway-derivation))
      (def query (gateway-derivation-request (source) (list (edge "infer" "policy")) '("policy")))
      (def result ((.get owner derive) query))
      (def original-digest (string-copy (.get result request_digest)))
      (string-set! (.get result request_digest) 0 (if (char=? (string-ref original-digest 0) #\a) #\b #\a))
      (check-equal? ((.get owner matches?) query result) #f)
      (def again ((.get owner derive) query))
      (check-equal? (.get again request_digest) original-digest)
      (string-set! (car (.get query changed)) 0 #\x)
      (check-equal? (.get again affected_nodes) '("infer"))
      (check-equal? ((.get owner matches?) query again) #f)
      ((.get owner close)))
    (test-case "replacement changes the integer dictionary without mixing old sources"
      (def owner (make-gateway-derivation))
      (def original (source))
      (def first-query (gateway-derivation-request original (list (edge "next" "policy")) '("policy")))
      (def first ((.get owner derive) first-query))
      ;; The new first dictionary entry shifts every old integer coordinate.
      (def next-query (gateway-derivation-request original (list (edge "infer" "aaa")) '("aaa")))
      (def next ((.get owner derive) next-query))
      (check-equal? (.get next affected) '("aaa" "infer"))
      (check-equal? (.get next affected_nodes) '("infer"))
      (check-equal? (candidate-rows next) (candidate-rows first))
      (check-equal? (.get first affected_nodes) '("next"))
      ((.get owner close)))
    (test-case "source changes with identical rows invalidate full-image reuse"
      (def owner (make-gateway-derivation))
      (def original (source))
      (def first-query (gateway-derivation-request original))
      (def first ((.get owner derive) first-query))
      (def changed (.o (:: @ original) plans:
                      (map (lambda (plan) (.o (:: @ plan) body: "{\"changed\":true}")) (.get original plans))))
      (def changed-query (gateway-derivation-request changed))
      (def second ((.get owner derive) changed-query))
      (check-equal? (candidate-rows first) (candidate-rows second))
      (check-equal? (equal? (.get first source_digest) (.get second source_digest)) #f)
      (check-equal? ((.get owner matches?) first-query first) #f)
      (def returned ((.get owner derive) first-query))
      (check-equal? (> (.get returned generation) (.get second generation)) #t)
      (check-equal? ((.get owner matches?) first-query first) #f)
      ((.get owner close)))
    (test-case "invalid input and fact overflow preserve the prior accepted result"
      (def owner (make-gateway-derivation))
      (def query (gateway-derivation-request (source)))
      (def result ((.get owner derive) query))
      (check-exception ((.get owner derive) (.o (:: @ query) unchecked: #t)) TypeError?)
      (def large (gateway-derivation-request (.get query source) '() (make-list 4096 "policy")))
      (check-equal? (attempt (lambda () ((.get owner derive) large))) #f)
      (check-equal? ((.get owner matches?) query result) #t)
      (check-equal? (.get ((.get owner derive) query) generation) (.get result generation))
      ((.get owner close)))
    (test-case "explicit invalidation prevents ABA reuse and close is terminal"
      (def owner (make-gateway-derivation))
      (def query (gateway-derivation-request (source)))
      (def result ((.get owner derive) query))
      ((.get owner invalidate))
      (check-equal? ((.get owner matches?) query result) #f)
      (def renewed ((.get owner derive) query))
      (check-equal? (> (.get renewed generation) (.get result generation)) #t)
      (check-exception (object-slots-set! owner '()) Error?)
      ((.get owner close))
      (check-equal? (attempt (lambda () ((.get owner derive) query))) #f)
      (check-equal? (attempt (lambda () ((.get owner matches?) query renewed))) #f))
    (test-case "a different thread cannot use or close the retained owner"
      (def owner (make-gateway-derivation))
      (def query (gateway-derivation-request (source)))
      (def answer #f)
      (def worker (make-thread (lambda () (set! answer (list
        (attempt (lambda () ((.get owner derive) query)))
        (attempt (lambda () ((.get owner close)))))))))
      (thread-start! worker) (thread-join! worker)
      (check-equal? answer '(#f #f))
      (check-equal? (.get ((.get owner derive) query) complete) #t)
      ((.get owner close)))
    (test-case "generated source replacements agree with graph traversal and fresh results"
      (def names '("policy" "infer" "next" "unrelated"))
      (def (query-for original command)
        (def edges
          (filter-map (lambda (index)
                        (and (not (= command index))
                             (list (list-ref names index) (list-ref names (modulo (1+ index) 4)))))
                      '(0 1 2 3)))
        (gateway-derivation-request original
          (map (lambda (row) (edge (car row) (cadr row))) edges) (list (list-ref names command))))
      ;; The generated commands select exactly four complete input cuts. Solve
      ;; each independently once; all 32x8 retained updates still compare against
      ;; the fresh oracle for their exact request digest and a separate traversal.
      (def fresh-results
        (map (lambda (command)
               (def fresh-owner (make-gateway-derivation))
               (def fresh ((.get fresh-owner derive) (query-for (source) command)))
               ((.get fresh-owner close)) fresh) '(0 1 2 3)))
      (def report
        (property.check-property
          (generator.generator-sequence (make-list 8 (generator.generator-integer 0 3)))
          (lambda (commands)
            (def owner (make-gateway-derivation))
            (def original (source))
            (def result
              (andmap
                (lambda (command)
                  (def query (query-for original command))
                  (def edges (map (lambda (item) (list (.get item dependent) (.get item dependency)))
                                  (.get query dependencies)))
                  (def actual ((.get owner derive) query))
                  (def fresh (list-ref fresh-results command))
                  (and (equal? (.get actual request_digest) (.get fresh request_digest))
                       (equal? (.get actual affected) (reachable edges (.get query changed)))
                       (equal? (.get actual affected_nodes) (.get fresh affected_nodes))
                       (equal? (candidate-rows actual) (candidate-rows fresh))
                       (eq? (.get actual execution_authorized) #f))) commands))
            ((.get owner close)) result)
          (property.make-specification
            (lambda (commands) (and (list? commands) (= (length commands) 8)
                                   (andmap (lambda (n) (and (exact-integer? n) (<= 0 n 3))) commands)))
            (lambda (commands) (apply + commands)))
          seed: 293 cases: 32 size: 32 shrink-budget: 64))
      (check-property report)
      (check-equal? (property.report-accepted report) 32))))
