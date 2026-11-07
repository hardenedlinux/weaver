;;; SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
;;; SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0
(import (only-in "../../../init.ss" hardenedlinux/weaver.init.exports)
        (only-in :clan/poo/object .get .o .cc .slot?)
        (only-in :std/source this-source-file)
        (only-in :yuanxu/module-system/source/admission call-with-module-source-operation-measurement)
        (only-in :std/misc/ports read-all-as-string)
        (only-in :gerbil/runtime/loader list-modules)
        (only-in :agentic-ai-lab/modules/governance/interface
                 agentic-ai-lab-governance-profile?))
(export main)
(def (main)
  (unless (and (procedure? agentic-ai-lab-governance-profile?)
               (ormap (lambda (row)
                        (equal? (car row) "agentic-ai-lab/modules/governance/interface~0"))
                      (list-modules))
               (.slot? hardenedlinux/weaver.init.exports 'Lab)
               (.slot? hardenedlinux/weaver.init.exports 'Weaver))
    (error "Gerbil Governance import or Yuanxu export layout differs"))
  (defvalues (lab first)
    (call-with-module-source-operation-measurement
      (lambda () (.get hardenedlinux/weaver.init.exports Lab governance)) accounting?: #f))
  (unless (and (= (hash-ref first '(calls candidate-read) 0) 4)
               (= (hash-ref first '(calls scope-factory) 0) 1)
               (= (hash-ref first '(calls (scope-factory agentic-ai-lab/modules/governance/interface)) 0) 1)
               (= (hash-ref first '(calls (scope-factory hardenedlinux/weaver/scheme/governance/interface)) 0) 0))
    (error "first Lab scope demand constructed an unrelated or conflated owner"))
  (defvalues (again repeat)
    (call-with-module-source-operation-measurement
      (lambda () (.get hardenedlinux/weaver.init.exports Lab governance)) accounting?: #f))
  (unless (and (eq? lab again) (zero? (hash-ref repeat '(calls candidate-read) 0))
               (zero? (hash-ref repeat '(calls scope-factory) 0)))
    (error "repeated native scope demand did not reuse its POO slot"))
  (displayln "WEAVER-MODULE-FIRST-GET declarations=4 scopes=1 repeat-scopes=0")
  (def local (.get hardenedlinux/weaver.init.exports Weaver governance))
  (unless (and (not (eq? lab local))
               (eq? lab (.get hardenedlinux/weaver.init.exports Lab governance))
               (eq? local (.get hardenedlinux/weaver.init.exports Weaver governance)))
    (error "native roots or repeated scope identities were conflated"))
  (def profile (.cc (.get lab Profile) identity: "weaver/selected" revision: "1" owner: "operator"))
  (unless (agentic-ai-lab-governance-profile? profile) (error "selected native public Profile rejected its scope value"))
  (def context (.o request: 'publish source: "{\"original\":true}" policy_inputs: "[]"
                  profile_identity: "weaver/selected" profile_revision: "1" profile_owner: "operator"
                  model_identity: "agentic-ai-lab/governance/threat-model/empty"))
  (unless ((.get local assess) profile context) (error "Weaver Governance business assessment failed"))
  (def policy (.get hardenedlinux/weaver.init.exports Weaver policy))
  (def schema (call-with-input-file
    (path-expand "../../../prod/policies/provider/schema.json" (path-directory (this-source-file)))
    read-all-as-string))
  (unless ((.get policy validate) "forbid(principal,action,resource);" schema)
    (error "selected Cedar FFI business validation failed"))
  (def gateway (.get hardenedlinux/weaver.init.exports Weaver gateway))
  (unless (procedure? (.get gateway compile)) (error "Gateway business entry is absent"))
  (def prefix (string-append (path-strip-trailing-directory-separator
                              (path-normalize (path-expand "lib" (gerbil-path)))) "/"))
  (for-each
    (lambda (id)
      (unless (ormap (lambda (row)
                       (and (equal? (car row) id) (string-prefix? prefix (cdr row))))
                     (list-modules))
        (error "business runtime did not load its own selected product" id)))
    '("agentic-ai-lab/modules/governance/interface~0"
      "agentic-ai-lab/modules/governance/types~0"
      "agentic-ai-lab/modules/authorization/providers/cedar/objects~0"
      "agentic-ai-lab/modules/loop-engine/control/governor-core~0"
      "hardenedlinux/weaver/scheme/policy/cedar-ffi~0"))
  (displayln "WEAVER-MODULE-USE-OK roots=Lab/Weaver same-leaf=distinct repeat=same governance=ready cedar=valid gateway=present products=own"))
