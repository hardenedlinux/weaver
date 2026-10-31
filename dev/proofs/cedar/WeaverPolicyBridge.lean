import CedarPooSpec.Admission.BoundOperation

/- Authenticated host contract: actual effect/state facts precede proof reuse.
   This bridge imports the actual pinned upstream package. It does not assert
   correctness of Rust, SQLite, transport callbacks or caller authentication. -/
namespace Weaver.PolicyBridge
open Cedar.Spec CedarPooSpec.Admission

theorem matching_actual_values_preserve_request
    [DecidableEq Effect] [DecidableEq HostState]
    (project : Effect → HostState → Request)
    (operation : BoundOperation Effect HostState project)
    (effect : Effect) (state : HostState)
    (accepted : operation.matches effect state = true) :
    operation.request = project effect state := by
  have equal : operation.effect = effect ∧ operation.state = state := by
    simpa [BoundOperation.matches] using accepted
  simp [BoundOperation.request,equal.1,equal.2]

theorem changed_effect_rejects_bound_reuse
    [DecidableEq Effect] [DecidableEq HostState]
    (project : Effect → HostState → Request)
    (operation : BoundOperation Effect HostState project)
    (effect : Effect) (state : HostState)
    (changed : operation.effect ≠ effect) : operation.matches effect state = false := by
  simp [BoundOperation.matches,changed]

/- SysML evidence projection, not another lifecycle/CAS state machine. The host
   must authenticate and read these values at the final deciding point. -/
structure SuccessorContext where
  originalRoot : Nat
  claim : Nat
  profile : Nat
  budgetDomain : Nat
  historyDomain : Nat
  factFloor : Nat
  pendingHardFacts : List Nat
  fence : Nat
  frontier : Nat
  reservation : Nat
  requiredDomain : Nat
  receiptDomain : Nat
  receiptComplete : Bool
  deriving DecidableEq

def SuccessorContext.ready (s : SuccessorContext) : Bool :=
  s.pendingHardFacts.isEmpty && decide (s.requiredDomain = s.receiptDomain) && s.receiptComplete

/- Current authority-read projection, not a second registry or CAS machine.
   Rust must materialize this from one authenticated deciding image and compare
   under final CAS. Full profile content/source and actual policy/schema remain
   native bindings; Nat values name canonical authenticated artifacts only. -/
structure PublicationContext extends SuccessorContext where
  authorityIdentity : Nat
  authorityRevision : Nat
  originalProfilePayload : Nat
  selectedProfilePayload : Nat
  profileSourceClosure : Nat
  policySchemaImage : Nat
  replayPredecessorImage : Option Nat
  replayCandidateImage : Nat
  executorSession : Nat
  deriving DecidableEq

theorem matched_publication_context_preserves_all_coordinates
    [DecidableEq Effect] (project : Effect → PublicationContext → Request)
    (operation : BoundOperation Effect PublicationContext project)
    (effect : Effect) (actual : PublicationContext)
    (matched : operation.matches effect actual = true) :
    operation.state = actual := by
  have same : operation.effect = effect ∧ operation.state = actual := by
    simpa [BoundOperation.matches] using matched
  exact same.2

theorem matched_publication_preserves_original_assignment
    [DecidableEq Effect] (project : Effect → PublicationContext → Request)
    (operation : BoundOperation Effect PublicationContext project)
    (effect : Effect) (actual : PublicationContext)
    (matched : operation.matches effect actual = true) :
    operation.state.toSuccessorContext = actual.toSuccessorContext :=
  congrArg PublicationContext.toSuccessorContext
    (matched_publication_context_preserves_all_coordinates project operation effect actual matched)

theorem changed_publication_coordinate_rejects_reuse
    [DecidableEq Effect] (project : Effect → PublicationContext → Request)
    (operation : BoundOperation Effect PublicationContext project)
    (effect : Effect) (actual : PublicationContext)
    (coordinate : PublicationContext → Nat)
    (changed : coordinate operation.state ≠ coordinate actual) :
    operation.matches effect actual = false := by
  have different : operation.state ≠ actual := fun same => changed (congrArg coordinate same)
  simp [BoundOperation.matches, different]

theorem changed_original_assignment_rejects_publication_reuse
    [DecidableEq Effect] (project : Effect → PublicationContext → Request)
    (operation : BoundOperation Effect PublicationContext project)
    (effect : Effect) (actual : PublicationContext)
    (changed : operation.state.toSuccessorContext ≠ actual.toSuccessorContext) :
    operation.matches effect actual = false := by
  have different : operation.state ≠ actual := fun same =>
    changed (congrArg PublicationContext.toSuccessorContext same)
  simp [BoundOperation.matches, different]

#print axioms matched_publication_context_preserves_all_coordinates
#print axioms matched_publication_preserves_original_assignment
#print axioms changed_publication_coordinate_rejects_reuse
#print axioms changed_original_assignment_rejects_publication_reuse

