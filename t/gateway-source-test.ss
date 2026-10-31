;;; Source compilation checks stay in the native Scheme test suite.
(import :std/test
        (only-in :std/error Error? Error-message)
        (only-in :clan/poo/object .o .get)
        (only-in :agentic-ai-lab/modules/governance/interface AgenticAILabGovernanceProfile.)
        (only-in ../scheme/policy/func project-policy)
        (only-in ../scheme/gateway/capture capture-gateway-source deliver-gateway-source)
        (prefix-in :clan/poo/testing/property/generator generator.)
        (prefix-in :clan/poo/testing/property property.)
        (only-in :clan/poo/testing/property/test check-property)
        ../scheme/gateway/func)
(export gateway-source-test)

(def commitment (make-string 64 #\a))
(def profile
  (.o (:: @ AgenticAILabGovernanceProfile.) identity: "weaver/test" revision: "1" owner: "operator"))
(def task
  (.o family: "family" principal: "agent" profile: "profile"
      provider_profile: (.o id: "profile" protocol: "openai.chat-text-sse.v1"
                            max_output_tokens: 32 max_messages: 4 max_body_bytes: 1024)
      nodes: '("infer") targets: '("primary" "backup")
      endpoints: (.o primary: "https://primary.invalid" backup: "https://backup.invalid")
      body_digests: (.o infer: commitment) node_cost_bounds: (.o infer: 4)
      stream_contracts: (.o infer: commitment) models: '("model") budget: 8))
(def plan
  (.o family: "family" node: "infer" profile: "profile" profile_commitment: commitment
      model: "model" body: "{}" ceiling: 4 revision: 0 fence: 1
      routes: (list (.o target: "primary" endpoint: "https://primary.invalid")
                    (.o target: "backup" endpoint: "https://backup.invalid"))))
(def source-publication
  (.o operation_id: "source" fence: 1 policy: "permit(principal,action,resource);" schema: "{}"))
(def bundle
  (.o governance: (.o schema: "agentic-ai-lab.loop-governor.v1" family: "family" open_nodes: '("infer"))
      tasks: (list task) plans: (list plan) publication: source-publication))
(def (refusal-message thunk)
  (with-catch (lambda (failure) (if (Error? failure) (Error-message failure) (raise failure)))
    (lambda () (thunk) #f)))

(def gateway-source-test
  (test-suite "Stable source assessment projection"
    (test-case "capture enforces the source byte boundary without aliasing its input"
      (let* ((text (make-string 8388608 #\a))
             (image (capture-gateway-source (lambda () (deliver-gateway-source text)))))
        (check-equal? (string-length image) 8388608)
        (string-set! text 0 #\z)
        (check-equal? (string-ref image 0) #\a))
      (for-each
        (lambda (text)
          (check-equal?
            (refusal-message (lambda () (capture-gateway-source (lambda () (deliver-gateway-source text)))))
            "Gateway source exceeds capture bound"))
        (list "" (make-string 8388609 #\a) (make-string 4194305 (integer->char 233)))))
    (test-case "native PBT requires one completed emission and an independent image"
      (def report
        (property.check-property
          (generator.generator-sequence
            (list (generator.generator-integer 0 3) (generator.generator-integer 0 1)
                  (generator.generator-integer 1 128) (generator.generator-integer 0 1)))
          (lambda (row)
            (let* ((count (car row)) (complete? (= (cadr row) 1))
                   (text (make-string (caddr row) #\a)) (original (string-copy text))
                   (outcome
                    (with-catch (lambda (failure) (if (Error? failure) 'refused (raise failure)))
                      (lambda ()
                        (capture-gateway-source
                          (lambda ()
                            (when (= (cadddr row) 1)
                              (refusal-message (lambda () (deliver-gateway-source ""))))
                            (for-each
                              (lambda (_)
                                ;; Swallowing a duplicate exception cannot clear its fuse.
                                (with-catch (lambda (failure) (if (Error? failure) #f (raise failure)))
                                  (lambda () (deliver-gateway-source text)))) (iota count))
                            (string-set! text 0 #\z)
                            complete?))))))
              (if (and (= count 1) complete? (= (cadddr row) 0))
                (equal? outcome original) (eq? outcome 'refused))))
          (property.make-specification
            (lambda (row) (and (list? row) (= (length row) 4) (andmap exact-integer? row)
                              (<= 0 (car row) 3) (<= 0 (cadr row) 1) (<= 1 (caddr row) 128)
                              (<= 0 (cadddr row) 1)))
            (lambda (row) (apply + row)))
          seed: 293 cases: 128 size: 128 shrink-budget: 64
          policy: (property.make-policy name: 'one-completed-source-image
                    labels: (lambda (row) (list (list-ref '(zero one two three) (car row))
                                               (if (= (cadr row) 1) 'completed 'incomplete)
                                               (if (= (cadddr row) 1) 'invalid-first 'clean)))
                    required: '((zero . 1) (one . 1) (two . 1) (three . 1) (completed . 1) (incomplete . 1)
                                (invalid-first . 1) (clean . 1)))))
      (check-property report)
      (check-equal? (property.report-accepted report) 128))
    (test-case "concurrent emissions serialize and poison a caught duplicate"
      (check-equal?
        (refusal-message
          (lambda ()
            (capture-gateway-source
              (lambda ()
                (let ((workers
                       (map (lambda (text)
                              (thread-start!
                                (make-thread
                                  (lambda ()
                                    (with-catch (lambda (failure) (if (Error? failure) #f (raise failure)))
                                      (lambda () (deliver-gateway-source text))))))) '("first" "second"))))
                  (for-each thread-join! workers)
                  #t)))))
        "Gateway capture requires one source emission"))
    (test-case "producer failure discards its image before another capture"
      (check-equal?
        (refusal-message
          (lambda ()
            (capture-gateway-source
              (lambda () (deliver-gateway-source "discarded") (error "source failed after emission")))))
        "source failed after emission")
      (check-equal? (capture-gateway-source (lambda () (deliver-gateway-source "next"))) "next"))
    (test-case "caught invalid emission cannot be replaced inside the same capture"
      (check-equal?
        (refusal-message
          (lambda ()
            (capture-gateway-source
              (lambda ()
                (refusal-message (lambda () (deliver-gateway-source "")))
                (refusal-message (lambda () (deliver-gateway-source "replacement")))
                #t))))
        "Gateway capture requires one source emission"))
    (test-case "a late inherited sink cannot replace an active next capture"
      (def release (make-mutex 'late-source-emission))
      (def release-held? #t)
      (def worker #f)
      (def image #f)
      (def next #f)
      (def late #f)
      (mutex-lock! release)
      (dynamic-wind void
        (lambda ()
          (set! image
            (capture-gateway-source
              (lambda ()
                (set! worker
                  (thread-start!
                    (make-thread
                      (lambda ()
                        (mutex-lock! release) (mutex-unlock! release)
                        (refusal-message (lambda () (deliver-gateway-source "late")))))))
                (deliver-gateway-source "original"))))
          (set! next
            (capture-gateway-source
              (lambda ()
                (mutex-unlock! release) (set! release-held? #f)
                (set! late (thread-join! worker)) (set! worker #f)
                (deliver-gateway-source "next")))))
        (lambda ()
          (when release-held? (mutex-unlock! release))
          (when worker (set! late (thread-join! worker)))))
      (check-equal? image "original")
      (check-equal? next "next")
      (check-equal? late "Gateway capture has ended"))
    (test-case "SDK sorted JSON preserves source identity and significant order"
      (def first (gateway-source-json bundle))
      (for-each (lambda (_) (check-equal? (gateway-source-json bundle) first)) (iota 16))
      (check (equal? first
                     (gateway-source-json (.o (:: @ bundle)
                       publication: (.o (:: @ source-publication) policy: "forbid(principal,action,resource);")))) => #f)
      (check (equal? first
                     (gateway-source-json (.o (:: @ bundle)
                       plans: (list (.o (:: @ plan) routes: (reverse (.get plan routes))))))) => #f))
    (test-case "a false Policy preflight cannot emit a source handoff"
      (check-equal?
        (refusal-message
          (lambda ()
            (compile-gateway (.o open: (lambda (_governor _states) '("infer")))
                             (.o validate: (lambda (_policy _schema) #f)
                                 project: (lambda (p text root) (project-policy p text '() root)))
                             #f profile (.o request: 'publish) '() (list task) (list plan) source-publication)))
        "Policy preflight declined the source handoff"))
    (test-case "a false Governance assessment cannot emit a source handoff"
      (check-equal?
        (refusal-message
          (lambda ()
            (compile-gateway (.o open: (lambda (_governor _states) '("infer"))
                                assess: (lambda (_profile _context) #f))
                             (.o validate: (lambda (_policy _schema) #t)
                                 project: (lambda (p text root) (project-policy p text '() root)))
                             #f profile (.o request: 'publish) '() (list task) (list plan) source-publication)))
        "Governance declined the source handoff"))))
