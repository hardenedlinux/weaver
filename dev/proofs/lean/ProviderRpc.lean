namespace Weaver.ProviderRpc

/- The native complete-family projection includes every effect kind. claimsMatch
   means every retained row joins its original execution kind, not an RPC flag. -/
def SharedExecutionExposure (claimsMatch : Bool)
    (requests messages providers : List Nat) (held budget originalBudget : Nat) : Prop :=
  claimsMatch = true ∧ budget = originalBudget ∧
  requests.sum + messages.sum + providers.sum = held ∧ held ≤ budget

theorem shared_exposure_keeps_original_budget
    (accepted : SharedExecutionExposure claims requests messages providers held budget originalBudget) :
    requests.sum + messages.sum + providers.sum ≤ held ∧ held ≤ originalBudget := by
  exact ⟨Nat.le_of_eq accepted.2.2.1, accepted.2.1 ▸ accepted.2.2.2⟩

theorem orphaned_hold_blocks_new_admission
    (orphaned : requests.sum + messages.sum + providers.sum ≠ held) :
    ¬ SharedExecutionExposure claims requests messages providers held budget originalBudget :=
  fun accepted => orphaned accepted.2.2.1

theorem changed_budget_projection_blocks_all_effects (changed : budget ≠ originalBudget) :
    ¬ SharedExecutionExposure claims requests messages providers held budget originalBudget :=
  fun accepted => changed accepted.2.1

theorem missing_retained_claim_blocks_family :
    ¬ SharedExecutionExposure false requests messages providers held budget originalBudget := by
  simp [SharedExecutionExposure]

theorem separate_domain_checks_do_not_prove_shared_retention :
    4 ≤ 4 ∧ 4 ≤ 4 ∧ ¬ SharedExecutionExposure true [4] [4] [] 4 12 12 := by
  simp [SharedExecutionExposure]

#print axioms shared_exposure_keeps_original_budget
#print axioms changed_budget_projection_blocks_all_effects

/- Native final-use projection: complete family provider reservations are read
   under the same deciding writer as claim, hold and actual callback. This is a
   lower bound, not settlement authority or proof of an anti-rollback store. -/
def ProviderExposure (claim : Bool) (reserved original held budget : Nat)
    (reservations : List Nat) : Prop :=
  claim = true ∧ reserved = original ∧ reservations.sum ≤ held ∧ held ≤ budget

theorem missing_claim_blocks_final_use
    (missing : claim = false) : ¬ ProviderExposure claim reserved original held budget reservations := by
  intro accepted
  simp [ProviderExposure, missing] at accepted

theorem changed_reservation_blocks_final_use
    (changed : reserved ≠ original) : ¬ ProviderExposure claim reserved original held budget reservations :=
  fun accepted => changed accepted.2.1

theorem shared_provider_exposure_cannot_be_released
    (insufficient : held < reservations.sum) :
    ¬ ProviderExposure claim reserved original held budget reservations := by
  intro accepted
  have bound := accepted.2.2.1
  omega

theorem individual_hold_only_is_insufficient :
    4 ≤ 4 ∧ ¬ ProviderExposure true 4 4 4 8 [4, 4] := by
  simp [ProviderExposure]

#print axioms missing_claim_blocks_final_use
#print axioms shared_provider_exposure_cannot_be_released

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

/- Transport may progress without an application RPC. This projection requires
   native refinement: dialing never emits an Execute/Publish operation. -/
structure GatewayState where
  provider : State
  connections : Connections

def GatewaySafe (cost budget limit : Nat) (s : GatewayState) : Prop :=
  Safe cost budget s.provider ∧ ConnectionsSafe limit s.connections

inductive GatewayStep (cost budget limit : Nat) : GatewayState → GatewayState → Prop where
  | transport (s) (step : ConnectionStep limit s.connections next) :
      GatewayStep cost budget limit s {s with connections := next}
  | execution (s) (step : Step cost budget s.provider next) :
      GatewayStep cost budget limit s {s with provider := next}

theorem gateway_step_preserves_original_execution_and_custody
    (safe : GatewaySafe cost budget limit s) (step : GatewayStep cost budget limit s t) :
    GatewaySafe cost budget limit t := by
  cases step with
  | transport _ step => exact ⟨safe.1, connection_step_preserves_custody safe.2 step⟩
  | execution _ step => exact ⟨safe_step safe.1 step, safe.2⟩

inductive GatewayRun (cost budget limit : Nat) : GatewayState → GatewayState → Prop where
  | refl (s) : GatewayRun cost budget limit s s
  | next : GatewayRun cost budget limit a b → GatewayStep cost budget limit b c → GatewayRun cost budget limit a c

