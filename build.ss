#!/usr/bin/env gxi
;;; Yuanxu owns module selection; Gerbil owns build commands and executable links.
(import (for-syntax
          (only-in :std/source this-source-file)
          (only-in :yuanxu/module-system/building/source-package register-module-build-source!)))
(begin-syntax
  (register-module-build-source! (path-directory (this-source-file)) 'hardenedlinux/weaver))
(import (only-in :clan/poo/object .get)
        (only-in :std/make pkg-config-cflags pkg-config-libs)
        (only-in :yuanxu/module-system/building/script defbuild-script)
        (only-in "./init.ss" hardenedlinux/weaver.init.exports))

(def policy-package (getenv "WEAVER_POLICY_PKG_CONFIG_PACKAGE" "weaver-policy-ffi"))
(defbuild-script
  ((.get hardenedlinux/weaver.init.exports std-make-spec)
   (list `(gxc: "scheme/policy/cedar-ffi"
                "-cc-options" ,(pkg-config-cflags policy-package)
                "-ld-options" ,(pkg-config-libs policy-package))
         '(exe: "dev/scheme/module-inventory" bin: "weaver-module-inventory"))))
