;;; SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
;;;
;;; SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

;;; Explicit qualification application; no ABI implementation or implicit default.
(import (only-in :std/source this-source-file)
        (only-in :clan/poo/object .ref)
        (only-in :yuanxu/module-system/source/admission call-with-module-source-operation-measurement)
        (only-in ../../scheme/gateway/compiled install-gateway-producer!)
        ./governed-control)
(export main)
;;; Returning library initializer required by the SDK, not an executable target.
(def (main . _) (void))
;;; Qualification-only host inputs, fixed for this VM; never selected by RPC.
(def source-asset-root (getenv "WEAVER_TEST_GOVERNANCE_ASSET_ROOT" #f))
(def measure-source? (getenv "WEAVER_TEST_SOURCE_MEASURE" #f))
(def (produce bundle)
  (let ((init (path-expand "../../init.ss" (path-directory (this-source-file)))))
    (capture-control-fixture init (if source-asset-root "assets-only" "policy-only")
      (.ref bundle 'tasks) (.ref bundle 'plans) (.ref bundle 'publication)
      (or source-asset-root "."))))
(def (produce-measured bundle)
  ;; Upstream owns operation accounting. Emit only fixed metric keys/scalars;
  ;; profiling never supplies an approval, source cache or replacement result.
  (call-with-values
    (lambda () (call-with-module-source-operation-measurement (lambda () (produce bundle))))
    (lambda (result metrics)
      (hash-for-each
        (lambda (key value)
          (let ((port (current-error-port)))
            (display "weaver source metric=" port) (write key port)
            (display " value=" port) (write value port) (newline port))) metrics)
      (force-output (current-error-port))
      result)))
(unless (getenv "WEAVER_TEST_SKIP_PROGRAM_INSTALL" #f)
  (install-gateway-producer!
    (lambda (bundle) (if measure-source? (produce-measured bundle) (produce bundle)))))