theorem matched_replay_preserves_both_images
    [DecidableEq Effect] (project : Effect → PublicationContext → Request)
    (operation : BoundOperation Effect PublicationContext project)
    (effect : Effect) (actual : PublicationContext)
    (matched : operation.matches effect actual = true) :
    operation.state.replayPredecessorImage = actual.replayPredecessorImage ∧
    operation.state.replayCandidateImage = actual.replayCandidateImage := by
  have same := matched_publication_context_preserves_all_coordinates project operation effect actual matched
  exact ⟨congrArg PublicationContext.replayPredecessorImage same,
    congrArg PublicationContext.replayCandidateImage same⟩

theorem changed_replay_predecessor_rejects_reuse
    [DecidableEq Effect] (project : Effect → PublicationContext → Request)
    (operation : BoundOperation Effect PublicationContext project)
    (effect : Effect) (actual : PublicationContext)
    (changed : operation.state.replayPredecessorImage ≠ actual.replayPredecessorImage) :
    operation.matches effect actual = false := by
  have different : operation.state ≠ actual := fun same =>
    changed (congrArg PublicationContext.replayPredecessorImage same)
  simp [BoundOperation.matches, different]

#print axioms matched_replay_preserves_both_images
#print axioms changed_replay_predecessor_rejects_reuse

theorem changed_state_rejects_bound_reuse
    [DecidableEq Effect] [DecidableEq HostState]
    (project : Effect → HostState → Request)
    (operation : BoundOperation Effect HostState project)
    (effect : Effect) (state : HostState)
    (changed : operation.state ≠ state) : operation.matches effect state = false := by
  simp [BoundOperation.matches,changed]

theorem changed_fact_floor_rejects_successor_reuse
    [DecidableEq Effect] (project : Effect → SuccessorContext → Request)
    (operation : BoundOperation Effect SuccessorContext project)
    (effect : Effect) (actual : SuccessorContext)
    (changed : operation.state.factFloor ≠ actual.factFloor) :
    operation.matches effect actual = false := by
  apply changed_state_rejects_bound_reuse
  intro same
  exact changed (congrArg SuccessorContext.factFloor same)

theorem changed_owner_fence_rejects_successor_reuse
    [DecidableEq Effect] (project : Effect → SuccessorContext → Request)
    (operation : BoundOperation Effect SuccessorContext project)
    (effect : Effect) (actual : SuccessorContext)
    (changed : operation.state.fence ≠ actual.fence) :
    operation.matches effect actual = false := by
  apply changed_state_rejects_bound_reuse
  intro same
  exact changed (congrArg SuccessorContext.fence same)

theorem pending_hard_fact_blocks_successor (s : SuccessorContext)
    (pending : s.pendingHardFacts ≠ []) : s.ready = false := by
  cases h : s.pendingHardFacts with
  | nil => exact False.elim (pending h)
  | cons head tail => simp [SuccessorContext.ready,h]

theorem wrong_observation_domain_blocks_successor (s : SuccessorContext)
    (wrong : s.requiredDomain ≠ s.receiptDomain) : s.ready = false := by
  simp [SuccessorContext.ready,wrong]

theorem incomplete_receipt_blocks_successor (s : SuccessorContext)
    (incomplete : s.receiptComplete = false) : s.ready = false := by
  simp [SuccessorContext.ready,incomplete]

/- This predicate describes evidence eligibility, not an account update. The
   original reservation, usage scope and application authenticity are Host facts.
   Unknown usage cannot justify refund by a completion/publication label. -/
def settlementEvidenceReady (usageKnown applicationBound scopeComplete : Bool) : Bool :=
  usageKnown && applicationBound && scopeComplete

theorem unknown_usage_cannot_justify_release (bound complete : Bool) :
    settlementEvidenceReady false bound complete = false := by
  simp [settlementEvidenceReady]

theorem missing_account_application_cannot_justify_release (known complete : Bool) :
    settlementEvidenceReady known false complete = false := by
  simp [settlementEvidenceReady]

theorem compound_acceptance_requires_each_error_free_allow
    (model : CedarPooSpec.PolicyModules.Model) (root : String) (requests : List Request)
    (entities : Entities) (receipt : CedarPooSpec.CompoundAuthorization.Receipt model root requests entities)
    (accepted : receipt.allowed = true) :
    ∀ request ∈ requests, let response := isAuthorized request entities receipt.policies
      (response.decision == .allow && response.erroringPolicies.isEmpty) = true := by
  have all : requests ≠ [] ∧ ∀ response ∈ receipt.responses,
      response.decision = .allow ∧ response.erroringPolicies.isEmpty = true := by
    simpa [CedarPooSpec.CompoundAuthorization.Receipt.allowed,List.all_eq_true] using accepted
  intro request member
  have evaluated : isAuthorized request entities receipt.policies ∈ receipt.responses := by
    rw [receipt.evaluated]
    exact List.mem_map.mpr ⟨request,member,rfl⟩
  simpa using all.2 _ evaluated


