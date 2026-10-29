namespace Weaver.ProviderRpc

/- Native premises: authenticated original source and adequate declared cost bound;
   canonical task/node key independent of RPC nonce; durable, non-rollback deciding
   CAS; affine native dispatch/release capabilities; current Cedar checks serialized
   with request invocation and bounded queue insertion; faithful private transport.
   These declarations do not prove TLS, gRPC, Rust compilation or filesystem durability. -/
structure State where
  stage : Nat := 0
  burned : Bool := false
  token : Nat := 0
  calls : Nat := 0
  held : Nat := 0
  revision : Nat := 0
  fence : Nat := 1
  permitRevision : Nat := 0
  permitFence : Nat := 1
  cancelled : Bool := false
  invocationSnapshots : List Bool := []

def Current (s : State) : Prop := s.permitRevision = s.revision ∧ s.permitFence = s.fence

def Safe (cost budget : Nat) (s : State) : Prop :=
  s.calls + s.token ≤ (if s.burned then 1 else 0) ∧ s.calls ≤ 1 ∧
  s.held ≤ budget ∧ (s.stage ≥ 1 → s.held = cost) ∧ (s.burned = true → s.stage ≥ 2)

inductive Step (cost budget : Nat) : State → State → Prop where
  | admit (s) (fresh : s.stage = 0) (capacity : cost ≤ budget) :
      Step cost budget s {s with stage := 1, held := cost}
  | consume (s) (queued : s.stage = 1) :
      Step cost budget s {s with stage := 2, permitRevision := s.revision, permitFence := s.fence}
  | burn (s) (consumed : s.stage = 2) (unused : s.burned = false) (authority : Current s) :
      Step cost budget s {s with burned := true, token := 1}
  | invoke (s) (affine : s.token = 1) (authority : Current s) (live : s.cancelled = false) :
      Step cost budget s {s with token := 0, calls := s.calls + 1, invocationSnapshots := s.invocationSnapshots ++ [s.cancelled]}
  | crash (s) : Step cost budget s {s with token := 0}
  | publish (s) : Step cost budget s {s with revision := s.revision+1, fence := s.fence+1}
  | cancel (s) : Step cost budget s {s with cancelled := true}
  | observation (s) : Step cost budget s s

theorem safe_step {s t : State} (h : Safe cost budget s) (step : Step cost budget s t) : Safe cost budget t := by
  cases step <;> cases hb : s.burned <;> simp_all [Safe] <;> omega

inductive Run (cost budget : Nat) : State → State → Prop where
  | refl (s) : Run cost budget s s
  | next : Run cost budget a b → Step cost budget b c → Run cost budget a c

theorem safe_run {s t : State} (initial : Safe cost budget s) (run : Run cost budget s t) : Safe cost budget t := by
  induction run with
  | refl => exact initial
  | next history step ih => exact safe_step ih step

theorem stale_authority_cannot_pass (s : State) (stale : s.permitFence < s.fence) : ¬ Current s := by
  intro fresh; have same := fresh.2; omega

theorem consumed_unknown_retains_original_hold {s t : State}
    (initial : Safe cost budget s) (run : Run cost budget s t) (consumed : t.stage ≥ 1) :
    t.held = cost ∧ t.calls ≤ 1 := by
  have h := safe_run initial run
  exact ⟨h.2.2.2.1 consumed,h.2.1⟩

theorem new_rpc_nonce_cannot_select_fresh_state {Nonce Root : Type}
    (canonical : Nonce → Root) (ledger : Root → State) (old fresh : Nonce)
    (bound : canonical fresh = canonical old) : ledger (canonical fresh) = ledger (canonical old) := by rw [bound]

inductive Encoding where | protobuf | arrow

def RowsAuthorized (_encoding : Encoding) (allow : Nat → Prop) (first rows : Nat) : Prop :=
  ∀ offset, offset < rows → allow (first + offset)

theorem arrow_cannot_weaken_row_authority :
    RowsAuthorized Encoding.arrow allow first rows ↔ RowsAuthorized Encoding.protobuf allow first rows := Iff.rfl

theorem every_arrow_row_requires_authority
    (h : RowsAuthorized Encoding.arrow allow first rows) (offset : Nat) (within : offset < rows) :
    allow (first + offset) := h offset within

