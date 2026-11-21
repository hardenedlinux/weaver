;;; SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
;;; SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0
(import (only-in :clan/poo/object .def .o)
        (only-in :std/make pkg-config-libs))
(export Build)
(.def Build
  defbuild-script:
  (.o spec:
      (append
        (cond-expand
          (darwin '((gxc: "roots" "-ld-options" "-Wl,-undefined,dynamic_lookup")))
          (else '("roots")))
        '("gateway")))
  autoload:
  (.o gateway:
      (.o module: ':hardenedlinux/weaver/scheme/gateway/config
          exports: (.o gateway-scope: 'gateway-scope))
      operations:
      (.o module: ':hardenedlinux/weaver/scheme/gateway/compiled
          exports: (.o ready: 'ready capture-request: 'capture-request
                       derive-request: 'derive-request compose-request: 'compose-request
                       session-turn-request: 'session-turn-request
                       fact-impact-request: 'fact-impact-request
                       install-capture-cancel!: 'install-capture-cancel!)))
  with-link:
  (lambda () ["-ld-options" (pkg-config-libs "openssl" "zlib" "sqlite3")]))
