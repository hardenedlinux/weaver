;;; SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
;;;
;;; SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

;;; Native Governor selection belongs to Scheme's standard test suite.
(import :std/test
        (only-in :std/error Error? Error-message)
        :agentic-ai-lab/modules/loop-engine/control/governor
        :agentic-ai-lab/modules/loop-engine/control/strategy
        :agentic-ai-lab/modules/loop-engine/control/descriptor
        :agentic-ai-lab/modules/governance/interface
        (only-in :clan/poo/object .o .get)
        (prefix-in :clan/poo/testing/property/generator generator.)
        (prefix-in :clan/poo/testing/property property.)
        (only-in :clan/poo/testing/property/test check-property)
        (only-in ../scheme/governance/objects Governance.)
        (only-in ../scheme/gateway/func governor-open-nodes))
(export governance-test)
(def (assess-governance! profile context) ((.get Governance. assess) profile context))

;;; The upstream framework owns generation, shrinking, coverage and replay.
(def (binding-case row)
  (def p-id (string-copy "weaver/test"))
  (def p-revision (string-copy "revision-123"))
  (def p-owner (string-copy "operator"))
  (def m-id (string-copy "weaver/model"))
  (def source-value (string-copy "{\"original\":true}"))
  (def policy-value (string-copy "[\"policy\"]"))
  (def evidence-value (string-copy "evidence:original"))
  (def threat-id (string-copy "weaver/latent"))
  (def model (agentic-ai-lab-governance-threat-model m-id
    (list (agentic-ai-lab-governance-threat threat-id 'low 'latent
      (list (agentic-ai-lab-governance-precondition "weaver/input" #t evidence-value))))))
  (def context (.o request: 'publish source: source-value policy_inputs: policy-value
                  profile_identity: p-id profile_revision: p-revision profile_owner: p-owner model_identity: m-id))
  (def profile
    (.o (:: @ AgenticAILabGovernanceProfile.) identity: p-id revision: p-revision owner: p-owner threat-model: model
        .assess-governance: (lambda (current)
          (when (= (list-ref row 3) 1)
            (let* ((text (list-ref (list p-id p-revision p-owner m-id source-value policy-value evidence-value threat-id) (car row)))
                   (index (modulo (list-ref row 1) (string-length text)))
                   (character (integer->char (+ (char->integer #\a) (list-ref row 2)))))
              (string-set! text index (if (char=? character (string-ref text index))
                                       (if (char=? character #\z) #\a #\z) character))))
          (agentic-ai-lab-governance-assessment profile current))))
  (with-catch (lambda (failure) (if (Error? failure) (Error-message failure) (raise failure)))
    (lambda () (assess-governance! profile context) 'accepted)))

(def (governor overrides)
  (make-loop-governor 'weaver
    (make-loop-strategy-plan 'weaver-routing
      (list (make-loop-pattern-descriptor 'infer "Original inference" '((level . l2)))
            (make-loop-pattern-descriptor 'next "Original continuation" '((level . l2)))))
    overrides))

(def governance-test
  (test-suite "Governor source handoff"
    (test-case "original open patterns are selected"
      (check-equal? (governor-open-nodes
                     (governor '((aggregate-budget . ((max-actionable . 2))))) '())
                    '("infer" "next")))
    (test-case "denylist removes candidates from the final handoff"
      (check-equal? (governor-open-nodes
                     (governor '((shared-denylist . (infer))
                                 (aggregate-budget . ((max-actionable . 2))))) '())
                    '("next")))
    (test-case "an active source snapshot excludes the occupied pattern"
      (check-equal? (governor-open-nodes
                     (governor '((aggregate-budget . ((max-actionable . 2)))))
                     '(((acting_on . infer)))) '("next")))
    (test-case "aggregate clipping applies to the final handoff"
      (check-equal? (length (governor-open-nodes
                             (governor '((aggregate-budget . ((max-actionable . 1))))) '())) 1))
    (test-case "a ready assessment is bound to its exact source context"
      (def context (.o request: 'publish source: "{\"original\":true}" policy_inputs: "[]"
                      profile_identity: "weaver/test" profile_revision: "1" profile_owner: "operator"
                      model_identity: "agentic-ai-lab/governance/threat-model/empty"))
      (def profile
        (.o (:: @ AgenticAILabGovernanceProfile.)
            identity: "weaver/test" revision: "1" owner: "operator"))
      (check (assess-governance! profile context) => #t)
      (check-exception (assess-governance! profile (.o request: 'publish)) Error?))
    (test-case "shared mutable identity cannot launder the original Profile binding"
      (def original-profile-id (string-copy "weaver/test"))
      (def context (.o request: 'publish source: "{\"original\":true}" policy_inputs: "[]"
                      profile_identity: original-profile-id profile_revision: "1" profile_owner: "operator"
                      model_identity: "agentic-ai-lab/governance/threat-model/empty"))
      (def profile
        (.o (:: @ AgenticAILabGovernanceProfile.) identity: original-profile-id revision: "1" owner: "operator"
            .assess-governance: (lambda (current)
              (string-set! original-profile-id 0 #\x)
              (agentic-ai-lab-governance-assessment profile current))))
      (check-equal?
        (with-catch (lambda (failure) (if (Error? failure) (Error-message failure) (raise failure)))
          (lambda () (assess-governance! profile context) 'accepted))
        "Governance source changed during assessment"))
    (test-case "native PBT preserves every original assessment binding across alias mutation"
      (def labels '(profile-identity profile-revision profile-owner model-identity source policy-inputs precondition-evidence threat-identity))
      (def report
        (property.check-property
          (generator.generator-sequence
            (list (generator.generator-integer 0 7) (generator.generator-integer 0 127)
                  (generator.generator-integer 0 25) (generator.generator-integer 0 1)))
          (lambda (row) (equal? (binding-case row)
                         (if (= (list-ref row 3) 1) "Governance source changed during assessment" 'accepted)))
          (property.make-specification
            (lambda (row) (and (list? row) (= (length row) 4) (andmap exact-integer? row)
                              (<= 0 (car row) 7) (<= 0 (list-ref row 1) 127)
                              (<= 0 (list-ref row 2) 25) (<= 0 (list-ref row 3) 1)))
            (lambda (row) (apply + row)))
          seed: 293 cases: 128 size: 128 shrink-budget: 64
          policy: (property.make-policy name: 'original-assessment-bindings
                    labels: (lambda (row) (list (list-ref labels (car row))
                                               (if (= (list-ref row 3) 1) 'mutated 'stable)))
                    required: (map (lambda (label) (cons label 1)) (append labels '(mutated stable))))))
      (check-property report)
      (check-equal? (property.report-accepted report) 128))
    (test-case "a typed ready assessment cannot omit an original blocking threat"
      (def assessment-calls 0)
      (def context (.o request: 'publish source: "{\"original\":true}" policy_inputs: "[]"
                      profile_identity: "weaver/test" profile_revision: "1" profile_owner: "operator"
                      model_identity: "weaver/blocking"))
      (def model
        (agentic-ai-lab-governance-threat-model "weaver/blocking"
          (list (agentic-ai-lab-governance-threat "weaver/exposed" 'critical 'realized
                  (list (agentic-ai-lab-governance-precondition "weaver/input" #t "evidence:input"))))))
      (def profile
        (.o (:: @ AgenticAILabGovernanceProfile.)
            identity: "weaver/test" revision: "1" owner: "operator"
            threat-model: model
            .assess-governance:
            (lambda (current)
              (set! assessment-calls (1+ assessment-calls))
              (agentic-ai-lab-governance-assessment-value profile model '() current))))
      (check-exception (assess-governance! profile context) Error?)
      (check-equal? assessment-calls 0))))
