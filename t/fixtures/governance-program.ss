;;; Explicit qualification application; no ABI implementation or implicit default.
(import (only-in :std/source this-source-file)
        (only-in :clan/poo/object .ref)
        (only-in ../../scheme/gateway/compiled install-gateway-producer!)
        ./governed-control)
(export main)
;;; Returning library initializer required by the SDK, not an executable target.
(def (main . _) (void))
;;; Qualification-only host input, fixed for this VM; never selected by RPC.
(def source-asset-root (getenv "WEAVER_TEST_GOVERNANCE_ASSET_ROOT" #f))
(unless (getenv "WEAVER_TEST_SKIP_PROGRAM_INSTALL" #f)
 (install-gateway-producer!
 (lambda (bundle)
   (let ((init (path-expand "../../init.ss" (path-directory (this-source-file)))))
     (capture-control-fixture init (if source-asset-root "assets-only" "policy-only")
       (.ref bundle 'tasks) (.ref bundle 'plans) (.ref bundle 'publication)
       (or source-asset-root "."))))))