/- Semantic refinement only. The host authenticates actual values and establishes
   that native parsing/publication materialized this exact root. Quint checks
   publication ordering and failures; native tests check SQL and transport. -/
theorem governance_projection_and_actual_request_require_error_free_allow
    [DecidableEq Effect] [DecidableEq HostState]
    (project : Effect → HostState → Request)
    (operation : BoundOperation Effect HostState project)
    (effect : Effect) (state : HostState)
    (matched : operation.matches effect state = true)
    (model : CedarPooSpec.PolicyModules.Model) (root : String)
    (entities : Entities) (runtimePolicies : Policies)
    (materialized : model.compile root = .ok runtimePolicies)
    (receipt : CedarPooSpec.CompoundAuthorization.Receipt model root [operation.request] entities)
    (accepted : receipt.allowed = true) :
    let response := isAuthorized (project effect state) entities runtimePolicies
    (response.decision == .allow && response.erroringPolicies.isEmpty) = true := by
  have same : receipt.policies = runtimePolicies := by
    have equal := receipt.compiled.symm.trans materialized
    exact Except.ok.inj equal
  have request := matching_actual_values_preserve_request project operation effect state matched
  have allowed := compound_acceptance_requires_each_error_free_allow model root
    [operation.request] entities receipt accepted operation.request (by simp)
  simpa [same, request] using allowed

theorem bound_successor_requires_current_semantics
    [DecidableEq Effect] (project : Effect → SuccessorContext → Request)
    (operation : BoundOperation Effect SuccessorContext project)
    (effect : Effect) (actual : SuccessorContext)
    (matched : operation.matches effect actual = true)
    (ready : actual.ready = true)
    (model : CedarPooSpec.PolicyModules.Model) (root : String)
    (entities : Entities) (runtimePolicies : Policies)
    (materialized : model.compile root = .ok runtimePolicies)
    (receipt : CedarPooSpec.CompoundAuthorization.Receipt model root [operation.request] entities)
    (accepted : receipt.allowed = true) :
    operation.state = actual ∧ actual.pendingHardFacts = [] ∧
    actual.requiredDomain = actual.receiptDomain ∧ actual.receiptComplete = true ∧
    let response := isAuthorized (project effect actual) entities runtimePolicies
    (response.decision == .allow && response.erroringPolicies.isEmpty) = true := by
  have same : operation.effect = effect ∧ operation.state = actual := by
    simpa [BoundOperation.matches] using matched
  have current : (actual.pendingHardFacts = [] ∧ actual.requiredDomain = actual.receiptDomain) ∧ actual.receiptComplete = true := by
    simpa [SuccessorContext.ready] using ready
  exact ⟨same.2,current.1.1,current.1.2,current.2,
    governance_projection_and_actual_request_require_error_free_allow project operation
      effect actual matched model root entities runtimePolicies materialized receipt accepted⟩

/- Additional SysML fact-use projection. Values are abstract identities, not a
   serializer for arbitrary Scheme procedures. No lifecycle transitions here. -/
structure ProjectionClosure where
  backend : Nat
  engine : Nat
  rule : Nat
  queryIdentity : Nat
  schema : Nat
  sourceCut : Nat
  sourceAuthority : Nat
  scope : Nat
  limits : Nat
  adapter : Nat
  callbackEnvironment : Nat
  freshnessContract : Nat
  deriving DecidableEq

inductive FactFreshnessMode where
  | orderedSession
  | boundedPromise
  deriving DecidableEq

structure FreshnessContext where
  mode : FactFreshnessMode
  contract : Nat
  sourceAuthority : Nat
  sourceCut : Nat
  grantContract : Nat
  grantAuthority : Nat
  grantCut : Nat
  sourceScope : Nat
  grantScope : Nat
  fence : Nat
  grantFence : Nat
  clockEpoch : Nat
  grantClockEpoch : Nat
  clockFloor : Nat
  now : Nat
  sessionEpoch : Nat
  grantSessionEpoch : Nat
  sessionLive : Bool
  validBefore : Nat
  deriving DecidableEq

def FreshnessContext.valid (s : FreshnessContext) : Bool :=
  decide (s.grantContract = s.contract ∧ s.grantAuthority = s.sourceAuthority ∧
    s.grantCut = s.sourceCut ∧ s.grantScope = s.sourceScope ∧ s.grantFence = s.fence ∧
    s.grantClockEpoch = s.clockEpoch ∧ s.clockFloor ≤ s.now) &&
  match s.mode with
  | .orderedSession => s.sessionLive && decide (s.grantSessionEpoch = s.sessionEpoch)
  | .boundedPromise => decide (s.now < s.validBefore)

