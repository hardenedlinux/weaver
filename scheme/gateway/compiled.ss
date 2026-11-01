;;; Fixed linked ABI. The approved application is an explicit build graph root.
;;; No application, Governor, Profile, module path or Policy is selected by RPC.
(import :std/ffi
        (only-in :clan/poo/object .get)
        :gerbil-scheme-rust/scheme/runtime
        (only-in "./program.ss" make-gateway-program)
        (only-in "./snapshot.ss" scheme-value->source-data source-data->scheme-value))
(export install-gateway-producer!)
(def source-program (make-gateway-program))
(def installed? #f)
(def (install-gateway-producer! producer)
  ((.get source-program install) producer)
  (set! installed? #t)
  #t)
(def (ready _) installed?)
(def (capture-request value)
  ;; Semantic decline is a valid false result, not a failed root transfer.
  (with-catch (lambda (_) #f)
    (lambda ()
      (source-data->scheme-value ((.get source-program capture) (scheme-value->source-data value))))))
(begin-foreign
 (c-define (capture-root root) (int64) int64 "weaver_capture_source_v1" "extern"
   (gerbil-scheme-rust/scheme/runtime#gerbil-rs-rooted-call root
     hardenedlinux/weaver/scheme/gateway/compiled#capture-request))
 (c-define (ready-root root) (int64) int64 "weaver_governance_ready_v1" "extern"
   (gerbil-scheme-rust/scheme/runtime#gerbil-rs-rooted-call root
     hardenedlinux/weaver/scheme/gateway/compiled#ready)))
