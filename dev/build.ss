#!/usr/bin/env gxi
;;; The existing init owns executable admission; Gerbil owns build dispatch.
(import (only-in :clan/poo/object .get .call)
        (only-in :std/source this-source-file)
        (only-in :std/make pkg-config-libs)
        (only-in :yuanxu/module-system/building/script defbuild-script)
        (only-in "../init.ss" hardenedlinux/weaver.init.exports))

(def root (path-expand ".." (path-directory (this-source-file))))
(def demand
  (.call (.get hardenedlinux/weaver.init.exports tests) .for-files
    (list (path-expand "dev/scheme/module-inventory.ss" root))
    (list (path-expand "dev/build.ss" root))
    (list `(exe: "dev/scheme/module-inventory" bin: "weaver-module-inventory"
                "-ld-options" ,(pkg-config-libs "libcrypto < 4")))))
(defbuild-script ((.get demand std-make-spec)) srcdir: root)
