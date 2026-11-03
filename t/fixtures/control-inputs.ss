;;; Structural Scheme contracts only; Rust owns cryptographic plan commitments.
(import (only-in :clan/poo/object .o)
        (only-in :clan/poo/mop validate)
        (only-in ../../scheme/gateway/contracts GatewaySourceInput))
(export control-inputs)

(def (control-inputs schema-text policy-text)
  (def commitment (make-string 64 #\a))
  (def task
    (.o family: "control" principal: "alice" profile: "p"
        provider_profile: (.o id: "p" protocol: "openai.chat-text-sse.v1"
                              max_output_tokens: 32 max_messages: 4 max_body_bytes: 1024)
        nodes: '("infer" "next") targets: '("primary" "backup")
        endpoints: (.o primary: "https://primary.invalid" backup: "https://backup.invalid")
        body_digests: (.o infer: commitment next: commitment)
        node_cost_bounds: (.o infer: 4 next: 4)
        stream_contracts: (.o infer: commitment next: commitment)
        models: '("model-a") budget: 8))
  (def (plan node-name)
    (.o family: "control" node: node-name profile: "p" profile_commitment: commitment
        model: "model-a" body: "{}" ceiling: 4 revision: 1 fence: 2
        routes: (list (.o target: "primary" endpoint: "https://primary.invalid")
                      (.o target: "backup" endpoint: "https://backup.invalid"))))
  (validate GatewaySourceInput
    (.o tasks: (list task) plans: (list (plan "infer") (plan "next"))
        publication: (.o operation_id: "source" expected_revision: 0 fence: 2
                         policy: policy-text schema: schema-text))))
