;;; Explicit qualification application; no ABI implementation or implicit default.
(import (only-in :std/source this-source-file)
        (only-in :clan/poo/object .ref)
        (only-in ../../scheme/gateway/compiled install-gateway-producer!)
        ./governed-control)
(export main)
;;; Returning library initializer required by the SDK, not an executable target.
(def (main . _) (void))
(unless (getenv "WEAVER_TEST_SKIP_PROGRAM_INSTALL" #f)
 (install-gateway-producer!
 (lambda (bundle)
   (let ((init (path-expand "../../init.ss" (path-directory (this-source-file)))))
     (capture-control-fixture init "policy-only"
       (.ref bundle 'tasks) (.ref bundle 'plans) (.ref bundle 'publication) ".")))))