structure ProjectionContext where
  evidenceClosure : ProjectionClosure
  authorityClosure : ProjectionClosure
  complete : Bool
  coveredScope : List Nat
  requiredScope : List Nat
  ownedCanonicalValues : Bool
  timedOut : Bool
  capturedValue : Nat
  readValue : Nat
  sourceCommittedValue : Nat
  materializedRowDigest : Nat
  committedRowDigest : Nat
  originalIntentCut : Nat
  freshness : FreshnessContext
  deriving DecidableEq

def ProjectionContext.Ready (s : ProjectionContext) : Prop :=
  s.evidenceClosure = s.authorityClosure ∧ s.complete = true ∧
  s.coveredScope = s.requiredScope ∧ s.ownedCanonicalValues = true ∧
  s.timedOut = false ∧ s.readValue = s.capturedValue ∧
  s.capturedValue = s.sourceCommittedValue ∧ s.materializedRowDigest = s.committedRowDigest ∧
  s.authorityClosure.sourceCut = s.originalIntentCut ∧
  s.freshness.contract = s.authorityClosure.freshnessContract ∧
  s.freshness.sourceAuthority = s.authorityClosure.sourceAuthority ∧
  s.freshness.sourceCut = s.authorityClosure.sourceCut ∧
  s.freshness.sourceScope = s.authorityClosure.scope ∧ s.freshness.valid = true

instance (s : ProjectionContext) : Decidable s.Ready := by
  unfold ProjectionContext.Ready
  infer_instance

def ProjectionContext.ready (s : ProjectionContext) : Bool := decide s.Ready

theorem changed_projection_closure_rejects_evidence (s : ProjectionContext)
    (changed : s.evidenceClosure ≠ s.authorityClosure) : s.ready = false := by
  simp [ProjectionContext.ready,ProjectionContext.Ready,changed]

theorem incomplete_facts_cannot_establish_negative (s : ProjectionContext)
    (unknown : s.complete = false) : s.ready = false := by
  simp [ProjectionContext.ready,ProjectionContext.Ready,unknown]

theorem partial_scope_cannot_establish_negative (s : ProjectionContext)
    (scopeGap : s.coveredScope ≠ s.requiredScope) : s.ready = false := by
  simp [ProjectionContext.ready,ProjectionContext.Ready,scopeGap]

theorem mutable_alias_cannot_reinterpret_frozen_evidence (s : ProjectionContext)
    (changed : s.readValue ≠ s.capturedValue) : s.ready = false := by
  simp [ProjectionContext.ready,ProjectionContext.Ready,changed]

theorem unowned_values_cannot_establish_fact_image (s : ProjectionContext)
    (unowned : s.ownedCanonicalValues = false) : s.ready = false := by
  simp [ProjectionContext.ready,ProjectionContext.Ready,unowned]

theorem uncommitted_source_value_cannot_be_materialized (s : ProjectionContext)
    (changed : s.capturedValue ≠ s.sourceCommittedValue) : s.ready = false := by
  simp [ProjectionContext.ready,ProjectionContext.Ready,changed]

theorem changed_materialized_rows_reject_source_cut (s : ProjectionContext)
    (changed : s.materializedRowDigest ≠ s.committedRowDigest) : s.ready = false := by
  simp [ProjectionContext.ready,ProjectionContext.Ready,changed]

theorem unrelated_source_cut_cannot_resolve_intent (s : ProjectionContext)
    (wrong : s.authorityClosure.sourceCut ≠ s.originalIntentCut) : s.ready = false := by
  simp [ProjectionContext.ready,ProjectionContext.Ready,wrong]

theorem timed_out_derivation_is_not_complete_evidence (s : ProjectionContext)
    (failed : s.timedOut = true) : s.ready = false := by
  simp [ProjectionContext.ready,ProjectionContext.Ready,failed]

theorem disconnected_ordered_session_is_not_fresh (s : FreshnessContext)
    (mode : s.mode = .orderedSession) (disconnected : s.sessionLive = false) :
    s.valid = false := by
  simp [FreshnessContext.valid,mode,disconnected]

theorem expired_source_promise_is_not_fresh (s : FreshnessContext)
    (mode : s.mode = .boundedPromise) (expired : s.validBefore ≤ s.now) :
    s.valid = false := by
  simp [FreshnessContext.valid,mode,Nat.not_lt.mpr expired]

theorem old_clock_epoch_is_not_fresh (s : FreshnessContext)
    (old : s.grantClockEpoch ≠ s.clockEpoch) : s.valid = false := by
  simp [FreshnessContext.valid,old]

theorem freshness_for_other_scope_cannot_enable_projection (s : ProjectionContext)
    (wrong : s.freshness.sourceScope ≠ s.authorityClosure.scope) : s.ready = false := by
  simp [ProjectionContext.ready,ProjectionContext.Ready,wrong]

/- A countermodel to cross-world reuse, not an alternate Cedar semantics.
   Even reflexive pointwise implication supplies no implication between worlds. -/
