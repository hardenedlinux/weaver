;;; A call-scoped data sink; neither emission nor capture grants authority.
(import (only-in :clan/poo/mop validate json<-)
        (only-in :std/encoding/json json->string JSONWriteOptions)
        "./contracts.ss" (only-in "./snapshot.ss" copy-source-data))
(export capture-gateway-source deliver-gateway-source gateway-source-json)

(def source-sink (make-parameter #f))

(def (check-source-text! text)
  (unless (and (string? text) (< 0 (string-length text) 8388609)
               (<= (u8vector-length (string->utf8 text)) 8388608))
    (error "Gateway source exceeds capture bound")))

(def (gateway-source-json value)
  (json->string (json<- GatewayArtifact (validate GatewayArtifact value)) (JSONWriteOptions sort-keys: #t)))

(def (deliver-gateway-source value)
  (let ((sink (source-sink)))
    (if sink (sink value)
      (let ((path (getenv "WEAVER_CONTROL_ARTIFACT" #f)) (text (gateway-source-json value)))
        (check-source-text! text)
        (unless path (error "WEAVER_CONTROL_ARTIFACT is required"))
        (call-with-output-file path (lambda (port) (display text port))))))
  #t)

(def (capture-gateway-source producer)
  (unless (procedure? producer) (error "Gateway capture requires a producer"))
  (when (source-sink) (error "Gateway capture cannot reenter"))
  (let ((gate (make-mutex 'weaver-source-capture)) (active? #t) (seen? #f) (poisoned? #f) (image #f))
    (def (locked thunk)
      (dynamic-wind (lambda () (mutex-lock! gate)) thunk (lambda () (mutex-unlock! gate))))
    (def (receive value)
      (locked
        (lambda ()
          (unless active? (error "Gateway capture has ended"))
          (when (or seen? poisoned?)
            (set! poisoned? #t)
            (error "Gateway capture requires one source emission"))
          (set! seen? #t)
          ;; An encoding/copy failure also consumes this call's emission slot.
          ;; User code catching it cannot retry another image in the same call.
          (set! poisoned? #t)
          (set! image (copy-source-data (validate GatewayArtifact value)))
          (set! poisoned? #f))))
    (dynamic-wind
      void
      (lambda ()
        (parameterize ((source-sink receive))
          (unless (eq? (producer) #t) (error "Gateway source producer did not complete")))
        (locked
          (lambda ()
            (unless (and active? seen? (not poisoned?))
              (error "Gateway capture requires one source emission"))
            (set! active? #f)
            image)))
      (lambda () (locked (lambda () (set! active? #f) (set! image #f)))))))
