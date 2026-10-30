#!/usr/bin/env gxi
;;; Yuanxu owns module selection; Gerbil owns build commands and executable links.
(import (for-syntax
          (only-in :std/source this-source-file)
          (only-in :yuanxu/module-system/building/source-package register-module-build-source!)))
(begin-syntax
  (register-module-build-source! (path-directory (this-source-file)) 'hardenedlinux/weaver))
(import (only-in :yuanxu/module-system/building/script defbuild-script)
        (only-in "./dev/scheme/build-spec.ss" weaver-build-spec))

(defbuild-script
  (weaver-build-spec
    '((exe: "dev/scheme/module-inventory" bin: "weaver-module-inventory"))))
