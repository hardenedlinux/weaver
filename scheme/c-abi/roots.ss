;;; SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
;;; SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

;;; Rust owns the root service. Scheme packages never import the Rust SDK.
(export weaver-rooted-call)
(extern root-procedure apply-procedure release-procedure)
(def (weaver-rooted-call input procedure)
  (let (callback (root-procedure procedure))
    (with-unwind-protect
      (lambda () (apply-procedure callback input))
      (lambda () (release-procedure callback)))))
(begin-foreign
  (namespace ("hardenedlinux/weaver/scheme/c-abi/roots#" root-procedure apply-procedure release-procedure))
  (c-declare "extern ___S64 gerbil_scheme_rust_object_root_raw(___SCMOBJ);\nextern ___S64 gerbil_scheme_rust_apply_rooted(___S64, ___S64);\nextern ___S32 gerbil_scheme_rust_root_release_raw(___S64);")
  (define root-procedure (c-lambda (scheme-object) int64 "gerbil_scheme_rust_object_root_raw"))
  (define apply-procedure (c-lambda (int64 int64) int64 "gerbil_scheme_rust_apply_rooted"))
  (define release-procedure (c-lambda (int64) int32 "gerbil_scheme_rust_root_release_raw")))
