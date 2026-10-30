;;; No Policy decision, grant, mutable ledger or Rust handle is retained here.
(import (only-in :clan/poo/object .o) "./func.ss" "./assets.ss")
(export Policy.)
(def Policy.
  (.o validate: validate-source-policy!
      project: (lambda (profile expected root)
                 (project-policy profile expected (read-policy-assets profile root) root))))