theorem gateway_run_preserves_original_execution_and_custody
    (initial : GatewaySafe cost budget limit s) (run : GatewayRun cost budget limit s t) :
    GatewaySafe cost budget limit t := by
  induction run with
  | refl => exact initial
  | next _ step ih => exact gateway_step_preserves_original_execution_and_custody ih step

#print axioms gateway_step_preserves_original_execution_and_custody
#print axioms gateway_run_preserves_original_execution_and_custody

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

/- Transport envelope in the existing provider owner. Context is the full
   authenticated deciding view supplied by the existing floor owner, not a
   second Policy/history/account evaluator. A native mapping must cover original
   scope, profile, Policy/schema, shared budget, history and owner coordinates.
   Batch values are immutable owned data; queue admission is not peer receipt. -/
namespace Flow

structure Batch (Key Context : Type) where
  binding : ReleaseEvent Key
  context : Context
  first : Nat
  rows : Nat
  allowed : Nat → Prop

def BatchSafe (b : Batch Key Context) : Prop :=
  ReleaseBound b.binding ∧ RowsAuthorized b.binding.requestedEncoding b.allowed b.first b.rows ∧
  0 < b.rows ∧ b.rows ≤ 32 ∧ (b.binding.requestedEncoding = Encoding.protobuf → b.rows = 1)

structure Pipe (Key Context : Type) where
  core : Releases Key
  context : Context
  originalPlan : Key
  authorize : Context → Nat → Prop
  session : Nat
  encoding : Encoding
  stopped : Bool := false
  queue : List (Batch Key Context) := []
  slot : Bool := false
  pending : Option (Batch Key Context) := none
  token : Bool := false
  commitPending : Bool := false

def Eligible (s : Pipe Key Context) (b : Batch Key Context) : Prop :=
  BatchSafe b ∧ b.context = s.context ∧ b.allowed = s.authorize s.context ∧
  b.binding.requestedPlan = s.originalPlan ∧ b.binding.currentSession = s.session ∧
  b.binding.requestedEncoding = s.encoding ∧ s.stopped = false

def CanEmit (s : Pipe Key Context) (b : Batch Key Context) : Prop :=
  s.slot = true ∧ s.pending = some b ∧ s.token = true ∧ Eligible s b

def Capacity (s : Pipe Key Context) : Prop :=
  s.queue.length + (if s.slot then 1 else 0) ≤ 2

def Continuations (s : Pipe Key Context) : Prop :=
  (s.token = true → ∃ b, s.pending = some b ∧ s.commitPending = false ∧ b.binding.currentSession = s.session) ∧
  (s.commitPending = true → ∃ b, s.pending = some b ∧ s.token = false)

def Safe (cost : Nat) (s : Pipe Key Context) : Prop :=
  ReleaseSafe cost s.core ∧ Capacity s ∧ (∀ b ∈ s.queue, BatchSafe b) ∧ Continuations s

inductive Step : Pipe Key Context → Pipe Key Context → Prop where
  | reserve (s) (room : s.queue.length < 2) (free : s.slot = false) (live : s.stopped = false) :
      Step s {s with slot := true}
  | dropSlot (s) : Step s {s with slot := false}
  | prepare (s b) (slot : s.slot = true) (fresh : s.pending = none) (current : Eligible s b) :
      Step s {s with pending := some b, token := true}
  | enqueue (s b) (ready : CanEmit s b) (affine : b.binding.serial ∉ s.core.emitted.map ReleaseEvent.serial) :
      Step s {s with
        core := {s.core with emitted := b.binding :: s.core.emitted}
        queue := s.queue ++ [b]
        slot := false
        token := false
        commitPending := true}
  | commitRelease (s) (live : s.commitPending = true) :
      Step s {s with pending := none, commitPending := false}
  | publishContext (s context) : Step s {s with context := context}
  | cancel (s) : Step s {s with stopped := true}
  | crash (s) : Step s {s with session := s.session + 1, slot := false, token := false, commitPending := false}
  | dequeue (s b tail) (queued : s.queue = b :: tail) : Step s {s with queue := tail}
  | discardQueue (s) : Step s {s with queue := []}
  | reconnectOrObserve (s) : Step s s

variable {Key Context : Type} {s t : Pipe Key Context}

theorem release_projection (event : Step s t) : ReleaseStep s.core t.core := by
  cases event with
  | enqueue b ready affine => exact .enqueue _ _ ready.2.2.2.1.1 affine
  | _ => exact .rejectOrObserveOrRestart _

