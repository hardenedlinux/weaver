;;; SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
;;;
;;; SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

(export Build)
(def Build
  (.o kind: 'module/build
      roots: (if (getenv "CARGO_FEATURE_SCHEME_PROGRAM" #f)
               (if (equal? (getenv "WEAVER_GOVERNANCE_APPLICATION" "")
                           "hardenedlinux/weaver/scheme/gateway/provider-program")
                 '("provider-source" "compiled" "provider-program")
                 '("provider-source" "compiled"))
               '("provider-source"))))
