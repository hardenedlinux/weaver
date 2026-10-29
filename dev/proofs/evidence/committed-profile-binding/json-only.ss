(import :std/encoding/json)
(call-with-input-string "{\"node\":\"infer\"}" read-json)
(display "CONTROL-COMPLETE\n")