theorem step_preserves_capacity (capacity : Capacity s) (event : Step s t) : Capacity t := by
  cases event <;> simp_all [Capacity, CanEmit] <;> omega

theorem step_preserves_batch_authority
    (known : ∀ b ∈ s.queue, BatchSafe b) (event : Step s t) : ∀ b ∈ t.queue, BatchSafe b := by
  cases event <;> simp_all [CanEmit, Eligible] <;> grind

theorem step_preserves_continuations (known : Continuations s) (event : Step s t) : Continuations t := by
  cases event <;> simp_all [Continuations, CanEmit, Eligible] <;> grind

theorem safe_step (safe : Safe cost s) (event : Step s t) : Safe cost t :=
  ⟨release_step_preserves_original_binding safe.1 (release_projection event),
   step_preserves_capacity safe.2.1 event, step_preserves_batch_authority safe.2.2.1 event,
   step_preserves_continuations safe.2.2.2 event⟩

inductive Run : Pipe Key Context → Pipe Key Context → Prop where
  | refl (state : Pipe Key Context) : Run state state
  | next {a b c : Pipe Key Context} : Run a b → Step b c → Run a c

theorem safe_run (safe : Safe cost s) (history : Run s t) : Safe cost t := by
  induction history with
  | refl => exact safe
  | next prior event ih => exact safe_step ih event

theorem projects_existing_release_history (history : Run s t) : ReleaseRun s.core t.core := by
  induction history with
  | refl => exact .refl _
  | next prior event ih => exact .next ih (release_projection event)

theorem stale_context_blocks_even_reserved_slot (stale : b.context ≠ s.context) : ¬ Flow.CanEmit s b := by
  intro ready
  exact stale ready.2.2.2.2.1

theorem observed_cancellation_blocks_release (stopped : s.stopped = true) : ¬ Flow.CanEmit s b := by
  simp_all [CanEmit, Eligible]

theorem final_guard_checks_actual_owner_rows (ready : CanEmit s b) (within : offset < b.rows) :
    s.authorize s.context (b.first + offset) := by
  rcases ready with ⟨_, _, _, bounds, _, rows, _, _, _, _⟩
  have admitted := bounds.2.1 offset within
  rw [rows] at admitted
  exact admitted

theorem original_plan_survives_batching (ready : CanEmit s b) : b.binding.preparedPlan = s.originalPlan := by
  rcases ready with ⟨_, _, _, bounds, _, _, plan, _, _, _⟩
  exact bounds.1.1.trans plan

theorem crash_cannot_recreate_unknown_release (s : Pipe Key Context) (b : Batch Key Context) :
    ¬ CanEmit {s with session := s.session + 1, slot := false, token := false, commitPending := false} b := by
  simp [CanEmit]

theorem uncertain_pending_survives_step
    (pending : s.pending = some batch) (noToken : s.token = false) (noCommit : s.commitPending = false)
    (event : Step s t) : t.pending = some batch ∧ t.token = false ∧ t.commitPending = false := by
  cases event <;> simp_all [CanEmit]

theorem uncertain_pending_survives_reconnect_history
    (pending : s.pending = some batch) (noToken : s.token = false) (noCommit : s.commitPending = false)
    (history : Run s t) : t.pending = some batch ∧ t.token = false ∧ t.commitPending = false := by
  induction history with
  | refl => exact ⟨pending, noToken, noCommit⟩
  | next prior event ih => exact uncertain_pending_survives_step ih.1 ih.2.1 ih.2.2 event

theorem transport_history_preserves_original_hold (safe : Safe cost s) (history : Run s t) :
    t.core.held = cost ∧ (∀ b ∈ t.queue, BatchSafe b) :=
  ⟨(safe_run safe history).1.2.2, (safe_run safe history).2.2.1⟩

/-- Composes existing execution and release laws; no account arithmetic or
second authorization machine is reconstructed in the transport envelope. -/
theorem execution_and_backpressure_composition
    (execution : Weaver.ProviderRpc.Safe cost budget a) (invocations : InvocationHistorySafe a)
    (executed : Weaver.ProviderRpc.Run cost budget a b) (pipe : Safe cost s) (flow : Run s t) :
    Weaver.ProviderRpc.Safe cost budget b ∧ InvocationHistorySafe b ∧
      ReleaseSafe cost t.core ∧ Capacity t ∧ t.core.held = cost := by
  have composed := release_binding_and_execution_composition execution invocations executed pipe.1
    (projects_existing_release_history flow)
  exact ⟨composed.1, composed.2.1, composed.2.2, (safe_run pipe flow).2.1,
    (transport_history_preserves_original_hold pipe flow).1⟩

