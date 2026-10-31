;;; Qualification-only linked library initializer; no command-line data channel.
(import :std/ffi (only-in :std/error Error? Error-message RuntimeException?)
        (only-in :std/source this-source-file)
        (only-in :clan/poo/object .ref)
        (only-in :clan/poo/mop validate)
        :gerbil-scheme-rust/scheme/runtime
        ../../scheme/gateway/contracts
        ../../scheme/gateway/snapshot
        ./governed-control)
(export main)
;;; Keep the SDK's compiled scheduling policy; no fixed processor override.
;;; The retained host-sized activation failure is a separate SMP limitation.
(def (main . _) (void))
(def (capture-request value)
  (let* ((bundle (validate GatewayArtifact (native->source-data value)))
         (init (path-expand "../../init.ss" (path-directory (this-source-file)))))
    (source-data->native
      (capture-control-fixture init "policy-only"
        (.ref bundle 'tasks) (.ref bundle 'plans) (.ref bundle 'publication) "."))))
(def (brief-irritants values (remaining 4))
  (if (or (zero? remaining) (not (pair? values))) ""
    (string-append
      (if (string? (car values))
        (substring (car values) 0 (min 512 (string-length (car values)))) "")
      " " (brief-irritants (cdr values) (1- remaining)))))
(def (failure-message failure)
  (cond ((RuntimeException? failure) (failure-message (slot-ref failure 'exception)))
        ((Error? failure) (Error-message failure))
        ((unbound-global-exception? failure)
         (string-append "unbound-global:" (symbol->string (unbound-global-exception-variable failure))))
        ((error-exception? failure) (let ((message (error-exception-message failure))) (if (string? message) message "error-exception")))
        ((type-exception? failure) "type-exception")
        ((slot-ref failure 'message (lambda () #f)) => (lambda (message) (if (string? message) (string-append message " " (brief-irritants (slot-ref failure 'irritants (lambda () '())))) "non-string-message")))
        (else (string-append "exception-type:" (symbol->string (##type-id (class-of failure)))))))
(def (capture-safe value)
  (with-catch
    failure-message
    (lambda () (capture-request value))))
(begin-foreign
 (c-define (capture-root root) (int64) int64 "weaver_capture_source_test_v1" "extern"
   (gerbil-scheme-rust/scheme/runtime#gerbil-rs-rooted-call root
     hardenedlinux/weaver/t/fixtures/governance-program#capture-safe)))
