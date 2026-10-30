;;; POO owns deferred compiled-module loading; source discovery never runs C FFI.
(import (only-in :clan/poo/io module-action))
(export validate-source-policy!)
(def cedar-validation
  (module-action "hardenedlinux/weaver/scheme/policy/cedar-ffi"
                 'hardenedlinux/weaver/scheme/policy/cedar-ffi#validate-source-policy!))
(def (validate-source-policy! policy-source schema-source)
  (cedar-validation (list policy-source schema-source)))