#print axioms release_projection
#print axioms safe_run
#print axioms stale_context_blocks_even_reserved_slot
#print axioms observed_cancellation_blocks_release
#print axioms final_guard_checks_actual_owner_rows
#print axioms original_plan_survives_batching
#print axioms crash_cannot_recreate_unknown_release
#print axioms uncertain_pending_survives_reconnect_history
#print axioms transport_history_preserves_original_hold
#print axioms execution_and_backpressure_composition
end Flow

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

theorem source_profile_and_rust_execution_step
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

theorem source_profile_and_rust_execution_run
    (initial : ProfileExecutionSafe cost budget s) (run : ProfileExecutionRun cost budget s t) :
    ProfileExecutionSafe cost budget t := by
  induction run with
  | refl => exact initial
  | next history step ih => exact source_profile_and_rust_execution_step ih step

theorem profile_recovery_retains_original_hold
    (initial : ProfileExecutionSafe cost budget s) (run : ProfileExecutionRun cost budget s t)
    (consumed : t.native.stage ≥ 1) :
    t.native.held = cost ∧ t.native.calls ≤ 1 ∧ (∀ e ∈ t.effects, ProfileEffectAuthorized e) := by
  have safe := source_profile_and_rust_execution_run initial run
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
#print axioms source_profile_and_rust_execution_step
#print axioms source_profile_and_rust_execution_run
#print axioms profile_recovery_retains_original_hold
#print axioms profile_registry_mismatch_cannot_send
#print axioms unknown_extension_cannot_authorize_profile_effect
#print axioms untyped_fallback_cannot_authorize_profile_effect
#print axioms profile_identity_and_digest_are_jointly_guarded
end ProfileRegistryProofs
namespace DecodeAllocation

/- Conditional allocator law, not a bound on the entire Go heap. Native code
   must route each Arrow buffer request through charge before allocation.
   Free leaves used unchanged; each batch has an independent accumulator. -/
def charge (limit used requested : Nat) : Option Nat :=
  if used + requested ≤ limit then some (used + requested) else none

theorem admitted_charge_is_bounded (h : charge limit used requested = some next) :
    next ≤ limit ∧ used ≤ next := by
  unfold charge at h
  split at h <;> simp_all <;> omega

theorem rejected_charge_cannot_allocate (h : limit < used + requested) :
    charge limit used requested = none := by
  simp [charge, Nat.not_le.mpr h]

inductive Run (limit : Nat) : Nat → Nat → Prop where
  | refl (used) : Run limit used used
  | allocate (before after requested next)
      (prior : Run limit before after)
      (admitted : charge limit after requested = some next) : Run limit before next
  | free (before after) (prior : Run limit before after) : Run limit before after
  | reject (before after requested) (prior : Run limit before after)
      (denied : charge limit after requested = none) : Run limit before after

theorem finite_run_preserves_cumulative_bound (run : Run limit initial final)
    (start : initial ≤ limit) : final ≤ limit ∧ initial ≤ final := by
  induction run with
  | refl => exact ⟨start, Nat.le_refl _⟩
  | allocate after requested next prior admitted ih =>
    have step := admitted_charge_is_bounded admitted
    exact ⟨step.1, Nat.le_trans ih.2 step.2⟩
  | free after prior ih => exact ih
  | reject after requested prior denied ih => exact ih

theorem wire_bound_does_not_prove_allocation_bound :
    1 ≤ (4 : Nat) ∧ charge 8 0 9 = none := by decide

end DecodeAllocation
#print axioms DecodeAllocation.finite_run_preserves_cumulative_bound
#print axioms DecodeAllocation.wire_bound_does_not_prove_allocation_bound

/-- Context is the complete current effect image, including Policy/fence,
shared budget/history and optional-field presence. The SDK representation must
preserve that value; immutable plan literals alone do not satisfy this premise. -/
theorem equivalent_context_preserves_emission {Key Context Representation : Type} {b : Flow.Batch Key Context} {s : Flow.Pipe Key Context}
    (decode : Representation → Context) (encode : Context → Representation)
    (faithful : decode (encode b.context) = b.context) :
    Flow.CanEmit s {b with context := decode (encode b.context)} ↔ Flow.CanEmit s b := by
  simp [faithful]

/-- An otherwise valid prepared frame cannot retain an old mutable context.
No premise about literal construction replaces the actual current-use guard. -/
theorem stale_context_cannot_emit {Key Context : Type} {b : Flow.Batch Key Context} {s : Flow.Pipe Key Context} (changed : b.context ≠ s.context) : ¬ Flow.CanEmit s b := by
  intro emitted
  exact changed emitted.2.2.2.2.1

