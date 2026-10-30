;;; Development packaging inventory. The SDK still owns tests and assertions.
prelude: :gerbil/core
;;; Evaluate exported suite values through the same public expander boundary
;;; as gxtest; do not execute test cases or scan the installed SDK tree.
(import :gerbil/expander)
(export main)

(def (main . files)
  (for-each
    (lambda (file)
      (let (context (import-module file #f #t))
        (for-each
          (lambda (exported)
            (when (zero? (module-export-phi exported))
              (eval (binding-id (core-resolve-module-export exported)))))
          (module-context-export context))))
    files)
  (call-with-output-file (getenv "WEAVER_MODULE_INVENTORY")
    (lambda (port)
      (for-each
        (lambda (entry)
          (when (string? (cdr entry))
            (display (car entry) port)
            (display "\t" port)
            (display (cdr entry) port)
            (newline port)))
        (list-modules))))
  (displayln "MODULE-INVENTORY-COMPLETE")
  (force-output))
