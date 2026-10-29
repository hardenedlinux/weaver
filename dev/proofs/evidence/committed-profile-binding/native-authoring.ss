(import :clan/poo/object
        (only-in :clan/poo/mop element?)
        :core/modules/json-schema/contracts
        :std/encoding/json
        (only-in :core/modules/json-schema/json-schema-source poo-flow-json-schema-read-port))
(def schema
  '((type . "object")
    (properties .
      ((routine . ((type . "string") (enum . ("support.resolve"))))
       (node . ((type . "string") (enum . ("infer"))))
       (response . ((type . "string") (enum . ("support.answer"))))
       (targets . ((type . "array") (minItems . 1) (uniqueItems . #t)
                   (items . ((type . "string") (enum . ("support.primary" "support.private"))))))
       (ceiling-microcredits . ((type . "integer") (minimum . 0) (maximum . 18446744073709551615)))
       (context-floor-tokens . ((type . "integer") (minimum . 0) (maximum . 18446744073709551615)))
       (extra-requirements . ((type . "array") (items . ((type . "string")))))
       (extensions . ((type . "object") (additionalProperties . #f)))))
    (required . ("routine" "node" "response" "targets" "ceiling-microcredits"))
    (additionalProperties . #f)))
(def contract (schema-value-contract 'weaver/support-infer schema))
(def (parse value) (call-with-input-string value poo-flow-json-schema-read-port))
(def (check name actual expected)
  (unless (equal? actual expected) (error "native check mismatch" name actual expected))
  (display "CHECK ") (display name) (display " PASS\n"))
(def scheme-value
  (.o routine: "support.resolve" node: "infer" response: "support.answer"
      targets: (list "support.primary" "support.private")
      ceiling-microcredits: 100000 context-floor-tokens: 4096
      extra-requirements: '() extensions: (.o)))
(def json-value
  "{\"routine\":\"support.resolve\",\"node\":\"infer\",\"response\":\"support.answer\",\"targets\":[\"support.primary\",\"support.private\"],\"ceiling-microcredits\":100000,\"context-floor-tokens\":4096,\"extra-requirements\":[],\"extensions\":{}}")
(check 'scheme-object-contract (element? contract scheme-value) #t)
(check 'native-json-contract (element? contract (parse json-value)) #t)
(check 'native-negative-ceiling
  (element? contract (parse "{\"routine\":\"support.resolve\",\"node\":\"infer\",\"response\":\"support.answer\",\"targets\":[\"support.primary\"],\"ceiling-microcredits\":-1}")) #f)
(check 'native-boolean-ceiling
  (element? contract (parse "{\"routine\":\"support.resolve\",\"node\":\"infer\",\"response\":\"support.answer\",\"targets\":[\"support.primary\"],\"ceiling-microcredits\":true}")) #f)
(check 'native-string-ceiling
  (element? contract (parse "{\"routine\":\"support.resolve\",\"node\":\"infer\",\"response\":\"support.answer\",\"targets\":[\"support.primary\"],\"ceiling-microcredits\":\"100\"}")) #f)
(check 'native-null-ceiling
  (element? contract (parse "{\"routine\":\"support.resolve\",\"node\":\"infer\",\"response\":\"support.answer\",\"targets\":[\"support.primary\"],\"ceiling-microcredits\":null}")) #f)
(check 'native-unknown-authority-field
  (element? contract (parse "{\"routine\":\"support.resolve\",\"node\":\"infer\",\"response\":\"support.answer\",\"targets\":[\"support.primary\"],\"ceiling-microcredits\":10,\"origin\":\"fresh\"}")) #f)
(check 'native-changed-node
  (element? contract (parse "{\"routine\":\"support.resolve\",\"node\":\"release\",\"response\":\"support.answer\",\"targets\":[\"support.primary\"],\"ceiling-microcredits\":10}")) #f)
(check 'native-overflow-ceiling
  (element? contract (parse "{\"routine\":\"support.resolve\",\"node\":\"infer\",\"response\":\"support.answer\",\"targets\":[\"support.primary\"],\"ceiling-microcredits\":18446744073709551616}")) #f)
(check 'native-empty-targets
  (element? contract (parse "{\"routine\":\"support.resolve\",\"node\":\"infer\",\"response\":\"support.answer\",\"targets\":[],\"ceiling-microcredits\":10}")) #f)
(check 'native-duplicate-targets
  (element? contract (parse "{\"routine\":\"support.resolve\",\"node\":\"infer\",\"response\":\"support.answer\",\"targets\":[\"support.primary\",\"support.primary\"],\"ceiling-microcredits\":10}")) #f)
(def duplicate
  "{\"routine\":\"support.resolve\",\"node\":\"release\",\"node\":\"infer\",\"response\":\"support.answer\",\"targets\":[\"support.primary\"],\"ceiling-microcredits\":10}")
;; Observe actual decoder behavior; acceptance is a negative control, not compliance.
(display "OBSERVATION duplicate-json-contract-accepted ")
(write (with-catch (lambda (e) 'decoder-rejected) (lambda () (element? contract (parse duplicate)))))
(newline)
(display "NATIVE-AUTHORING-CHECKS-COMPLETE\n")
