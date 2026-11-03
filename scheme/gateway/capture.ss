;;; A call-scoped data sink; neither emission nor capture grants authority.
(import (only-in :clan/poo/mop validate)
        "./contracts.ss" (only-in "./snapshot.ss" copy-source-data))
(export capture-gateway-source deliver-gateway-source)

(def source-sink (make-parameter #f))

(def (deliver-gateway-source value)
  (let ((sink (source-sink)))
    (unless sink (error "Gateway delivery requires an active typed capture"))
    (sink value))
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