theorem pointwise_no_gain_does_not_compare_fact_worlds :
    (∀ world : Bool, world = true → world = true) ∧
    ¬ ((true : Bool) = true → (false : Bool) = true) := by
  simp

theorem fact_context_and_cedar_bind_actual_execution
    [DecidableEq Effect] (project : Effect → ProjectionContext → Request)
    (operation : BoundOperation Effect ProjectionContext project)
    (effect : Effect) (actual : ProjectionContext)
    (matched : operation.matches effect actual = true) (ready : actual.ready = true)
    (model : CedarPooSpec.PolicyModules.Model) (root : String)
    (entities : Entities) (runtimePolicies : Policies)
    (materialized : model.compile root = .ok runtimePolicies)
    (receipt : CedarPooSpec.CompoundAuthorization.Receipt model root [operation.request] entities)
    (accepted : receipt.allowed = true) :
    operation.state = actual ∧ actual.Ready ∧
    let response := isAuthorized (project effect actual) entities runtimePolicies
    (response.decision == .allow && response.erroringPolicies.isEmpty) = true := by
  have same : operation.effect = effect ∧ operation.state = actual := by
    simpa [BoundOperation.matches] using matched
  have current : actual.Ready := by simpa [ProjectionContext.ready] using ready
  exact ⟨same.2,current,governance_projection_and_actual_request_require_error_free_allow
    project operation effect actual matched model root entities runtimePolicies materialized receipt accepted⟩

/- Adapter eligibility only: borrowed-region validity is a trusted caller/GC
   premise, not a safe way to probe arbitrary C pointers. No new execution FSM. -/
inductive ConfigurationEntry where
  | jsonData
  | schemeProgram
  deriving DecidableEq

structure CallbackIdentity where
  vm : Nat
  call : Nat
  captureEpoch : Nat
  deriving DecidableEq

structure CaptureDependency where
  moduleClosure : Nat
  environment : Nat
  sourceCut : Nat
  deriving DecidableEq

/- Native refinement also requires the independently checked Policy/schema byte
   bounds before foreign calls. The Scheme character precheck prevents unbounded
   encoding input; its actual UTF-8 byte check and Rust region guards have native
   property evidence. Ready below proves neither encoding allocation bounds nor
   address validity; retain those host premises and the inert-preflight boundary. -/
/- root_source and materialize_source implement native input/output in Rust.
   Fidelity of SDK constructors, UTF-8/NUL, exact integer magnitude and field/map
   key kinds remains a concrete refinement premise, checked by real-VM PBT.
   These semantic laws do not verify the SDK allocator or raw C representation.
   Aggregate construction refusal cannot establish a Ready boundary. -/
structure BoundaryContext where
  entry : ConfigurationEntry
  configurationSchema : Nat
  expectedConfigurationSchema : Nat
  normalizer : Nat
  expectedNormalizer : Nat
  callback : CallbackIdentity
  authenticatedCallback : CallbackIdentity
  expectedCallback : CallbackIdentity
  captured : CaptureDependency
  expectedCapture : CaptureDependency
  inputValue : Nat
  committedInput : Nat
  semanticOutput : Nat
  committedOutput : Nat
  schemaChecked : Bool
  governanceChecked : Bool
  borrowedRegionValid : Bool
  borrowedRegionStable : Bool
  rustOwned : Bool
  retainsForeignPointer : Bool
  reentrant : Bool
  captureEmissions : Nat
  captureCompleted : Bool
  capturePoisoned : Bool
  nativeTyped : Bool
  exactIntegers : Bool
  keyKinds : Bool
  deriving DecidableEq

def BoundaryContext.Ready (s : BoundaryContext) : Prop :=
  0 < s.configurationSchema ∧ s.configurationSchema = s.expectedConfigurationSchema ∧
  s.normalizer = s.expectedNormalizer ∧ s.callback = s.expectedCallback ∧
  s.authenticatedCallback = s.expectedCallback ∧
  s.captured = s.expectedCapture ∧ s.inputValue = s.committedInput ∧
  s.semanticOutput = s.committedOutput ∧ s.schemaChecked = true ∧
  s.governanceChecked = true ∧ s.borrowedRegionValid = true ∧
  s.borrowedRegionStable = true ∧ s.rustOwned = true ∧
  s.retainsForeignPointer = false ∧ s.reentrant = false ∧
  s.captureEmissions = 1 ∧ s.captureCompleted = true ∧ s.capturePoisoned = false ∧
  s.nativeTyped = true ∧ s.exactIntegers = true ∧ s.keyKinds = true

instance (s : BoundaryContext) : Decidable s.Ready := by
  unfold BoundaryContext.Ready
  infer_instance

def BoundaryContext.ready (s : BoundaryContext) : Bool := decide s.Ready