def CallerAuthorized (certificate expected : Key) (credential : Bool) : Prop := certificate = expected ∧ credential = true

theorem shared_name_is_not_key_authority {Key : Type} {certificate expected : Key}
    (different : certificate ≠ expected) : ¬ CallerAuthorized certificate expected credential := by
  intro h; exact different h.1

theorem execution_and_encoding_composition {s t : State}
    (initial : Safe cost budget s) (history : Run cost budget s t)
    (rows : RowsAuthorized Encoding.arrow allow first count) :
    Safe cost budget t ∧ RowsAuthorized Encoding.protobuf allow first count :=
  ⟨safe_run initial history,(arrow_cannot_weaken_row_authority).mp rows⟩

/- Native lane refinement premises: methods authenticate before choosing a lane;
   each tracked native worker retains its RAII permit until actual completion;
   transport, scheduler and SQLite are separately bounded/fair. Reserved admission
   is an enabledness property, not an unconditional publication deadline. -/
structure Lanes where
  execution : Nat := 0
  publication : Nat := 0
  observation : Nat := 0
  closing : Bool := false

def LanesSafe (limit : Nat) (s : Lanes) : Prop :=
  s.execution ≤ limit ∧ s.publication ≤ 1 ∧ s.observation ≤ 2

inductive LaneStep (limit : Nat) : Lanes → Lanes → Prop where
  | execute (s) (admissionOpen : s.closing = false) (room : s.execution < limit) :
      LaneStep limit s {s with execution := s.execution + 1}
  | publish (s) (admissionOpen : s.closing = false) (room : s.publication < 1) :
      LaneStep limit s {s with publication := s.publication + 1}
  | observe (s) (admissionOpen : s.closing = false) (room : s.observation < 2) :
      LaneStep limit s {s with observation := s.observation + 1}
  | finishExecution (s) : LaneStep limit s {s with execution := s.execution - 1}
  | finishPublication (s) : LaneStep limit s {s with publication := s.publication - 1}
  | finishObservation (s) : LaneStep limit s {s with observation := s.observation - 1}
  | disconnect (s) : LaneStep limit s s
  | close (s) : LaneStep limit s {s with closing := true}

theorem lane_step_preserves_bounds (h : LanesSafe limit s) (step : LaneStep limit s t) :
    LanesSafe limit t := by
  cases step <;> simp_all [LanesSafe] <;> omega

theorem execution_saturation_preserves_publication_admission
    (s : Lanes) (admissionOpen : s.closing = false) (free : s.publication = 0) :
    LaneStep limit s {s with publication := s.publication + 1} := by
  exact LaneStep.publish s admissionOpen (by omega)

theorem execution_and_admission_composition
    (source : Safe cost budget s) (execution : Step cost budget s t)
    (bounded : LanesSafe limit a) (admission : LaneStep limit a b) :
    Safe cost budget t ∧ LanesSafe limit b :=
  ⟨safe_step source execution, lane_step_preserves_bounds bounded admission⟩

/- Socket budget is per live server process, including its TLS handshakes. Native
   refinement must retain the permit in the IO wrapper, not a cloneable certificate
   extension. Peer EOF and TLS completion are not socket destruction. -/
structure Connections where
  live : Nat := 0
  held : Nat := 0
  handshakes : Nat := 0
  reserved : Nat := 0
  closing : Bool := false

def ConnectionsSafe (limit : Nat) (s : Connections) : Prop :=
  s.live = s.held ∧ s.handshakes ≤ s.live ∧ s.held + s.reserved ≤ limit ∧ s.reserved ≤ 1

