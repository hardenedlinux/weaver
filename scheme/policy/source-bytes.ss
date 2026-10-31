;;; Bound characters before encoding, then enforce the actual UTF-8 byte bound.
;;; These bytes are inert input, never an authorization or execution capability.
(export cedar-source-utf8 bounded-cedar-source?)

(def (cedar-source-utf8 value)
  (and (string? value)
       (< 0 (string-length value) 65537)
       (let ((bytes (string->utf8 value)))
         (and (<= (u8vector-length bytes) 65536) bytes))))

(def (bounded-cedar-source? value)
  (and (cedar-source-utf8 value) #t))
