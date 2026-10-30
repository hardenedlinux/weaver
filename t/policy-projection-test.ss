;;; Standard Cedar Policy values compose without an additional policy language.
(import :std/test
        (only-in :std/error Error?)
        (only-in :clan/poo/object .o .get)
        (only-in :agentic-ai-lab/modules/governance/interface AgenticAILabGovernanceProfile.)
        (only-in :agentic-ai-lab/modules/authorization/providers/cedar/objects agentic-ai-lab-cedar-policy)
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
                         allow-source '() "") Error?))))