inductive ConnectionStep (limit : Nat) : Connections → Connections → Prop where
  | reserve (s) (admissionOpen : s.closing = false) (empty : s.reserved = 0) (room : s.held < limit) :
      ConnectionStep limit s {s with reserved := 1}
  | accept (s) (admissionOpen : s.closing = false) (reserved : s.reserved = 1) :
      ConnectionStep limit s {s with live := s.live+1, held := s.held+1, handshakes := s.handshakes+1, reserved := 0}
  | tlsComplete (s) : ConnectionStep limit s {s with handshakes := s.handshakes-1}
  | handshakeDestroyed (s) (existsSocket : s.handshakes > 0) :
      ConnectionStep limit s {s with live := s.live-1, held := s.held-1, handshakes := s.handshakes-1}
  | establishedDestroyed (s) (existsSocket : s.handshakes < s.live) :
      ConnectionStep limit s {s with live := s.live-1, held := s.held-1}
  | peerClose (s) : ConnectionStep limit s s
  | closeListener (s) : ConnectionStep limit s {s with closing := true, reserved := 0}

theorem connection_step_preserves_custody (h : ConnectionsSafe limit s) (step : ConnectionStep limit s t) :
    ConnectionsSafe limit t := by
  cases step <;> simp_all [ConnectionsSafe] <;> omega

theorem bounded_connections_include_handshakes (h : ConnectionsSafe limit s) :
    s.handshakes ≤ s.live ∧ s.live ≤ limit := by
  simp only [ConnectionsSafe] at h
  omega

theorem provider_and_connection_composition
    (source : Safe cost budget s) (execution : Step cost budget s t)
    (custody : ConnectionsSafe limit a) (connection : ConnectionStep limit a b) :
    Safe cost budget t ∧ ConnectionsSafe limit b :=
  ⟨safe_step source execution, connection_step_preserves_custody custody connection⟩

inductive IngressRole where | operation | source
  deriving DecidableEq

def IngressAuthorized {Key : Type} (pins : IngressRole → Key) (surface : IngressRole)
    (certificate : Key) (credential : Bool) (method : IngressRole) : Prop :=
  certificate = pins surface ∧ credential = true ∧ method = surface

theorem operation_leaf_cannot_publish_on_source {Key : Type} (pins : IngressRole → Key)
    (distinct : pins .operation ≠ pins .source) :
    ¬ IngressAuthorized pins .source (pins .operation) true .source := by
  intro h
  exact distinct h.1

theorem source_ingress_cannot_execute {Key : Type} (pins : IngressRole → Key) (certificate : Key) :
    ¬ IngressAuthorized pins .source certificate credential .operation := by
  simp [IngressAuthorized]

theorem publication_requires_source_ingress_and_leaf {Key : Type} (pins : IngressRole → Key)
    {surface : IngressRole} {certificate : Key} {credential : Bool}
    (h : IngressAuthorized pins surface certificate credential .source) :
    surface = .source ∧ certificate = pins .source := by
  have same := h.2.2
  cases same
  exact ⟨rfl, h.1⟩

structure IngressState where
  operation : Connections
  source : Connections

def IngressSafe (operationLimit sourceLimit : Nat) (s : IngressState) : Prop :=
  ConnectionsSafe operationLimit s.operation ∧ ConnectionsSafe sourceLimit s.source

inductive IngressStep (operationLimit sourceLimit : Nat) : IngressState → IngressState → Prop where
  | operation (s) (step : ConnectionStep operationLimit s.operation next) :
      IngressStep operationLimit sourceLimit s {s with operation := next}
  | source (s) (step : ConnectionStep sourceLimit s.source next) :
      IngressStep operationLimit sourceLimit s {s with source := next}

theorem ingress_step_preserves_independent_custody (h : IngressSafe operationLimit sourceLimit s)
    (step : IngressStep operationLimit sourceLimit s t) : IngressSafe operationLimit sourceLimit t := by
  cases step with
  | operation s step => exact ⟨connection_step_preserves_custody h.1 step, h.2⟩
  | source s step => exact ⟨h.1, connection_step_preserves_custody h.2 step⟩

theorem operation_transition_preserves_source_state
    (s : IngressState) (_step : ConnectionStep operationLimit s.operation next) :
    ({s with operation := next} : IngressState).source = s.source := rfl

def InvocationHistorySafe (s : State) : Prop :=
  s.calls = s.invocationSnapshots.length ∧ ∀ snapshot ∈ s.invocationSnapshots, snapshot = false

theorem invocation_history_step (h : InvocationHistorySafe s) (step : Step cost budget s t) : InvocationHistorySafe t := by
  cases step <;> simp_all [InvocationHistorySafe]

