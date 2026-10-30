;;; Root package build. Yuanxu owns selection/guards; the SDK owns compilation.
(import (for-syntax
          (only-in :std/source this-source-file)
          (only-in :yuanxu/module-system/building/source-package register-module-build-source!)))
(begin-syntax
  (register-module-build-source! (path-directory (this-source-file)) 'hardenedlinux/weaver))
(import (only-in :clan/poo/object .get)
        (only-in :std/source this-source-file)
        (only-in :yuanxu/module-system/building/script defbuild-script)
        (only-in "./init.ss" hardenedlinux/weaver.init.exports))

(def root (path-directory (this-source-file)))
(def rust-policy-library (path-expand "target/debug" root))
(def policy-ffi-spec
  `(gxc: "scheme/policy/cedar-ffi"
         "-cc-options" ,(string-append "-I" (path-expand "crates/policy-ffi/include" root))
         "-ld-options" ,(string-append "-L" rust-policy-library " -lweaver_policy_ffi -Wl,-rpath," rust-policy-library)))
(def library-spec (list policy-ffi-spec))
(def modules-spec (.get hardenedlinux/weaver.init.exports std-make-spec))
(defbuild-script (modules-spec library-spec))