theorem source_capture_requires_one_emission (s : BoundaryContext)
    (wrong : s.captureEmissions ≠ 1) : s.ready = false := by
  simp [BoundaryContext.ready,BoundaryContext.Ready,wrong]

theorem caught_duplicate_cannot_clear_capture_fuse (s : BoundaryContext)
    (poisoned : s.capturePoisoned = true) : s.ready = false := by
  simp [BoundaryContext.ready,BoundaryContext.Ready,poisoned]

theorem status_cannot_replace_source_completion (s : BoundaryContext)
    (incomplete : s.captureCompleted = false) : s.ready = false := by
  simp [BoundaryContext.ready,BoundaryContext.Ready,incomplete]

#print axioms source_capture_requires_one_emission
#print axioms caught_duplicate_cannot_clear_capture_fuse
#print axioms status_cannot_replace_source_completion

/-- Refinement premises are established by native SDK/PBT tests, not by these laws. -/
theorem encoded_blob_cannot_claim_native_capture (s : BoundaryContext)
    (blob : s.nativeTyped = false) : s.ready = false := by
  simp [BoundaryContext.ready,BoundaryContext.Ready,blob]

theorem lossy_integer_cannot_preserve_original_budget (s : BoundaryContext)
    (rounded : s.exactIntegers = false) : s.ready = false := by
  simp [BoundaryContext.ready,BoundaryContext.Ready,rounded]

theorem coerced_key_cannot_preserve_source_identity (s : BoundaryContext)
    (ambiguous : s.keyKinds = false) : s.ready = false := by
  simp [BoundaryContext.ready,BoundaryContext.Ready,ambiguous]

#print axioms encoded_blob_cannot_claim_native_capture
#print axioms lossy_integer_cannot_preserve_original_budget
#print axioms coerced_key_cannot_preserve_source_identity

theorem configuration_cannot_skip_governance (s : BoundaryContext)
    (missing : s.governanceChecked = false) : s.ready = false := by
  simp [BoundaryContext.ready,BoundaryContext.Ready,missing]

theorem scheme_output_requires_configuration_validation (s : BoundaryContext)
    (missing : s.schemaChecked = false) : s.ready = false := by
  simp [BoundaryContext.ready,BoundaryContext.Ready,missing]

theorem omitted_configuration_schema_cannot_admit (s : BoundaryContext)
    (missing : s.configurationSchema = 0) : s.ready = false := by
  simp [BoundaryContext.ready,BoundaryContext.Ready,missing]

theorem stale_vm_callback_cannot_admit (s : BoundaryContext)
    (stale : s.callback ≠ s.expectedCallback) : s.ready = false := by
  simp [BoundaryContext.ready,BoundaryContext.Ready,stale]

theorem changed_capture_cannot_reuse_adapter_evidence (s : BoundaryContext)
    (changed : s.captured ≠ s.expectedCapture) : s.ready = false := by
  simp [BoundaryContext.ready,BoundaryContext.Ready,changed]

/-- The expected capture names the independently retained pre-assessment data,
not a second pointer to the same mutable live Profile/context. Native canonical
capture and method/source qualification remain explicit refinement premises. -/
theorem changed_assessment_snapshot_cannot_reuse_boundary (s : BoundaryContext)
    (changed : s.captured.environment ≠ s.expectedCapture.environment) : s.ready = false := by
  apply changed_capture_cannot_reuse_adapter_evidence
  intro same
  exact changed (congrArg CaptureDependency.environment same)

#print axioms changed_assessment_snapshot_cannot_reuse_boundary

/-- Self-consistent replacement content cannot redefine the independently
retained original. Authenticity of that original is still a host premise. -/
theorem coherent_replacement_cannot_redefine_original (s : BoundaryContext)
    (_coherent : s.inputValue = s.semanticOutput)
    (changed : s.inputValue ≠ s.committedInput) : s.ready = false := by
  simp [BoundaryContext.ready,BoundaryContext.Ready,changed]

theorem ready_output_keeps_retained_original (s : BoundaryContext)
    (ready : s.ready = true) : s.semanticOutput = s.committedOutput := by
  have admitted : s.Ready := by simpa [BoundaryContext.ready] using ready
  rcases admitted with ⟨_, _, _, _, _, _, _, output, _⟩
  exact output

#print axioms coherent_replacement_cannot_redefine_original
#print axioms ready_output_keeps_retained_original

theorem old_authenticated_callback_cannot_use_fresh_labels (s : BoundaryContext)
    (old : s.authenticatedCallback ≠ s.expectedCallback) : s.ready = false := by
  simp [BoundaryContext.ready,BoundaryContext.Ready,old]

theorem retained_pointer_cannot_enter_owned_queue (s : BoundaryContext)
    (retained : s.retainsForeignPointer = true) : s.ready = false := by
  simp [BoundaryContext.ready,BoundaryContext.Ready,retained]