theorem invocation_history_run (h : InvocationHistorySafe s) (run : Run cost budget s t) : InvocationHistorySafe t := by
  induction run with
  | refl => exact h
  | next history step ih => exact invocation_history_step ih step

theorem cancelled_context_cannot_admit (s : State) (stopped : s.cancelled = true) :
    ¬ (s.token = 1 ∧ Current s ∧ s.cancelled = false) := by simp [stopped]

theorem stale_consumed_view_cannot_create_dispatch_token
    (stale : ¬ Current s) (noToken : s.token = 0) (step : Step cost budget s t) : t.token = 0 := by
  cases step <;> simp_all

theorem cancellation_and_original_hold_composition
    (original : Safe cost budget s) (admission : InvocationHistorySafe s) (run : Run cost budget s t) :
    Safe cost budget t ∧ InvocationHistorySafe t := ⟨safe_run original run,invocation_history_run admission run⟩

/- A release capability's key denotes the immutable original plan commitment,
   not its possibly equal response batch digest. Key is arbitrary: no fixed
   number of plans is assumed. Opaque native tokens, SHA-256 commitment integrity,
   unique durable release intervals and current Cedar/SQL guards are refinement
   premises. These lemmas establish local queue admission, not peer receipt. -/
structure ReleaseEvent (Key : Type) where
  serial : Nat
  preparedPlan : Key
  requestedPlan : Key
  preparedEncoding : Encoding
  requestedEncoding : Encoding
  tokenSession : Nat
  currentSession : Nat
  current : Bool

def ReleaseBound (e : ReleaseEvent Key) : Prop :=
  e.preparedPlan = e.requestedPlan ∧ e.preparedEncoding = e.requestedEncoding ∧
  e.tokenSession = e.currentSession ∧ e.current = true

structure Releases (Key : Type) where
  emitted : List (ReleaseEvent Key) := []
  held : Nat

def ReleaseSafe (cost : Nat) (s : Releases Key) : Prop :=
  (∀ e ∈ s.emitted, ReleaseBound e) ∧ (s.emitted.map ReleaseEvent.serial).Nodup ∧ s.held = cost

inductive ReleaseStep : Releases Key → Releases Key → Prop where
  | enqueue (s) (e) (binding : ReleaseBound e)
      (affine : e.serial ∉ s.emitted.map ReleaseEvent.serial) :
      ReleaseStep s {s with emitted := e :: s.emitted}
  | rejectOrObserveOrRestart (s) : ReleaseStep s s

theorem release_step_preserves_original_binding
    (h : ReleaseSafe cost s) (step : ReleaseStep s t) : ReleaseSafe cost t := by
  cases step <;> simp_all [ReleaseSafe]

inductive ReleaseRun : Releases Key → Releases Key → Prop where
  | refl (s) : ReleaseRun s s
  | next : ReleaseRun a b → ReleaseStep b c → ReleaseRun a c

theorem release_run_preserves_original_binding
    (h : ReleaseSafe cost s) (run : ReleaseRun s t) : ReleaseSafe cost t := by
  induction run with
  | refl => exact h
  | next history step ih => exact release_step_preserves_original_binding ih step

theorem foreign_plan_cannot_release (e : ReleaseEvent Key)
    (different : e.preparedPlan ≠ e.requestedPlan) : ¬ ReleaseBound e := by
  intro h; exact different h.1

theorem changed_encoding_cannot_release (e : ReleaseEvent Key)
    (different : e.preparedEncoding ≠ e.requestedEncoding) : ¬ ReleaseBound e := by
  intro h; exact different h.2.1

theorem restarted_session_cannot_release (e : ReleaseEvent Key)
    (different : e.tokenSession ≠ e.currentSession) : ¬ ReleaseBound e := by
  intro h; exact different h.2.2.1

theorem release_binding_and_execution_composition
    (execution : Safe cost budget s) (admission : InvocationHistorySafe s)
    (history : Run cost budget s t) (release : ReleaseSafe cost r)
    (releases : ReleaseRun r u) :
    Safe cost budget t ∧ InvocationHistorySafe t ∧ ReleaseSafe cost u :=
  ⟨safe_run execution history, invocation_history_run admission history,
    release_run_preserves_original_binding release releases⟩

