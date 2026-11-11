;;; SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
;;;
;;; SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

;;; Fixed linked ABI. The approved application is an explicit build graph root.
;;; No application, Governor, Profile, module path or Policy is selected by RPC.
(import :std/ffi
        (only-in :clan/poo/object .get .o)
        :gerbil-scheme-rust/scheme/runtime
        (only-in "./func.ss" governor-ready-steps make-retained-governor gateway-source-cancelled?)
        (only-in "./provider-source.ss" compose-provider-configuration)
        (only-in "./program.ss" make-gateway-program hard-fact-affected)
        (only-in "./snapshot.ss" scheme-value->source-data source-data->scheme-value))
(export install-gateway-producer!)
(def source-program (make-gateway-program))
(def installed? #f)
(def (install-gateway-producer! producer)
  ((.get source-program install) producer)
  (set! installed? #t)
  #t)
(def (ready _) installed?)
(def capture-cancel-callback #f)
(def (install-capture-cancel! callback) (set! capture-cancel-callback callback))
(extern capture-cancelled)
(def (capture-request value)
  ;; Semantic decline is a valid false result, not a failed root transfer.
  (with-catch (lambda (_) #f)
    (lambda ()
      (parameterize ((gateway-source-cancelled?
                       (and capture-cancel-callback
                            (lambda () (not (zero? (capture-cancelled capture-cancel-callback)))))))
        (source-data->scheme-value ((.get source-program capture) (scheme-value->source-data value)))))))
(def retained-governor? (equal? "1" (getenv "WEAVER_TEST_GOVERNOR_RETAINED" "0")))
(def derive-governor (if retained-governor? (make-retained-governor) governor-ready-steps))
(when (getenv "WEAVER_TEST_GOVERNOR_TIMING" #f)
  (let (port (current-error-port))
    (display (if retained-governor? "weaver-governor-mode retained\n" "weaver-governor-mode fresh\n") port)
    (force-output port)))
(def (derive-request value)
  (with-catch (lambda (_) #f)
    (lambda ()
      (let (packed (table-ref value 'packed_facts #f))
        (source-data->scheme-value
          (if packed
            (begin
              (unless (and retained-governor? (= (table-length value) 3))
                (error "Packed Governor cut requires a retained binding"))
              (derive-governor (.o topology_binding: (table-ref value 'topology_binding)
                                  indexed_result: (table-ref value 'indexed_result))
                               packed))
            (derive-governor (scheme-value->source-data value))))))))
(def (compose-request value)
  (with-catch (lambda (_) #f)
    (lambda () (source-data->scheme-value
      (compose-provider-configuration (scheme-value->source-data value))))))
(def (fact-impact-request value)
  (with-catch (lambda (_) #f)
    (lambda ()
      (source-data->scheme-value (hard-fact-affected (scheme-value->source-data value))))))
(begin-foreign
 (namespace ("hardenedlinux/weaver/scheme/gateway/compiled#" capture-cancelled))
 (define capture-cancelled
   (c-lambda ((pointer void)) int "___return((*(int (**)(void))___arg1)());"))
 (c-define (install-cancel callback) ((pointer void)) void "weaver_install_source_cancel_v1" "extern"
   (hardenedlinux/weaver/scheme/gateway/compiled#install-capture-cancel! callback))
 (c-define (derive-root root) (int64) int64 "weaver_governor_ready_steps_v1" "extern"
   (gerbil-scheme-rust/scheme/runtime#gerbil-rs-rooted-call root
     hardenedlinux/weaver/scheme/gateway/compiled#derive-request))
 (c-define (fact-impact-root root) (int64) int64 "weaver_hard_fact_impact_v1" "extern"
   (gerbil-scheme-rust/scheme/runtime#gerbil-rs-rooted-call root
     hardenedlinux/weaver/scheme/gateway/compiled#fact-impact-request))
 (c-define (compose-root root) (int64) int64 "weaver_compose_source_v1" "extern"
   (gerbil-scheme-rust/scheme/runtime#gerbil-rs-rooted-call root
     hardenedlinux/weaver/scheme/gateway/compiled#compose-request))
 (c-define (capture-root root) (int64) int64 "weaver_capture_source_v1" "extern"
   (gerbil-scheme-rust/scheme/runtime#gerbil-rs-rooted-call root
     hardenedlinux/weaver/scheme/gateway/compiled#capture-request))
 (c-define (ready-root root) (int64) int64 "weaver_governance_ready_v1" "extern"
   (gerbil-scheme-rust/scheme/runtime#gerbil-rs-rooted-call root
     hardenedlinux/weaver/scheme/gateway/compiled#ready)))
