;;; SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
;;;
;;; SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

(import (only-in :std/make pkg-config-cflags pkg-config-libs))
(export Build)
(def policy-package (getenv "WEAVER_POLICY_PKG_CONFIG_PACKAGE" "weaver-policy-ffi"))
(def Build
  (.o kind: 'module/build
      roots: `((gxc: "cedar-ffi"
                "-cc-options" ,(pkg-config-cflags policy-package)
                "-ld-options" ,(pkg-config-libs policy-package)))))