/- A source commitment identifies bytes; it does not select between conflicting
   provider fields. The native decoder must refine this typed request premise.
   Token caps are not money, pricing proofs, usage receipts or refund authority. -/
structure RequestCaps where
  completion : Option Nat
  legacy : Option Nat

def CapsAdmitted (c : RequestCaps) : Prop :=
  (∃ n, c.completion = some n ∧ c.legacy = none ∧ 0 < n ∧ n ≤ 4096) ∨
  (∃ n, c.legacy = some n ∧ c.completion = none ∧ 0 < n ∧ n ≤ 4096)

def SelectedCap (c : RequestCaps) (n : Nat) : Prop :=
  c.completion = some n ∨ c.legacy = some n

theorem admitted_provider_cap_is_bounded (admitted : CapsAdmitted c)
    (selected : SelectedCap c n) : 0 < n ∧ n ≤ 4096 := by
  rcases admitted with ⟨cap, hc, hl, low, high⟩ | ⟨cap, hl, hc, low, high⟩ <;>
    rcases selected with selected | selected <;> simp_all

theorem competing_provider_caps_cannot_be_admitted
    (modern : c.completion = some a) (legacy : c.legacy = some b) : ¬ CapsAdmitted c := by
  intro admitted
  rcases admitted with ⟨cap, _, absent, _, _⟩ | ⟨cap, _, absent, _, _⟩ <;> simp_all

theorem preferred_cap_precedence_counterexample :
    let c : RequestCaps := ⟨some 32, some 1000000⟩
    c.completion = some 32 ∧ SelectedCap c 1000000 ∧ ¬ CapsAdmitted c := by
  simp [SelectedCap, CapsAdmitted]

theorem request_bounds_and_affine_execution_composition
    (initial : Safe cost budget s) (history : Run cost budget s t)
    (admitted : CapsAdmitted original) :
    Safe cost budget t ∧ (∀ n, SelectedCap original n → 0 < n ∧ n ≤ 4096) :=
  ⟨safe_run initial history, fun _ selected => admitted_provider_cap_is_bounded admitted selected⟩

#print axioms admitted_provider_cap_is_bounded
#print axioms competing_provider_caps_cannot_be_admitted
#print axioms preferred_cap_precedence_counterexample
#print axioms request_bounds_and_affine_execution_composition
#print axioms release_step_preserves_original_binding
#print axioms release_run_preserves_original_binding
#print axioms foreign_plan_cannot_release
#print axioms changed_encoding_cannot_release
#print axioms restarted_session_cannot_release
#print axioms release_binding_and_execution_composition
#print axioms invocation_history_step
#print axioms invocation_history_run
#print axioms cancelled_context_cannot_admit
#print axioms stale_consumed_view_cannot_create_dispatch_token
#print axioms cancellation_and_original_hold_composition
#print axioms operation_leaf_cannot_publish_on_source
#print axioms source_ingress_cannot_execute
#print axioms publication_requires_source_ingress_and_leaf
#print axioms ingress_step_preserves_independent_custody
#print axioms operation_transition_preserves_source_state
#print axioms connection_step_preserves_custody
#print axioms bounded_connections_include_handshakes
#print axioms provider_and_connection_composition
#print axioms lane_step_preserves_bounds
#print axioms execution_saturation_preserves_publication_admission
#print axioms execution_and_admission_composition
#print axioms safe_step
#print axioms safe_run
#print axioms stale_authority_cannot_pass
#print axioms consumed_unknown_retains_original_hold
#print axioms new_rpc_nonce_cannot_select_fresh_state
#print axioms arrow_cannot_weaken_row_authority
#print axioms every_arrow_row_requires_authority
#print axioms shared_name_is_not_key_authority
#print axioms execution_and_encoding_composition
/- Profile registry refinement premises: authenticated source registration, atomic
   task/profile commit, canonical artifact/hash agreement, faithful closed-schema
   interpretation, durable original task floors and final checks serialized with
   native invocation. Whole-image rollback, provider honesty and compiler correctness
   are not conclusions of these declarations. Keys and digests are arbitrary types. -/
