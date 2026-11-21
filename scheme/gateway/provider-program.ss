;;; SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
;;;
;;; SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

;;; Build-selected initializer for Weaver's declared provider workflows.
(import (only-in :clan/poo/object .o .get .ref)
        (only-in :tao3k/yuanxu/prelude yuanxu-build-autoloads)
        (for-syntax (only-in "../c-abi/build.ss" Build))
        (only-in "../interface.ss" LabGovernance LabCedar)
        (only-in :tao3k/yuanxu/module-system/source/admission call-with-module-source-operation-measurement)
        :hardenedlinux/weaver/scheme/policy/cedar-ffi
        (only-in "./compiled.ss" install-gateway-producer!)
        "../c-abi/gateway.ss"
        (only-in "./func.ss" capture-compiled-gateway gateway-source-phase-observer)
        "./provider-source.ss")
(export main)
(def (main . _) (void))
(yuanxu-build-autoloads Build gateway)

(def policy-root (getenv "WEAVER_GOVERNANCE_POLICY_ROOT" #f))

;;; Use the existing Reader's private scalar accounting. A diagnostic cannot
;;; supply a callback during admission, retain contexts or change the result.
;;; Keep it separate from ordinary phase timing and report exceptional exits.
(def (capture-source action)
  (if (not (getenv "WEAVER_TEST_SOURCE_PROFILE" #f)) (action)
    (let ((failed? #f) (failure #f))
      (let-values (((result times)
                    (call-with-module-source-operation-measurement
                      (lambda ()
                        (with-catch
                          (lambda (exception)
                            (set! failed? #t) (set! failure exception) #f)
                          action))
                      accounting?: 'stages)))
        (let (port (current-error-port))
          (hash-for-each
            (lambda (key value)
              (display "weaver scheme phase=source-profile metric=" port)
              (write key port) (display " value=" port) (write value port)
              (newline port)) times)
          (force-output port))
        (if failed? (raise failure) result)))))

(def (capture bundle)
  (def schema (.ref (.ref bundle 'governance) 'schema))
  (def publication (.ref bundle 'publication))
  (def policy ((.get LabCedar policy) "weaver/runtime" (.ref publication 'policy)))
  (def profile
    (.o (:: @ (.get LabGovernance Profile))
        identity: "weaver/source" revision: "1" owner: "source-owner"
        policies: (.o runtime: policy)
        source-assets: (if policy-root
                         (list ((.get LabGovernance source) "weaver/runtime" "policy.cedar" 'cedar))
                         '())))
  (def controls (provider-source-controls schema))
  (def governor (car controls))
  (def context
    (if policy-root (.o (:: @ (cadr controls)) source_root: policy-root) (cadr controls)))
  (def phase-observer (gateway-source-phase-observer))
  (when phase-observer (phase-observer "compile-begin"))
  (begin0
    (capture-source
      (lambda ()
        (capture-compiled-gateway (gateway-scope) governor profile context '()
          (.ref bundle 'tasks) (.ref bundle 'plans) publication)))
    (when phase-observer (phase-observer "source-captured"))))

(install-gateway-producer! capture)
