;;; A call-scoped data sink; neither emission nor capture grants authority.
(export capture-gateway-source deliver-gateway-source)

(def source-sink (make-parameter #f))

(def (check-source-text! text)
  (unless (and (string? text) (< 0 (string-length text) 8388609)
               (<= (u8vector-length (string->utf8 text)) 8388608))
    (error "Gateway source exceeds capture bound")))

(def (deliver-gateway-source text)
  (let ((sink (source-sink)))
    (if sink (sink text)
      (let ((path (getenv "WEAVER_CONTROL_ARTIFACT" #f)))
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
    (def (receive text)
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
          (check-source-text! text)
          (set! image (string-copy text))
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
            (string-copy image))))
      (lambda () (locked (lambda () (set! active? #f) (set! image #f)))))))
