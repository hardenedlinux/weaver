(import :clan/poo/object (only-in :clan/poo/mop element?) :core/modules/json-schema/contracts)
(def bounded (schema-value-contract 'weaver/probe '((type . "integer") (minimum . 0) (maximum . 10))))
(unless (and (element? bounded 7) (not (element? bounded 11))) (error "native bounded contract failed"))
(display "NATIVE-CONTRACT-PROBE-PASS\n")