theorem invalid_borrow_contract_cannot_admit (s : BoundaryContext)
    (invalid : s.borrowedRegionValid = false) : s.ready = false := by
  simp [BoundaryContext.ready,BoundaryContext.Ready,invalid]

/- Only the already validated common data output is compared. This is not
   equivalence of arbitrary Scheme programs, or permission to erase provenance. -/
theorem configuration_entry_does_not_weaken_common_admission
    (s : BoundaryContext) (entry : ConfigurationEntry) :
    ({s with entry := entry} : BoundaryContext).ready = s.ready := by
  rfl

theorem adapter_context_and_cedar_bind_actual_effect
    [DecidableEq Effect] (project : Effect → BoundaryContext → Request)
    (operation : BoundOperation Effect BoundaryContext project)
    (effect : Effect) (actual : BoundaryContext)
    (matched : operation.matches effect actual = true) (ready : actual.ready = true)
    (model : CedarPooSpec.PolicyModules.Model) (root : String)
    (entities : Entities) (runtimePolicies : Policies)
    (materialized : model.compile root = .ok runtimePolicies)
    (receipt : CedarPooSpec.CompoundAuthorization.Receipt model root [operation.request] entities)
    (accepted : receipt.allowed = true) :
    operation.state = actual ∧ actual.Ready ∧
    let response := isAuthorized (project effect actual) entities runtimePolicies
    (response.decision == .allow && response.erroringPolicies.isEmpty) = true := by
  have same : operation.effect = effect ∧ operation.state = actual := by
    simpa [BoundOperation.matches] using matched
  have current : actual.Ready := by simpa [BoundaryContext.ready] using ready
  exact ⟨same.2,current,governance_projection_and_actual_request_require_error_free_allow
    project operation effect actual matched model root entities runtimePolicies materialized receipt accepted⟩

/- A stored immutable capture is data, not a live callback. Reuse depends on its
   admitted receipt and current semantic/source binding, not current VM liveness. -/
structure OwnedCaptureContext where
  captureReceipt : BoundaryContext
  currentCapture : CaptureDependency
  currentConfigurationSchema : Nat
  currentNormalizer : Nat
  currentInput : Nat
  currentOutput : Nat

def OwnedCaptureContext.Ready (s : OwnedCaptureContext) : Prop :=
  s.captureReceipt.ready = true ∧ s.captureReceipt.captured = s.currentCapture ∧
  s.captureReceipt.configurationSchema = s.currentConfigurationSchema ∧
  s.captureReceipt.normalizer = s.currentNormalizer ∧
  s.captureReceipt.inputValue = s.currentInput ∧ s.captureReceipt.semanticOutput = s.currentOutput

instance (s : OwnedCaptureContext) : Decidable s.Ready := by
  unfold OwnedCaptureContext.Ready
  infer_instance

def OwnedCaptureContext.ready (s : OwnedCaptureContext) : Bool := decide s.Ready

theorem owned_artifact_requires_admitted_capture (s : OwnedCaptureContext)
    (missing : s.captureReceipt.ready = false) : s.ready = false := by
  simp [OwnedCaptureContext.ready,OwnedCaptureContext.Ready,missing]

theorem owned_artifact_cannot_ignore_current_source (s : OwnedCaptureContext)
    (changed : s.captureReceipt.captured ≠ s.currentCapture) : s.ready = false := by
  simp [OwnedCaptureContext.ready,OwnedCaptureContext.Ready,changed]

/- Local host resources refine inert capture delivery, not execution authority.
   The embedding must implement the shared gate and natural foreign-call drain.
   Cancellation marks data unusable; disposal or natural return releases slots. -/
inductive SourcePhase where
  | queued | running | ready | delivered | discarded
  deriving DecidableEq
structure SourceHost where
  closed : Bool
  cancelled : Bool
  phase : SourcePhase
  slot : Bool
  initializing : Bool
  factoryActive : Bool
  ownerCleaned : Bool
  joined : Bool

inductive SourceHostStep : SourceHost → SourceHost → Prop where
  | close (s) : SourceHostStep s {s with closed := true}
  | factoryReturn (s) : SourceHostStep s {s with factoryActive := false}
  | initialize (s) (starting : s.initializing = true) (returned : s.factoryActive = false)
      (admitted : s.closed = false) (live : s.ownerCleaned = false) :
      SourceHostStep s {s with initializing := false}
  | cleanup (s) (closed : s.closed = true) (returned : s.factoryActive = false)
      (idle : s.phase ≠ .running) : SourceHostStep s {s with ownerCleaned := true}
  | join (s) (cleaned : s.ownerCleaned = true) : SourceHostStep s {s with joined := true}
  | start (s) (admitted : s.closed = false) (queued : s.phase = .queued)
      (initialized : s.initializing = false) (live : s.ownerCleaned = false) :
      SourceHostStep s {s with phase := .running}
  | cancel (s) :
      SourceHostStep s {s with cancelled := true}
  | discardWaiting (s) (waiting : s.phase = .queued ∨ s.phase = .ready)
      (blocked : s.closed = true ∨ s.cancelled = true) :
      SourceHostStep s {s with phase := .discarded, slot := false}
  | finish (s) (running : s.phase = .running)
      (eligible : s.closed = false ∧ s.cancelled = false) :
      SourceHostStep s {s with phase := .ready}
  | discardFinished (s) (running : s.phase = .running)
      (blocked : s.closed = true ∨ s.cancelled = true) :
      SourceHostStep s {s with phase := .discarded, slot := false}
  | deliver (s) (ready : s.phase = .ready)
      (eligible : s.closed = false ∧ s.cancelled = false) :
      SourceHostStep s {s with phase := .delivered, slot := false}