#print axioms equivalent_context_preserves_emission
#print axioms stale_context_cannot_emit
/- Native premise: all reads belong to one locked deciding transaction and
   no write, wait or external callback intervenes. Context includes Policy,
   profile, fence and shared-domain facts. This premise expires at transaction
   end; it says nothing about a prepared token surviving a later state cut. -/
theorem transaction_local_projection_preserves_each_row
    {Context : Type} (image : Context) (reads : Nat → Context)
    (approve : Context → Nat → Prop) (encoding : Encoding) (first rows : Nat)
    (stable : ∀ offset, offset < rows → reads offset = image) :
    RowsAuthorized encoding (approve image) first rows ↔
      ∀ offset, offset < rows → approve (reads offset) (first + offset) := by
  constructor
  · intro accepted offset within
    rw [stable offset within]
    exact accepted offset within
  · intro accepted offset within
    have allowed := accepted offset within
    rw [stable offset within] at allowed
    exact allowed

theorem transaction_local_batch_cannot_skip_a_denied_row
    {Context : Type} (image : Context) (approve : Context → Nat → Prop)
    (encoding : Encoding) (first rows offset : Nat)
    (within : offset < rows) (denied : ¬ approve image (first + offset)) :
    ¬ RowsAuthorized encoding (approve image) first rows := by
  intro accepted
  exact denied (accepted offset within)

#print axioms transaction_local_projection_preserves_each_row
#print axioms transaction_local_batch_cannot_skip_a_denied_row
/- Encoded bytes are an inert result of a pure host function. The native
   fidelity premise binds them to the original batch; currentness and the affine
   release token are still required at insertion, after preparation has ended. -/
theorem prepared_bytes_cannot_bypass_currentness
    {Key Context Bytes : Type} {b : Flow.Batch Key Context} {s : Flow.Pipe Key Context}
    (encode : Flow.Batch Key Context → Bytes) (bytes : Bytes)
    (changed : b.context ≠ s.context) :
    ¬ (bytes = encode b ∧ Flow.CanEmit s b) := by
  intro accepted
  exact stale_context_cannot_emit changed accepted.2

theorem prepared_bytes_cannot_replace_affine_token
    {Key Context Bytes : Type} {b : Flow.Batch Key Context} {s : Flow.Pipe Key Context}
    (encode : Flow.Batch Key Context → Bytes) (bytes : Bytes)
    (spent : s.token = false) :
    ¬ (bytes = encode b ∧ Flow.CanEmit s b) := by
  intro accepted
  have live := accepted.2.2.2.1
  simp [spent] at live

#print axioms prepared_bytes_cannot_bypass_currentness
#print axioms prepared_bytes_cannot_replace_affine_token
/- A prospective native transport receipt must certify BOTH local drain and
absence of every future application-write capability, including SDK tasks.
This is a host premise; the current reqwest backend exports no such receipt. -/
namespace RequestWriteFence
structure State where
  tail : Bool
  writable : Bool
  eof : Bool
  responseHead : Bool
  deriving DecidableEq

def Sealed (s : State) : Prop := s.tail = false ∧ s.writable = false

def CanWrite (s : State) : Prop := s.writable = true

theorem seal_excludes_future_application_write (sealed : Sealed s) : ¬ CanWrite s := by
  simp [CanWrite, sealed.2]

theorem eof_and_response_head_do_not_certify_seal :
    let s : State := ⟨true, true, true, true⟩
    s.eof = true ∧ s.responseHead = true ∧ ¬ Sealed s := by simp [Sealed]

theorem local_drain_without_writer_retirement_is_insufficient :
    let s : State := ⟨false, true, true, false⟩
    s.tail = false ∧ ¬ Sealed s := by simp [Sealed]

/-- Sealing the request does not authorize response rows. Compose with the
existing current-context/affine guard, never substitute a transport observation. -/
theorem sealed_request_cannot_bypass_response_currentness
    {Key Context : Type} {b : Flow.Batch Key Context} {s : Flow.Pipe Key Context}
    (transport : State) (_sealed : Sealed transport) (changed : b.context ≠ s.context) :
    ¬ Flow.CanEmit s b := stale_context_cannot_emit changed

#print axioms seal_excludes_future_application_write
#print axioms eof_and_response_head_do_not_certify_seal
#print axioms local_drain_without_writer_retirement_is_insufficient
#print axioms sealed_request_cannot_bypass_response_currentness
end RequestWriteFence
end Weaver.ProviderRpc
