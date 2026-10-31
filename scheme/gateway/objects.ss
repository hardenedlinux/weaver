;;; Dependency scopes are injected by Yuanxu's declaration linker.
(import (only-in :clan/poo/object .o) "./func.ss"
        (only-in "./capture.ss" capture-gateway-source))
(export Gateway.)
(def Gateway. (.o emit: emit-gateway capture: capture-gateway-source))