theorem source_host_close_is_terminal (event : SourceHostStep s t)
    (closed : s.closed = true) : t.closed = true := by
  cases event <;> simp_all

theorem source_host_delivery_requires_open_gate (event : SourceHostStep s t)
    (fresh : s.phase ≠ .delivered) (delivered : t.phase = .delivered) :
    s.closed = false ∧ s.cancelled = false := by
  cases event <;> simp_all

theorem source_host_running_cancel_retains_slot (event : SourceHostStep s t)
    (running : s.phase = .running) (stillRunning : t.phase = .running) :
    t.slot = s.slot := by
  cases event <;> simp_all

def SourceHost.ResourcesSafe (s : SourceHost) : Prop := s.joined = true → s.ownerCleaned = true
theorem source_owner_join_preserves_cleanup (event : SourceHostStep s t)
    (safe : s.ResourcesSafe) : t.ResourcesSafe := by
  cases event <;> simp_all [SourceHost.ResourcesSafe]
theorem source_owner_late_initialization_is_fenced (event : SourceHostStep s t)
    (before : s.initializing = true) (after : t.initializing = false) : s.closed = false := by
  cases event <;> simp_all
theorem source_owner_cleanup_requires_natural_return (event : SourceHostStep s t)
    (before : s.ownerCleaned = false) (after : t.ownerCleaned = true) :
    s.factoryActive = false ∧ s.phase ≠ .running := by
  cases event <;> simp_all

#print axioms source_owner_join_preserves_cleanup
#print axioms source_owner_late_initialization_is_fenced
#print axioms source_owner_cleanup_requires_natural_return
#print axioms source_host_close_is_terminal
#print axioms source_host_delivery_requires_open_gate
#print axioms source_host_running_cancel_retains_slot
#print axioms owned_artifact_requires_admitted_capture
#print axioms owned_artifact_cannot_ignore_current_source
#print axioms configuration_cannot_skip_governance
#print axioms scheme_output_requires_configuration_validation
#print axioms omitted_configuration_schema_cannot_admit
#print axioms stale_vm_callback_cannot_admit
#print axioms changed_capture_cannot_reuse_adapter_evidence
#print axioms retained_pointer_cannot_enter_owned_queue
#print axioms invalid_borrow_contract_cannot_admit
#print axioms configuration_entry_does_not_weaken_common_admission
#print axioms adapter_context_and_cedar_bind_actual_effect
#print axioms old_authenticated_callback_cannot_use_fresh_labels
#print axioms governance_projection_and_actual_request_require_error_free_allow
#print axioms matching_actual_values_preserve_request
#print axioms changed_effect_rejects_bound_reuse
#print axioms compound_acceptance_requires_each_error_free_allow
#print axioms changed_state_rejects_bound_reuse
#print axioms changed_fact_floor_rejects_successor_reuse
#print axioms changed_owner_fence_rejects_successor_reuse
#print axioms pending_hard_fact_blocks_successor
#print axioms wrong_observation_domain_blocks_successor
#print axioms unknown_usage_cannot_justify_release
#print axioms missing_account_application_cannot_justify_release
#print axioms bound_successor_requires_current_semantics
#print axioms incomplete_receipt_blocks_successor
#print axioms changed_projection_closure_rejects_evidence
#print axioms incomplete_facts_cannot_establish_negative
#print axioms partial_scope_cannot_establish_negative
#print axioms mutable_alias_cannot_reinterpret_frozen_evidence
#print axioms unowned_values_cannot_establish_fact_image
#print axioms timed_out_derivation_is_not_complete_evidence
#print axioms disconnected_ordered_session_is_not_fresh
#print axioms expired_source_promise_is_not_fresh
#print axioms old_clock_epoch_is_not_fresh
#print axioms pointwise_no_gain_does_not_compare_fact_worlds
#print axioms fact_context_and_cedar_bind_actual_execution
#print axioms freshness_for_other_scope_cannot_enable_projection
#print axioms uncommitted_source_value_cannot_be_materialized
#print axioms changed_materialized_rows_reject_source_cut
#print axioms unrelated_source_cut_cannot_resolve_intent
end Weaver.PolicyBridge