section ProfileRegistryProofs
variable {TaskKey ProfileKey Digest : Type}
def ProfileBindings (TaskKey ProfileKey Digest : Type) := TaskKey → ProfileKey → Digest → Prop
variable {roots : ProfileBindings TaskKey ProfileKey Digest}

def ProfileFloor (roots : ProfileBindings TaskKey ProfileKey Digest) (profile : ProfileKey) (digest : Digest) : Prop :=
  ∀ key original, roots key profile original → original = digest

def NoProfileFork (roots : ProfileBindings TaskKey ProfileKey Digest) : Prop :=
  ∀ a b profile da db, roots a profile da → roots b profile db → da = db

def TaskProfileCompatible (roots : ProfileBindings TaskKey ProfileKey Digest) (key : TaskKey) (profile : ProfileKey) (digest : Digest) : Prop :=
  ∀ p d, roots key p d → p = profile ∧ d = digest

def NoTaskProfileFork (roots : ProfileBindings TaskKey ProfileKey Digest) : Prop :=
  ∀ key p q d e, roots key p d → roots key q e → p = q ∧ d = e

def RegisterProfile (roots : ProfileBindings TaskKey ProfileKey Digest) (key : TaskKey) (profile : ProfileKey) (digest : Digest) :
    ProfileBindings TaskKey ProfileKey Digest :=
  fun k p d => roots k p d ∨ (k = key ∧ p = profile ∧ d = digest)

theorem registration_preserves_original_profile_binding
    (original : roots task profile digest) :
    RegisterProfile roots key candidate proposed task profile digest := Or.inl original

theorem profile_registration_cannot_fork
    (safe : NoProfileFork roots) (floor : ProfileFloor roots profile digest) :
    NoProfileFork (RegisterProfile roots key profile digest) := by
  intro a b p da db ha hb
  rcases ha with oldA | ⟨_, profileA, digestA⟩ <;>
    rcases hb with oldB | ⟨_, profileB, digestB⟩
  · exact safe a b p da db oldA oldB
  · subst p; subst db; exact floor a da oldA
  · subst p; subst da; exact (floor b db oldB).symm
  · exact digestA.trans digestB.symm

theorem missing_registry_cannot_erase_original_floor
    (original : roots task profile digest) (changed : digest ≠ proposed) :
    ¬ ProfileFloor roots profile proposed := by
  intro floor
  exact changed (floor task digest original)

theorem original_task_registration_cannot_rebind
    (safe : NoTaskProfileFork roots) (compatible : TaskProfileCompatible roots key profile digest) :
    NoTaskProfileFork (RegisterProfile roots key profile digest) := by
  intro task p q d e ha hb
  rcases ha with oldA | ⟨taskA,profileA,digestA⟩ <;>
    rcases hb with oldB | ⟨taskB,profileB,digestB⟩
  · exact safe task p q d e oldA oldB
  · subst task; subst q; subst e; exact compatible p d oldA
  · subst task; subst p; subst d
    have h := compatible q e oldB
    exact ⟨h.1.symm,h.2.symm⟩
  · exact ⟨profileA.trans profileB.symm,digestA.trans digestB.symm⟩

theorem exact_profile_registration_is_idempotent
    (original : roots key profile digest) : RegisterProfile roots key profile digest = roots := by
  funext t p d
  apply propext
  constructor
  · intro registered
    rcases registered with old | ⟨rfl,rfl,rfl⟩
    · exact old
    · exact original
  · exact Or.inl

structure ProfileEffect (Digest : Type) where
  original : Digest
  proposal : Digest
  registry : Option Digest
  floorMatches : Bool
  schemaClosed : Bool
  providerPath : Bool
  policyAllowed : Bool

def ProfileEffectAuthorized (e : ProfileEffect Digest) : Prop :=
  e.proposal = e.original ∧ e.registry = some e.original ∧
  e.floorMatches = true ∧ e.schemaClosed = true ∧ e.providerPath = true ∧ e.policyAllowed = true

theorem profile_identity_and_digest_are_jointly_guarded (event : ProfileEffect (String × String))
    (checked : ProfileEffectAuthorized event) :
    event.proposal.1 = event.original.1 ∧ event.proposal.2 = event.original.2 :=
  ⟨congrArg Prod.fst checked.1,congrArg Prod.snd checked.1⟩

