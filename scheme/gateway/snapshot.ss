;;; Scheme data projection only: no JSON text and no procedure/object word escapes.
(import (only-in :clan/poo/object .all-slots .ref object<-alist))
(export copy-source-data source-data->scheme-value scheme-value->source-data)

(def (copy-source-data value)
  (def remaining 8388608)
  (def nodes 16384)
  (def (copy value depth)
    (set! nodes (1- nodes))
    (when (or (< nodes 0) (> depth 64)) (error "Gateway source shape bound"))
    (cond
      ((string? value)
       (when (> (string-length value) remaining) (error "Gateway source exceeds capture bound"))
       (set! remaining (- remaining (u8vector-length (string->utf8 value))))
       (when (< remaining 0) (error "Gateway source exceeds capture bound"))
       (string-copy value))
      ((or (boolean? value) (exact-integer? value) (null? value)) value)
      ((pair? value) (cons (copy (car value) (1+ depth)) (copy (cdr value) depth)))
      (else
       (object<-alist
         (map (lambda (key) (cons key (copy (.ref value key) (1+ depth)))) (.all-slots value))))))
  (copy value 0))

;;; Field names remain Scheme symbols; declared identifier maps use Scheme strings.
(def identifier-maps '(endpoints body_digests node_cost_bounds stream_contracts))
(def (source-data->scheme-value value (identifier-map? #f))
  (cond
    ((or (string? value) (boolean? value) (exact-integer? value)) value)
    ((list? value) (list->vector (map source-data->scheme-value value)))
    (else
     (let ((result (make-table test: equal?)))
       (for-each
         (lambda (key)
           (table-set! result (if identifier-map? (symbol->string key) key)
             (source-data->scheme-value (.ref value key) (and (memq key identifier-maps) #t))))
         (.all-slots value))
       result))))

(def (scheme-value->source-data value (identifier-map? #f))
  (cond
    ((or (string? value) (boolean? value) (exact-integer? value)) value)
    ((vector? value) (map scheme-value->source-data (vector->list value)))
    ((null? value) #f)
    ((table? value)
     (let ((seen '()))
       (object<-alist
         (filter-map
           (lambda (entry)
             (let* ((key (car entry))
                    (name (if identifier-map?
                            (if (string? key) key (error "Gateway bridge requires string identifier keys"))
                            (if (symbol? key) (symbol->string key)
                              (error "Gateway bridge requires symbol field keys"))))
                    (field (string->symbol name)))
               (when (member name seen) (error "Gateway bridge duplicate key"))
               (set! seen (cons name seen))
               ;; Absence belongs only to declared optional fields. Unknown nil
               ;; fields remain visible to closed Record validation.
               (and (not (and (not identifier-map?) (null? (cdr entry))
                              (memq field '(expected_revision provider_profile))))
                    (cons field (scheme-value->source-data (cdr entry)
                                  (and (memq field identifier-maps) #t))))))
           (table->list value)))))
    (else (error "unsupported Scheme source value"))))
