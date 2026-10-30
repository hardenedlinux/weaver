;;; No Policy decision, grant, mutable ledger or Rust handle is retained here.
(import (only-in :clan/poo/object .o) "./func.ss")
(export Policy.)
(def Policy. (.o validate: validate-source-policy!))