structure ProfileExecution (Digest : Type) where
  native : State
  effects : List (ProfileEffect Digest)

def ProfileExecutionSafe (cost budget : Nat) (s : ProfileExecution Digest) : Prop :=
  Safe cost budget s.native ∧ (∀ e ∈ s.effects, ProfileEffectAuthorized e) ∧ s.effects.length = s.native.calls

inductive ProfileExecutionStep (cost budget : Nat) : ProfileExecution Digest → ProfileExecution Digest → Prop where
  | internal (s) (native : Step cost budget s.native target) (noSend : target.calls = s.native.calls) :
      ProfileExecutionStep cost budget s ⟨target,s.effects⟩
  | invoke (s) (native : Step cost budget s.native target) (oneSend : target.calls = s.native.calls + 1)
      (checked : ProfileEffectAuthorized event) :
      ProfileExecutionStep cost budget s ⟨target,s.effects ++ [event]⟩

theorem source_profile_and_native_execution_step
    (safe : ProfileExecutionSafe cost budget s) (step : ProfileExecutionStep cost budget s t) :
    ProfileExecutionSafe cost budget t := by
  rcases safe with ⟨execution, effects, count⟩
  cases step with
  | internal s native noSend => exact ⟨safe_step execution native,effects,by simpa [noSend] using count⟩
  | invoke s native oneSend checked =>
    refine ⟨safe_step execution native, ?_, ?_⟩
    · intro e member
      simp only [List.mem_append, List.mem_singleton] at member
      rcases member with old | rfl
      · exact effects e old
      · exact checked
    · simp [List.length_append, count, oneSend]

theorem profile_registry_mismatch_cannot_send
    (mismatch : event.registry ≠ some event.original) : ¬ ProfileEffectAuthorized event := by
  intro checked
  exact mismatch checked.2.1

inductive ProfileExecutionRun (cost budget : Nat) : ProfileExecution Digest → ProfileExecution Digest → Prop where
  | refl (s) : ProfileExecutionRun cost budget s s
  | next : ProfileExecutionRun cost budget a b → ProfileExecutionStep cost budget b c → ProfileExecutionRun cost budget a c

theorem source_profile_and_native_execution_run
    (initial : ProfileExecutionSafe cost budget s) (run : ProfileExecutionRun cost budget s t) :
    ProfileExecutionSafe cost budget t := by
  induction run with
  | refl => exact initial
  | next history step ih => exact source_profile_and_native_execution_step ih step

theorem profile_recovery_retains_original_hold
    (initial : ProfileExecutionSafe cost budget s) (run : ProfileExecutionRun cost budget s t)
    (consumed : t.native.stage ≥ 1) :
    t.native.held = cost ∧ t.native.calls ≤ 1 ∧ (∀ e ∈ t.effects, ProfileEffectAuthorized e) := by
  have safe := source_profile_and_native_execution_run initial run
  exact ⟨safe.1.2.2.2.1 consumed,safe.1.2.1,safe.2.1⟩

theorem unknown_extension_cannot_authorize_profile_effect
    (unknown : event.schemaClosed = false) : ¬ ProfileEffectAuthorized event := by
  simp [ProfileEffectAuthorized, unknown]

theorem untyped_fallback_cannot_authorize_profile_effect
    (wrong : event.providerPath = false) : ¬ ProfileEffectAuthorized event := by
  simp [ProfileEffectAuthorized, wrong]

#print axioms registration_preserves_original_profile_binding
#print axioms profile_registration_cannot_fork
#print axioms original_task_registration_cannot_rebind
#print axioms missing_registry_cannot_erase_original_floor
#print axioms exact_profile_registration_is_idempotent
#print axioms source_profile_and_native_execution_step
#print axioms source_profile_and_native_execution_run
#print axioms profile_recovery_retains_original_hold
#print axioms profile_registry_mismatch_cannot_send
#print axioms unknown_extension_cannot_authorize_profile_effect
#print axioms untyped_fallback_cannot_authorize_profile_effect
#print axioms profile_identity_and_digest_are_jointly_guarded
end ProfileRegistryProofs
end Weaver.ProviderRpc
