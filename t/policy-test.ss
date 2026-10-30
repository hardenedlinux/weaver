;;; These checks exercise the real compiled Cedar FFI without any execution grant.
(import :std/test
        (only-in :std/error Error?)
        (only-in :std/misc/ports read-all-as-string)
        (only-in :std/source this-source-file)
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
      (check-exception (validate-source-policy! "" "{}") Error?))))
