;;; Scheme-to-Rust Cedar C ABI preflight. Final publication repeats validation.
(import :std/ffi (only-in "./source-bytes.ss" cedar-source-utf8))
(export validate-source-policy!)

(begin-foreign
  (c-declare "#include <weaver_policy.h>"))

(def-C-lambda policy-abi () unsigned-int "weaver_policy_abi_v1")
(def-C-lambda policy-validate/raw (scheme-object scheme-object) int
  "___result = weaver_policy_validate_v1(
     ___CAST(const uint8_t*, ___BODY_AS(___arg1, ___tSUBTYPED)),
     ___U8VECTORSIZE(___arg1),
     ___CAST(const uint8_t*, ___BODY_AS(___arg2, ___tSUBTYPED)),
     ___U8VECTORSIZE(___arg2));")

(def (validate-source-policy! policy schema)
  (unless (and (string? policy) (string? schema))
    (error "Policy and schema must be source strings"))
  (let ((policy-bytes (cedar-source-utf8 policy))
        (schema-bytes (cedar-source-utf8 schema)))
    (unless (and policy-bytes schema-bytes)
      (error "Policy and schema require bounded UTF-8 source"))
    (unless (= (policy-abi) #x00010000)
      (error "unsupported Rust Policy ABI"))
    (let ((status (policy-validate/raw policy-bytes schema-bytes)))
      (unless (= status 0)
        (error "Rust rejected inert source Policy/schema" status))))
  #t)
