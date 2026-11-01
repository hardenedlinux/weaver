;;; Source compilation checks stay in the native Scheme test suite.
(import :std/test
        (only-in :std/error Error? Error-message)
        (only-in :clan/poo/object .o .get .slot? object-slots-set!)
        (only-in :clan/poo/mop TypeError?)
        (only-in :agentic-ai-lab/modules/governance/interface AgenticAILabGovernanceProfile. agentic-ai-lab-governance-source)
        (only-in :agentic-ai-lab/modules/authorization/providers/cedar/objects agentic-ai-lab-cedar-policy)
        (only-in ../scheme/policy/func project-policy)
        (only-in ../scheme/gateway/capture capture-gateway-source deliver-gateway-source)
        (only-in ../scheme/gateway/snapshot copy-source-data native->source-data source-data->native)
        (only-in ../scheme/gateway/program make-gateway-program)
        (prefix-in :clan/poo/testing/property/generator generator.)
        (prefix-in :clan/poo/testing/property property.)
        (only-in :clan/poo/testing/property/test check-property)
        ../scheme/gateway/func)
(export gateway-source-test)

(def commitment (make-string 64 #\a))
(def profile
  (.o (:: @ AgenticAILabGovernanceProfile.) identity: "weaver/test" revision: "1" owner: "operator"))
(def task
  (.o family: "family" principal: "agent" profile: "profile"
      provider_profile: (.o id: "profile" protocol: "openai.chat-text-sse.v1"
                            max_output_tokens: 32 max_messages: 4 max_body_bytes: 1024)
      nodes: '("infer") targets: '("primary" "backup")
      endpoints: (.o primary: "https://primary.invalid" backup: "https://backup.invalid")
      body_digests: (.o infer: commitment) node_cost_bounds: (.o infer: 4)
      stream_contracts: (.o infer: commitment) models: '("model") budget: 8))
(def plan
  (.o family: "family" node: "infer" profile: "profile" profile_commitment: commitment
      model: "model" body: "{}" ceiling: 4 revision: 0 fence: 1
      routes: (list (.o target: "primary" endpoint: "https://primary.invalid")
                    (.o target: "backup" endpoint: "https://backup.invalid"))))
(def source-publication
  (.o operation_id: "source" fence: 1 policy: "permit(principal,action,resource);" schema: "{}"))
(def bundle
  (.o governance: (.o schema: "agentic-ai-lab.loop-governor.v1" family: "family" open_nodes: '("infer"))
      tasks: (list task) plans: (list plan) publication: source-publication))
(def (refusal-message thunk)
  (with-catch (lambda (failure) (if (Error? failure) (Error-message failure) (raise failure)))
    (lambda () (thunk) #f)))

(def gateway-source-test
  (test-suite "Stable source assessment projection"
    (test-case "program returns independent typed data without borrowing an ambient sink"
      (let* ((program (make-gateway-program)) (held #f)
             (text (string-copy (.get source-publication policy))) (original (string-copy text))
             (input (.o (:: @ bundle) publication: (.o (:: @ source-publication) policy: text))))
        ((.get program install) (lambda (value) (set! held value) value))
        (let ((result ((.get program capture) input)))
          (string-set! text 0 #\x)
          (string-set! (.get (.get held publication) policy) 0 #\y)
          (check-equal? (.get (.get result publication) policy) original))))
    (test-case "a producer cannot return a Boolean in place of a typed source"
      (let ((program (make-gateway-program)))
        ((.get program install) (lambda (_) #t))
        (check-exception ((.get program capture) bundle) TypeError?)
        (check-equal? (refusal-message (lambda () ((.get program install) (lambda (value) value))))
                      "Gateway program installation is sealed")))
    (test-case "program lifecycle methods cannot be replaced through supported POO writes"
      (let ((program (make-gateway-program)))
        (check-equal? (refusal-message (lambda () (object-slots-set! program '()))) "sealed prototype")
        ((.get program install) (lambda (value) value))
        (check-equal? (gateway-source-json ((.get program capture) bundle)) (gateway-source-json bundle))
        (check-equal? (refusal-message (lambda () (object-slots-set! program '()))) "sealed prototype")))
    (test-case "program installation and close follow an irreversible lifecycle"
      (def report
        (property.check-property
          (generator.generator-sequence (map (lambda (_) (generator.generator-integer 0 3)) (iota 8)))
          (lambda (commands)
            (let ((program (make-gateway-program)) (phase 'uninstalled) (calls 0) (expected-calls 0))
              (def (produce value) (set! calls (1+ calls)) value)
              (and
                (andmap
                  (lambda (command)
                    (let* ((expected-refusal?
                            (cond ((= command 0) (not (eq? phase 'uninstalled)))
                                  ((= command 1) #t)
                                  ((= command 2) (not (eq? phase 'active)))
                                  (else #f)))
                           (result
                            (with-catch
                              (lambda (failure) (if (Error? failure) 'refused (raise failure)))
                              (lambda ()
                                (case command
                                  ((0) ((.get program install) produce))
                                  ((1) ((.get program install) #f))
                                  ((2) ((.get program capture) bundle))
                                  (else ((.get program close))))))))
                      (cond ((and (= command 0) (eq? phase 'uninstalled)) (set! phase 'active))
                            ((and (= command 2) (eq? phase 'active)) (set! expected-calls (1+ expected-calls)))
                            ((= command 3) (set! phase 'closed)))
                      (eq? (eq? result 'refused) expected-refusal?)))
                  commands)
                (= calls expected-calls))))
          (property.make-specification
            (lambda (commands) (and (list? commands) (= (length commands) 8)
                                   (andmap (lambda (command) (and (exact-integer? command) (<= 0 command 3))) commands)))
            (lambda (commands) (apply + commands)))
          seed: 293 cases: 128 size: 128 shrink-budget: 64))
      (check-property report)
      (check-equal? (property.report-accepted report) 128))
    (test-case "program contracts reject nested invalid data and recover on the same owner"
      (def invalid (.o (:: @ bundle) tasks: (list (.o (:: @ task) budget: "8"))))
      (def calls 0)
      (let ((program (make-gateway-program)))
        ((.get program install)
         (lambda (value) (set! calls (1+ calls)) (if (= calls 1) invalid value)))
        ;; Input refusal precedes the callback, so it cannot occupy the slot.
        (check-exception ((.get program capture) invalid) TypeError?)
        (check-equal? calls 0)
        ;; The installed Function contract still checks nested output fields.
        (check-exception ((.get program capture) bundle) TypeError?)
        (check-equal? calls 1)
        (check-equal? (gateway-source-json ((.get program capture) bundle))
                      (gateway-source-json bundle))
        (check-equal? calls 2)))
    (test-case "program close during callback fences output without holding the lifecycle lock"
      (let ((program (make-gateway-program)))
        ((.get program install)
         (lambda (value) ((.get program close)) value))
        (check-equal? (refusal-message (lambda () ((.get program capture) bundle)))
                      "Gateway program closed during capture")
        (check-equal? (refusal-message (lambda () ((.get program capture) bundle)))
                      "Gateway program is not active")))
    (test-case "caught program reentry cannot promote the outer result"
      (let ((program (make-gateway-program)))
        ((.get program install)
         (lambda (value)
           (check-equal? (refusal-message (lambda () ((.get program capture) value)))
                         "Gateway program capture is active")
           value))
        (check-equal? (refusal-message (lambda () ((.get program capture) bundle)))
                      "Gateway program closed during capture")))
    (test-case "native snapshot bounds and mutable leaf ownership"
      (let* ((text (make-string 8388608 #\a)) (image (copy-source-data text)))
        (check-equal? (string-length image) 8388608)
        (string-set! text 0 #\z)
        (check-equal? (string-ref image 0) #\a))
      (for-each
        (lambda (text)
          (check-equal? (refusal-message (lambda () (copy-source-data text)))
                        "Gateway source exceeds capture bound"))
        (list (make-string 8388609 #\a) (make-string 4194305 (integer->char 233)))))
    (test-case "SDK field symbols and identifier strings cannot be interchanged"
      (let ((fields (make-table test: equal?)) (identifiers (make-table test: equal?)))
        (table-set! fields "family" "replacement")
        (table-set! identifiers 'primary "https://primary.invalid")
        (check-equal? (refusal-message (lambda () (native->source-data fields)))
                      "Gateway bridge requires symbol field keys")
        (check-equal? (refusal-message (lambda () (native->source-data identifiers #t)))
                      "Gateway bridge requires string identifier keys"))
      (let ((image (native->source-data (source-data->native bundle))))
        (check-equal? (.get (.get image governance) family) "family")
        (check-equal? (.get (.get image publication) fence) 1)))
    (test-case "SDK data projection preserves typed fields without a JSON oracle"
      (def report
        (property.check-property
          (generator.generator-sequence
            (list (generator.generator-integer 0 5) (generator.generator-integer 0 1)
                  (generator.generator-integer 1 128)))
          (lambda (row)
            (let* ((counter (list-ref (list 0 1 (- (expt 2 53) 1) (expt 2 53)
                                           (+ (expt 2 53) 1) (- (expt 2 63) 1)) (car row)))
                   (present? (= (cadr row) 1))
                   (text (string-append (string (integer->char 0) (integer->char 955)
                                               (integer->char 128578))
                                       (make-string (caddr row) (integer->char 233))))
                   (pub-value (.o (:: @ source-publication) fence: counter policy: text))
                   (value (.o (:: @ bundle) publication:
                              (if present? (.o (:: @ pub-value) expected_revision: counter) pub-value)))
                   (image (native->source-data (source-data->native value)))
                   (actual (.get image publication))
                   (actual-task (car (.get image tasks))))
              (and (exact-integer? (.get actual fence)) (= (.get actual fence) counter)
                   (equal? (.get actual policy) text)
                   (eq? (.slot? actual 'expected_revision) present?)
                   (or (not present?)
                       (and (exact-integer? (.get actual expected_revision))
                            (= (.get actual expected_revision) counter)))
                   (equal? (.get actual-task family) (.get task family))
                   (= (.get actual-task budget) (.get task budget))
                   (equal? (.get actual-task nodes) (.get task nodes))
                   (equal? (.get (.get actual-task endpoints) primary)
                           (.get (.get task endpoints) primary)))))
          (property.make-specification
            (lambda (row) (and (list? row) (= (length row) 3)
                              (andmap exact-integer? row) (<= 0 (car row) 5)
                              (<= 0 (cadr row) 1) (<= 1 (caddr row) 128)))
            (lambda (row) (apply + row)))
          seed: 293 cases: 128 size: 128 shrink-budget: 64))
      (check-property report)
      (check-equal? (property.report-accepted report) 128))
    (test-case "delivery outside typed capture refuses"
      (check-equal? (refusal-message (lambda () (deliver-gateway-source bundle)))
                    "Gateway delivery requires an active typed capture"))
    (test-case "native PBT requires one completed emission and an independent image"
      (def report
        (property.check-property
          (generator.generator-sequence
            (list (generator.generator-integer 0 3) (generator.generator-integer 0 1)
                  (generator.generator-integer 1 128) (generator.generator-integer 0 1)))
          (lambda (row)
            (let* ((count (car row)) (complete? (= (cadr row) 1))
                   (text (make-string (caddr row) #\a)) (original (string-copy text))
                   (outcome
                    (with-catch (lambda (failure) (if (Error? failure) 'refused (raise failure)))
                      (lambda ()
                        (capture-gateway-source
                          (lambda ()
                            (when (= (cadddr row) 1)
                              (refusal-message (lambda () (deliver-gateway-source ""))))
                            (for-each
                              (lambda (_)
                                ;; Swallowing a duplicate exception cannot clear its fuse.
                                (with-catch (lambda (failure) (if (Error? failure) #f (raise failure)))
                                  (lambda () (deliver-gateway-source (.o (:: @ bundle) publication: (.o (:: @ source-publication) policy: text)))))) (iota count))
                            (string-set! text 0 #\z)
                            complete?))))))
              (if (and (= count 1) complete? (= (cadddr row) 0))
                (and (not (eq? outcome 'refused)) (equal? (.get (.get outcome publication) policy) original)) (eq? outcome 'refused))))
          (property.make-specification
            (lambda (row) (and (list? row) (= (length row) 4) (andmap exact-integer? row)
                              (<= 0 (car row) 3) (<= 0 (cadr row) 1) (<= 1 (caddr row) 128)
                              (<= 0 (cadddr row) 1)))
            (lambda (row) (apply + row)))
          seed: 293 cases: 128 size: 128 shrink-budget: 64
          policy: (property.make-policy name: 'one-completed-source-image
                    labels: (lambda (row) (list (list-ref '(zero one two three) (car row))
                                               (if (= (cadr row) 1) 'completed 'incomplete)
                                               (if (= (cadddr row) 1) 'invalid-first 'clean)))
                    required: '((zero . 1) (one . 1) (two . 1) (three . 1) (completed . 1) (incomplete . 1)
                                (invalid-first . 1) (clean . 1)))))
      (check-property report)
      (check-equal? (property.report-accepted report) 128))
    (test-case "concurrent emissions serialize and poison a caught duplicate"
      (check-equal?
        (refusal-message
          (lambda ()
            (capture-gateway-source
              (lambda ()
                (let ((workers
                       (map (lambda (text)
                              (thread-start!
                                (make-thread
                                  (lambda ()
                                    (with-catch (lambda (failure) (if (Error? failure) #f (raise failure)))
                                      (lambda () (deliver-gateway-source bundle))))))) '("first" "second"))))
                  (for-each thread-join! workers)
                  #t)))))
        "Gateway capture requires one source emission"))
    (test-case "producer failure discards its image before another capture"
      (check-equal?
        (refusal-message
          (lambda ()
            (capture-gateway-source
              (lambda () (deliver-gateway-source bundle) (error "source failed after emission")))))
        "source failed after emission")
      (check-equal? (gateway-source-json (capture-gateway-source (lambda () (deliver-gateway-source bundle)))) (gateway-source-json bundle)))
    (test-case "caught invalid emission cannot be replaced inside the same capture"
      (check-equal?
        (refusal-message
          (lambda ()
            (capture-gateway-source
              (lambda ()
                (refusal-message (lambda () (deliver-gateway-source "")))
                (refusal-message (lambda () (deliver-gateway-source bundle)))
                #t))))
        "Gateway capture requires one source emission"))
    (test-case "a late inherited sink cannot replace an active next capture"
      (def release (make-mutex 'late-source-emission))
      (def release-held? #t)
      (def worker #f)
      (def image #f)
      (def next #f)
      (def late #f)
      (mutex-lock! release)
      (dynamic-wind void
        (lambda ()
          (set! image
            (capture-gateway-source
              (lambda ()
                (set! worker
                  (thread-start!
                    (make-thread
                      (lambda ()
                        (mutex-lock! release) (mutex-unlock! release)
                        (refusal-message (lambda () (deliver-gateway-source bundle)))))))
                (deliver-gateway-source bundle))))
          (set! next
            (capture-gateway-source
              (lambda ()
                (mutex-unlock! release) (set! release-held? #f)
                (set! late (thread-join! worker)) (set! worker #f)
                (deliver-gateway-source bundle)))))
        (lambda ()
          (when release-held? (mutex-unlock! release))
          (when worker (set! late (thread-join! worker)))))
      (check-equal? (gateway-source-json image) (gateway-source-json bundle))
      (check-equal? (gateway-source-json next) (gateway-source-json bundle))
      (check-equal? late "Gateway capture has ended"))
    (test-case "SDK sorted JSON preserves source identity and significant order"
      (def first (gateway-source-json bundle))
      (for-each (lambda (_) (check-equal? (gateway-source-json bundle) first)) (iota 16))
      (check (equal? first
                     (gateway-source-json (.o (:: @ bundle)
                       publication: (.o (:: @ source-publication) policy: "forbid(principal,action,resource);")))) => #f)
      (check (equal? first
                     (gateway-source-json (.o (:: @ bundle)
                       plans: (list (.o (:: @ plan) routes: (reverse (.get plan routes))))))) => #f))
    (test-case "assessed compilation owns its image across all delegated callbacks"
      (def field-labels '(policy schema family endpoint nodes routes profile root policy-id asset-path))
      (def phase-labels '(after-return assessment reproject project governor preflight))
      (def report
        (property.check-property
          (generator.generator-sequence
            (list (generator.generator-integer 0 9) (generator.generator-integer 0 5)
                  (generator.generator-integer 1 128)))
          (lambda (row)
            (let* ((field (car row)) (phase (cadr row)) (projections 0)
                   (policy-text (string-append (.get source-publication policy) (make-string (caddr row) #\space)))
                   (expected-policy (string-copy policy-text)) (schema-text (string-copy "{}"))
                   (family-text (string-copy "family")) (endpoint-text (string-copy "https://primary.invalid"))
                   (profile-label (string-copy "weaver/test")) (root-text (string-copy "."))
                   (policy-id-text (string-copy "weaver/runtime")) (asset-path-text (string-copy "policy.cedar"))
                   (native-policy (agentic-ai-lab-cedar-policy policy-id-text (string-copy policy-text)))
                   (profile-value (.o (:: @ profile) identity: profile-label policies: (.o runtime: native-policy)
                                      source-assets: (list (agentic-ai-lab-governance-source "weaver/runtime" asset-path-text 'cedar))))
                   (node-values (list "infer")) (route-values (copy-source-data (.get plan routes)))
                   (task-value (.o (:: @ task) family: family-text nodes: node-values
                                  endpoints: (.o primary: endpoint-text backup: "https://backup.invalid")))
                   (plan-value (.o (:: @ plan) family: family-text routes: route-values))
                   (pub-value (.o (:: @ source-publication) policy: policy-text schema: schema-text)))
              (def (mutate!)
                (case field
                  ((0) (string-set! policy-text 0 #\x))
                  ((1) (string-set! schema-text 0 #\x))
                  ((2) (string-set! family-text 0 #\x))
                  ((3) (string-set! endpoint-text 0 #\x))
                  ((4) (set-car! node-values "changed"))
                  ((5) (set-car! route-values (.o target: "changed" endpoint: "https://changed.invalid")))
                  ((6) (string-set! profile-label 0 #\x))
                  ((7) (string-set! root-text 0 #\x))
                  ((8) (string-set! policy-id-text 0 #\x))
                  (else (string-set! asset-path-text 0 #\x))))
              (def (project-image p text root)
                (set! projections (1+ projections))
                (when (or (and (= phase 3) (= projections 1))
                          (and (= phase 2) (= projections 2))) (mutate!))
                (project-policy p text '() root))
              (def outcome
                (with-catch (lambda (failure) (if (Error? failure) 'refused (raise failure)))
                  (lambda ()
                    (compile-gateway
                      (.o open: (lambda (_governor _states) (when (= phase 4) (mutate!)) '("infer"))
                          assess: (lambda (_profile _context) (when (= phase 1) (mutate!)) #t))
                      (.o validate: (lambda (_policy _schema) (when (= phase 5) (mutate!)) #t)
                          project: project-image)
                      #f profile-value (.o request: 'publish source_root: root-text)
                      '() (list task-value) (list plan-value) pub-value))))
              (if (= phase 0)
                (begin
                  (mutate!)
                  (and (not (eq? outcome 'refused))
                       (equal? (.get (.get outcome publication) policy) expected-policy)
                       (equal? (.get (.get outcome publication) schema) "{}")
                       (equal? (.get (car (.get outcome tasks)) family) "family")
                       (equal? (.get (car (.get outcome tasks)) nodes) '("infer"))
                       (equal? (.get (.get (car (.get outcome tasks)) endpoints) primary) "https://primary.invalid")
                       (equal? (.get (car (.get (car (.get outcome plans)) routes)) target) "primary")))
                (eq? outcome 'refused))))
          (property.make-specification
            (lambda (row) (and (list? row) (= (length row) 3) (andmap exact-integer? row)
                              (<= 0 (car row) 9) (<= 0 (cadr row) 5) (<= 1 (caddr row) 128)))
            (lambda (row) (apply + row)))
          seed: 293 cases: 128 size: 128 shrink-budget: 64
          policy: (property.make-policy name: 'assessed-source-ownership
                    labels: (lambda (row) (list (list-ref field-labels (car row))
                                               (list-ref phase-labels (cadr row))))
                    required: (map (lambda (label) (cons label 1)) (append field-labels phase-labels)))))
      (check-property report)
      (check-equal? (property.report-accepted report) 128))
    (test-case "a false Policy preflight cannot emit a source handoff"
      (check-equal?
        (refusal-message
          (lambda ()
            (compile-gateway (.o open: (lambda (_governor _states) '("infer")))
                             (.o validate: (lambda (_policy _schema) #f)
                                 project: (lambda (p text root) (project-policy p text '() root)))
                             #f profile (.o request: 'publish) '() (list task) (list plan) source-publication)))
        "Policy preflight declined the source handoff"))
    (test-case "a false Governance assessment cannot emit a source handoff"
      (check-equal?
        (refusal-message
          (lambda ()
            (compile-gateway (.o open: (lambda (_governor _states) '("infer"))
                                assess: (lambda (_profile _context) #f))
                             (.o validate: (lambda (_policy _schema) #t)
                                 project: (lambda (p text root) (project-policy p text '() root)))
                             #f profile (.o request: 'publish) '() (list task) (list plan) source-publication)))
        "Governance declined the source handoff"))))
