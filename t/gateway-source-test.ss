;;; Source compilation checks stay in the native Scheme test suite.
(import :std/test
        (only-in :std/error Error? Error-message)
        (only-in :clan/poo/object .o .get)
        (only-in :agentic-ai-lab/modules/governance/interface AgenticAILabGovernanceProfile.)
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
                             (.o validate: (lambda (_policy _schema) #f))
                             #f profile (.o request: 'publish) '() (list task) (list plan) source-publication)))
        "Policy preflight declined the source handoff"))
    (test-case "a false Governance assessment cannot emit a source handoff"
      (check-equal?
        (refusal-message
          (lambda ()
            (compile-gateway (.o open: (lambda (_governor _states) '("infer"))
                                assess: (lambda (_profile _context) #f))
                             (.o validate: (lambda (_policy _schema) #t))
                             #f profile (.o request: 'publish) '() (list task) (list plan) source-publication)))
        "Governance declined the source handoff"))))
