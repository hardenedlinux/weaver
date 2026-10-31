namespace Weaver.PublicationRecovery

/- Native refinement premises: authenticated stable source scope; exact domain-
   separated request commitment; durable non-rollback SQLite transaction jointly
   writes authority/schema and immutable decision; retained records are not pruned.
   head counts committed versions (zero is absent), not the wire revision ordinal.
   Schema validation, storage durability and authenticated transport are native
   obligations; this proof does not establish anti-rollback anchors. -/
structure Decision where
  payload : Nat
  parent : Nat
  requestedFence : Nat
  committed : Bool
  resultHead : Nat
  resultFence : Nat
  deriving DecidableEq

/-- Immutable commitment to the complete approved artifact and its command.
The native adapter interprets artifact/sourceCut as authenticated commitments. -/
structure ReviewRegistration where
  payload : Nat
  parent : Nat
  requestedFence : Nat
  artifact : Nat
  sourceCut : Nat
  deriving DecidableEq

structure State (Key : Type) where
  head : Nat := 0
  fence : Nat := 1
  records : Key → Option Decision := fun _ => none
  pending : Key → Option (Nat × Nat × Nat) := fun _ => none
  commits : List Key := []
  held : Nat := 4
  calls : Nat := 1
  reviewAnchor : Key → Option ReviewRegistration := fun _ => none
  reviewProjection : Key → Option ReviewRegistration := fun _ => none
  registrarOwner : Nat := 1
  registrarEpoch : Nat := 0
  reviewCut : Nat := 0
  reviewRequired : Key → Bool := fun _ => false

variable {Key : Type}

def write [DecidableEq Key] (records : Key → Option Value) (id : Key) (d : Value) :=
  fun key => if key = id then some d else records key

def clear [DecidableEq Key] (records : Key → Option Value) (id : Key) :=
  fun key => if key = id then none else records key

def Extends (s t : State Key) : Prop := ∀ id d, s.records id = some d → t.records id = some d
def Safe (held calls : Nat) (s : State Key) : Prop := s.head = s.commits.length ∧ s.held = held ∧ s.calls = calls

/-- Local native admission only. Payload/parent stand for exact command/head
commitments under the native encoding premise. This predicate does not establish
independent registry recovery, Delta validity or registrar authentication. -/
def LocalReviewAdmissible (s : State Key) (id : Key) (payload fence : Nat) : Prop :=
  s.reviewRequired id = true → ∃ e, s.reviewProjection id = some e ∧
    e.payload = payload ∧ e.parent = s.head ∧ e.requestedFence = fence

inductive Step [DecidableEq Key] : State Key → State Key → Prop where
  | stage (s : State Key) (id : Key) (q : Nat × Nat × Nat) (fresh : s.records id = none)
      (bound : s.pending id = none ∨ s.pending id = some q) :
      Step s {s with pending := write s.pending id q}
  | stageReviewed (s : State Key) (id : Key) (q : Nat × Nat × Nat) (fresh : s.records id = none)
      (bound : s.pending id = none ∨ s.pending id = some q) :
      Step s {s with pending := write s.pending id q, reviewRequired := fun key => if key = id then true else s.reviewRequired key}
  | commit (s : State Key) (id : Key) (payload fence : Nat) (fresh : s.records id = none) (monotone : s.fence ≤ fence)
      (bound : s.pending id = none ∨ s.pending id = some (payload,s.head,fence))
      (review : LocalReviewAdmissible s id payload fence) :
      Step s {s with head := s.head+1, fence := fence, commits := s.commits ++ [id], records := write s.records id ⟨payload,s.head,fence,true,s.head+1,fence⟩, pending := clear s.pending id}
  | reject (s : State Key) (id : Key) (payload parent fence : Nat) (fresh : s.records id = none)
      (conflict : parent ≠ s.head ∨ fence < s.fence)
      (bound : s.pending id = none ∨ s.pending id = some (payload,parent,fence)) :
      Step s {s with records := write s.records id ⟨payload,parent,fence,false,s.head,s.fence⟩, pending := clear s.pending id}
  | replayOrObservationOrRestart (s) : Step s s
  | registerReview (s : State Key) (id : Key) (entry : ReviewRegistration) (actor epoch : Nat)
      (caller : actor = s.registrarOwner ∧ epoch = s.registrarEpoch)
      (fresh : s.reviewAnchor id = none)
      (pending : s.pending id = some (entry.payload,entry.parent,entry.requestedFence))
      (current : entry.parent = s.head ∧ s.fence ≤ entry.requestedFence ∧ entry.sourceCut = s.reviewCut) :
      Step s {s with reviewAnchor := write s.reviewAnchor id entry}
  | restoreReviewProjection (s : State Key) (image : Key → Option ReviewRegistration) :
      Step s {s with reviewProjection := image}
  | recoverReviewProjection (s : State Key) :
      Step s {s with reviewProjection := s.reviewAnchor}
  | rotateRegistrar (s : State Key) (owner : Nat) :
      Step s {s with registrarOwner := owner, registrarEpoch := s.registrarEpoch + 1}
  | advanceReviewCut (s : State Key) : Step s {s with reviewCut := s.reviewCut + 1}

variable {s t : State Key}
variable {held calls : Nat}

theorem step_preserves_original_decisions [DecidableEq Key] (step : Step s t) : Extends s t := by
  intro key d existing
  cases step with
  | stage | stageReviewed => exact existing
  | commit id payload fence fresh monotone bound review =>
    by_cases same : key = id
    · subst key; rw [fresh] at existing; contradiction
    · simpa [write, same] using existing
  | reject id payload parent fence fresh conflict bound =>
    by_cases same : key = id
    · subst key; rw [fresh] at existing; contradiction
    · simpa [write, same] using existing
  | replayOrObservationOrRestart => exact existing
  | registerReview | restoreReviewProjection | recoverReviewProjection | rotateRegistrar | advanceReviewCut => exact existing

theorem step_preserves_accounting [DecidableEq Key] (h : Safe held calls s) (step : Step s t) : Safe held calls t := by
  cases step <;> simp_all [Safe]

def Ready (s : State Key) : Prop := ∀ id, s.pending id = none

def TaskBirthCommitted (s : State Key) (id : Key) : Prop :=
  ∃ d, s.records id = some d ∧ d.committed = true

variable {id : Key} {d : Decision}

theorem unresolved_birth_cannot_authorize (unknown : s.records id = none) : ¬ TaskBirthCommitted s id := by
  simp [TaskBirthCommitted,unknown]

theorem rejected_birth_cannot_authorize (recorded : s.records id = some d) (rejected : d.committed = false) :
    ¬ TaskBirthCommitted s id := by simp [TaskBirthCommitted,recorded,rejected]

def PreservesIntents (s t : State Key) : Prop := ∀ id q, s.pending id = some q →
  t.pending id = some q ∨ ∃ d, t.records id = some d ∧ (d.payload,d.parent,d.requestedFence) = q

theorem step_preserves_original_intents [DecidableEq Key] (step : Step s t) : PreservesIntents s t := by
  intro key q existing
  cases step with
  | stage id candidate fresh bound | stageReviewed id candidate fresh bound =>
    by_cases same : key = id <;> simp_all [write]
  | commit id payload fence fresh monotone bound review =>
    by_cases same : key = id <;> simp_all [write, clear]
  | reject id payload parent fence fresh conflict bound =>
    by_cases same : key = id <;> simp_all [write, clear]
  | replayOrObservationOrRestart => exact Or.inl existing
  | registerReview | restoreReviewProjection | recoverReviewProjection | rotateRegistrar | advanceReviewCut => exact Or.inl existing

theorem staged_intent_blocks_effect_readiness [DecidableEq Key] (id : Key) (q : Nat × Nat × Nat) :
    ¬ Ready {s with pending := write s.pending id q} := by
  intro ready
  have impossible := ready id
  simp [write] at impossible

theorem resolving_one_key_preserves_sibling [DecidableEq Key] (id sibling : Key) (different : sibling ≠ id) :
    clear s.pending id sibling = s.pending sibling := by simp [clear, different]

inductive Run [DecidableEq Key] : State Key → State Key → Prop where
  | refl (s : State Key) : Run s s
  | next {a b c : State Key} : Run a b → Step b c → Run a c

theorem run_preserves_original_decisions [DecidableEq Key] (run : Run s t) : Extends s t := by
  induction run with
  | refl => intro id d existing; exact existing
  | next history step ih =>
    intro id d existing
    exact step_preserves_original_decisions step id d (ih id d existing)

theorem run_preserves_original_intents [DecidableEq Key] (run : Run s t) : PreservesIntents s t := by
  induction run with
  | refl => intro id q existing; exact Or.inl existing
  | next history step ih =>
    intro id q existing
    rcases ih id q existing with pending | ⟨d, recorded, bound⟩
    · exact step_preserves_original_intents step id q pending
    · exact Or.inr ⟨d, step_preserves_original_decisions step id d recorded, bound⟩

theorem rejected_birth_stays_ineligible_after_recovery [DecidableEq Key] (run : Run s t)
    (recorded : s.records id = some d) (rejected : d.committed = false) : ¬ TaskBirthCommitted t id :=
  rejected_birth_cannot_authorize (run_preserves_original_decisions run id d recorded) rejected

theorem original_committed_birth_survives_policy_changes [DecidableEq Key] (run : Run s t)
    (birth : TaskBirthCommitted s id) : TaskBirthCommitted t id := by
  obtain ⟨d,recorded,committed⟩ := birth
  exact ⟨d,run_preserves_original_decisions run id d recorded,committed⟩

#print axioms rejected_birth_stays_ineligible_after_recovery

#print axioms run_preserves_original_intents
#print axioms staged_intent_blocks_effect_readiness

theorem run_preserves_accounting [DecidableEq Key] (h : Safe held calls s) (run : Run s t) : Safe held calls t := by
  induction run with
  | refl => exact h
  | next history step ih => exact step_preserves_accounting ih step

theorem step_cannot_remove_review_requirement [DecidableEq Key] (step : Step s t)
    (required : s.reviewRequired id = true) : t.reviewRequired id = true := by
  cases step <;> simp_all

theorem recovery_cannot_remove_review_requirement [DecidableEq Key] (run : Run s t)
    (required : s.reviewRequired id = true) : t.reviewRequired id = true := by
  induction run with
  | refl => exact required
  | next history step ih => exact step_cannot_remove_review_requirement step ih

/-- The native adapter must refine this guarded Step at the same SQL pre-state.
An earlier review read followed by an unguarded native commit does not qualify. -/
theorem latched_new_commit_requires_original_local_review [DecidableEq Key]
    (step : Step s t) (required : s.reviewRequired id = true)
    (fresh : s.records id = none) (recorded : t.records id = some d)
    (committed : d.committed = true) :
    ∃ e, s.reviewProjection id = some e ∧ e.payload = d.payload ∧
      e.parent = d.parent ∧ e.requestedFence = d.requestedFence := by
  cases step with
  | commit key payload fence unused monotone bound review =>
    by_cases same : id = key
    · subst key
      simp only [write, ite_true] at recorded
      cases recorded
      exact review required
    · simp_all [write]
  | reject key payload parent fence unused conflict bound =>
    by_cases same : id = key
    · subst key
      simp only [write, ite_true] at recorded
      cases recorded
      simp at committed
    · simp_all [write]
  | _ => simp_all

theorem native_review_recovery_composes_without_releasing_unknown [DecidableEq Key]
    (run : Run s t) (safe : Safe held calls s) (required : s.reviewRequired id = true) :
    t.reviewRequired id = true ∧ PreservesIntents s t ∧ Extends s t ∧ Safe held calls t :=
  ⟨recovery_cannot_remove_review_requirement run required, run_preserves_original_intents run,
    run_preserves_original_decisions run, run_preserves_accounting safe run⟩

#print axioms latched_new_commit_requires_original_local_review
#print axioms native_review_recovery_composes_without_releasing_unknown

variable {id : Key} {entry : ReviewRegistration} {actor epoch : Nat}

/-- Historical registration survives parent advancement and local image loss.
The independent authority's own rollback is deliberately outside Step. -/
theorem step_preserves_review_anchor [DecidableEq Key] (step : Step s t)
    (registered : s.reviewAnchor id = some entry) : t.reviewAnchor id = some entry := by
  cases step with
  | registerReview key candidate actor epoch caller fresh pending current =>
    by_cases same : id = key
    · subst id; rw [fresh] at registered; contradiction
    · simpa [write, same] using registered
  | _ => exact registered

theorem run_preserves_review_anchor [DecidableEq Key] (run : Run s t)
    (registered : s.reviewAnchor id = some entry) : t.reviewAnchor id = some entry := by
  induction run with
  | refl => exact registered
  | next history step ih => exact step_preserves_review_anchor step ih

def RegistryCurrent (s : State Key) (actor epoch : Nat) : Prop :=
  actor = s.registrarOwner ∧ epoch = s.registrarEpoch

def RegisteredCurrent (s : State Key) (id : Key) (entry : ReviewRegistration) (actor epoch : Nat) : Prop :=
  s.reviewAnchor id = some entry ∧ s.reviewProjection = s.reviewAnchor ∧
    RegistryCurrent s actor epoch ∧ entry.parent = s.head ∧
    entry.sourceCut = s.reviewCut ∧ s.fence ≤ entry.requestedFence

theorem rolled_back_projection_cannot_publish (different : s.reviewProjection ≠ s.reviewAnchor) :
    ¬ RegisteredCurrent s id entry actor epoch := fun accepted => different accepted.2.1

theorem old_registrar_cannot_publish (stale : epoch ≠ s.registrarEpoch) :
    ¬ RegisteredCurrent s id entry actor epoch := fun accepted => stale accepted.2.2.1.2

theorem historical_registration_is_not_current (stale : entry.parent ≠ s.head) :
    ¬ RegisteredCurrent s id entry actor epoch := fun accepted => stale accepted.2.2.2.1

theorem changed_review_source_cannot_publish (stale : entry.sourceCut ≠ s.reviewCut) :
    ¬ RegisteredCurrent s id entry actor epoch := fun accepted => stale accepted.2.2.2.2.1

theorem review_recovery_keeps_original_constraints [DecidableEq Key]
    (run : Run s t) (safe : Safe held calls s) (registered : s.reviewAnchor id = some entry) :
    t.reviewAnchor id = some entry ∧ PreservesIntents s t ∧ Extends s t ∧ Safe held calls t :=
  ⟨run_preserves_review_anchor run registered, run_preserves_original_intents run,
    run_preserves_original_decisions run, run_preserves_accounting safe run⟩

#print axioms review_recovery_keeps_original_constraints
#print axioms rolled_back_projection_cannot_publish
#print axioms old_registrar_cannot_publish

theorem recovery_and_provider_accounting_composition [DecidableEq Key]
    {id : Key} {decision : Decision}
    (h : Safe held calls s) (run : Run s t) (original : s.records id = some decision) :
    t.records id = some decision ∧ t.held = held ∧ t.calls = calls :=
  ⟨run_preserves_original_decisions run id decision original,
   (run_preserves_accounting h run).2.1, (run_preserves_accounting h run).2.2⟩

/- A source observation binds the frozen command, not the current policy head.
   Native refinement must authenticate InspectPublication and validate its full
   domain-separated digest. Missing/failed reads do not establish abort. -/
def ExactObservation (s : State Key) (id : Key) (payload parent fence : Nat) (d : Decision) : Prop :=
  s.records id = some d ∧ d.payload = payload ∧ d.parent = parent ∧ d.requestedFence = fence

theorem exact_observation_and_accounting_survive_recovery [DecidableEq Key]
    {id : Key} {d : Decision} {payload parent fence : Nat}
    (safe : Safe held calls s) (run : Run s t)
    (observed : ExactObservation s id payload parent fence d) :
    ExactObservation t id payload parent fence d ∧ t.held = held ∧ t.calls = calls := by
  have preserved := recovery_and_provider_accounting_composition safe run observed.1
  exact ⟨⟨preserved.1, observed.2⟩, preserved.2⟩
/-- A recoverable committed decision stays historical after head advancement.
It cannot certify the current head or release an existing unknown reservation. -/
theorem recovered_decision_cannot_replace_advanced_head [DecidableEq Key]
    {id : Key} {decision : Decision}
    (h : Safe held calls s) (run : Run s t) (original : s.records id = some decision)
    (historical : decision.resultHead ≤ s.head) (advanced : s.head < t.head) :
    t.records id = some decision ∧ decision.resultHead ≠ t.head ∧
      t.held = held ∧ t.calls = calls := by
  have preserved := recovery_and_provider_accounting_composition h run original
  exact ⟨preserved.1, by omega, preserved.2⟩

/- Owned-connection refinement: the worker has opened one private connection;
   every command is checked quiescent before/after SQL, storage faults terminate
   the owner, and a successful finish requires an explicitly successful close.
   The runtime must track the worker and observe its final result. -/
structure Owner where
  live : Bool := true
  closing : Bool := false
  busy : Bool := false
  slot : Bool := false
  transaction : Bool := false
  closed : Bool := false
  closeOk : Bool := false
  failed : Bool := false
  ack : Bool := false
  command : Nat := 0
  returned : Nat → Prop := fun _ => False
  decided : Nat → Prop := fun _ => False
  replies : Nat → Prop := fun _ => False

def MarkCommand (history : Nat → Prop) (id : Nat) : Nat → Prop := fun key => history key ∨ key = id

def OwnerSafe (o : Owner) : Prop := o.busy = o.slot ∧
  (o.transaction = true → o.busy = true ∧ o.live = true) ∧
  (o.closed = true → o.live = false) ∧ (o.failed = true → o.closing = true) ∧
  (o.ack = true → o.closing = true ∧ o.closed = true ∧ o.closeOk = true ∧ o.failed = false ∧ o.busy = false ∧ o.transaction = false) ∧
  (∀ id, o.replies id → o.returned id ∧ o.decided id)

inductive OwnerStep : Owner → Owner → Prop where
  | admit (o) (live : o.live = true) (openForWork : o.closing = false) (free : o.busy = false) :
      OwnerStep o {o with busy := true, slot := true, command := o.command + 1}
  | begin (o) (busy : o.busy = true) (live : o.live = true) (healthy : o.failed = false) :
      OwnerStep o {o with transaction := true}
  | quiescent (o) : OwnerStep o {o with transaction := false}
  | decideCommand (o) (busy : o.busy = true) (healthy : o.failed = false) :
      OwnerStep o {o with transaction := false, decided := MarkCommand o.decided o.command}
  | finishCommand (o) (idleTransaction : o.transaction = false) :
      OwnerStep o {o with busy := false, slot := false, returned := MarkCommand o.returned o.command}
  | commandReply (o) (id : Nat) (decided : o.decided id) (returned : o.returned id) :
      OwnerStep o {o with replies := MarkCommand o.replies id}
  | disconnect (o) : OwnerStep o o
  | requestClose (o) : OwnerStep o {o with closing := true}
  | storageFailure (o) (live : o.live = true) : OwnerStep o {o with failed := true, closing := true}
  | destroyFailedWork (o) (failed : o.failed = true) :
      OwnerStep o {o with busy := false, slot := false, transaction := false, returned := MarkCommand o.returned o.command}
  | closeGood (o) (closing : o.closing = true) (free : o.busy = false) (quiescent : o.transaction = false) :
      OwnerStep o {o with live := false, closed := true, closeOk := true}
  | closeError (o) (live : o.live = true) (closing : o.closing = true) (free : o.busy = false) (quiescent : o.transaction = false) :
      OwnerStep o {o with live := false, closed := true, closeOk := false, failed := true}
  | acknowledge (o) (closing : o.closing = true) (closed : o.closed = true) (closeOk : o.closeOk = true)
      (healthy : o.failed = false) (free : o.busy = false) (quiescent : o.transaction = false) :
      OwnerStep o {o with ack := true}

theorem owner_step_preserves_custody (h : OwnerSafe a) (step : OwnerStep a b) : OwnerSafe b := by
  cases step <;> simp_all [OwnerSafe, MarkCommand] <;> grind

theorem closed_owner_cannot_reopen (step : OwnerStep a b) (closed : a.live = false) : b.live = false := by
  cases step <;> simp_all

theorem successful_owner_ack_requires_close_and_no_failed_transaction (h : OwnerSafe o) (ack : o.ack = true) :
    o.closed = true ∧ o.closeOk = true ∧ o.failed = false ∧ o.busy = false ∧ o.transaction = false := by
  exact (h.2.2.2.2.1 ack).2

theorem command_ack_requires_returned_capacity (h : OwnerSafe o) {id : Nat} (ack : o.replies id) :
    o.returned id ∧ o.decided id := h.2.2.2.2.2 id ack

theorem owned_worker_and_publication_composition [DecidableEq Key]
    (logical : Safe held calls s) (publication : Step s t)
    (owned : OwnerSafe a) (owner : OwnerStep a b) : Safe held calls t ∧ OwnerSafe b :=
  ⟨step_preserves_accounting logical publication, owner_step_preserves_custody owned owner⟩

#print axioms owner_step_preserves_custody
#print axioms command_ack_requires_returned_capacity
#print axioms closed_owner_cannot_reopen
#print axioms successful_owner_ack_requires_close_and_no_failed_transaction
#print axioms owned_worker_and_publication_composition
#print axioms step_preserves_original_decisions
#print axioms step_preserves_accounting
#print axioms run_preserves_original_decisions
#print axioms run_preserves_accounting
#print axioms recovery_and_provider_accounting_composition
#print axioms exact_observation_and_accounting_survive_recovery
#print axioms recovered_decision_cannot_replace_advanced_head
/- Independent recovery envelope, owned here rather than another policy or
   account machine. Lists stand for ordered canonical records, not lengths.
   Authentication, collision-resistant encoding and independence of this state
   from restored projections remain runtime premises. DomainValid.assess is the
   existing publication/consumption/account/history owner's validation law;
   transportStopped supplies the separate exact-incarnation Host premise. -/
namespace CommitFloor

structure Cut where
  publication : List Nat := []
  consumption : List Nat := []
  account : List Nat := []
  history : List Nat := []
  deriving DecidableEq

def append (a b : Cut) : Cut :=
  ⟨a.publication ++ b.publication, a.consumption ++ b.consumption,
   a.account ++ b.account, a.history ++ b.history⟩

structure Command where
  identity : Nat
  canonicalBody : Nat
  originalScope : Nat
  epoch : Nat
  before : Cut
  delta : Cut
  deriving DecidableEq

structure Result where
  command : Command
  committed : Bool
  after : Cut
  deriving DecidableEq

structure Authority where
  originalScope : Nat
  epoch : Nat
  cut : Cut
  outcomes : Nat → Option Result := fun _ => none
  burned : Nat → Bool := fun _ => false
  held : Nat
  transportOwner : Nat := 1
  transportLive : Bool := true
  handoff : Bool := false
  quiesced : Bool := false

structure Image where
  cut : Cut
  epoch : Nat
  unresolved : List Nat := []

def Current (a : Authority) (i : Image) : Prop :=
  i.cut = a.cut ∧ i.epoch = a.epoch ∧ i.unresolved = []

structure DomainValid where
  assess : Cut → Command → Cut → Prop
  /-- Authentic evidence for the exact old process/egress incarnation. This is
  a Host premise, not Kubernetes lease expiry or a client-supplied assertion. -/
  transportStopped : Nat → Prop

def OwnerCurrent (a : Authority) (actor : Nat) (i : Image) : Prop :=
  Current a i ∧ actor = a.transportOwner ∧ a.transportLive = true ∧ a.handoff = false

def CanStartReplacement (a : Authority) : Prop :=
  a.transportLive = false ∧ a.quiesced = true ∧ a.handoff = true

inductive Transition (valid : DomainValid) : Authority → Authority → Prop where
  | commit (a q) (fresh : a.outcomes q.identity = none)
      (scope : q.originalScope = a.originalScope) (epoch : q.epoch = a.epoch)
      (parent : q.before = a.cut) (domain : valid.assess a.cut q (append a.cut q.delta)) :
      Transition valid a {a with
        cut := append a.cut q.delta
        outcomes := write a.outcomes q.identity ⟨q, true, append a.cut q.delta⟩}
  | reject (a q) (fresh : a.outcomes q.identity = none) :
      Transition valid a {a with outcomes := write a.outcomes q.identity ⟨q, false, a.cut⟩}
  | rotate (a) : Transition valid a {a with epoch := a.epoch + 1}
  | burnAtTransportOwner (a i actor key) (current : OwnerCurrent a actor i) (unspent : a.burned key = false)
      (consumed : key ∈ a.cut.consumption) :
      Transition valid a {a with burned := fun k => if k = key then true else a.burned k}
  | requestHandoff (a) : Transition valid a {a with handoff := true}
  | confirmStopped (a) (requested : a.handoff = true)
      (actualStop : valid.transportStopped a.transportOwner) :
      Transition valid a {a with transportLive := false, quiesced := true}
  | startReplacement (a) (eligible : CanStartReplacement a) :
      Transition valid a {a with
        transportOwner := a.transportOwner + 1
        epoch := a.epoch + 1
        transportLive := true
        quiesced := false
        handoff := false}
  | observeReplayOrRestoreProjection (a) : Transition valid a a

variable {id : Nat}

theorem outcome_is_immutable (step : Transition valid a b)
    (original : a.outcomes id = some result) : b.outcomes id = some result := by
  cases step <;> simp_all [write] <;> grind

theorem spent_is_monotone (step : Transition valid a b)
    (spent : a.burned key = true) : b.burned key = true := by
  cases step <;> simp_all <;> split <;> simp_all

theorem scope_and_unknown_hold_are_preserved (step : Transition valid a b) :
    b.originalScope = a.originalScope ∧ b.held = a.held := by
  cases step <;> simp

def Prefix (a b : Cut) : Prop := ∃ tail, b = append a tail

theorem step_keeps_all_four_prefixes (step : Transition valid a b) : Prefix a.cut b.cut := by
  cases step with
  | commit q => exact ⟨q.delta, rfl⟩
  | _ => exact ⟨{}, by simp [append]⟩

theorem prefix_transitive (ab : Prefix a b) (bc : Prefix b c) : Prefix a c := by
  obtain ⟨d, rfl⟩ := ab
  obtain ⟨e, rfl⟩ := bc
  exact ⟨append d e, by simp [append, List.append_assoc]⟩

inductive Trace (valid : DomainValid) : Authority → Authority → Prop where
  | refl (a) : Trace valid a a
  | next : Trace valid a b → Transition valid b c → Trace valid a c

theorem recovery_keeps_all_four_prefixes (trace : Trace valid a b) : Prefix a.cut b.cut := by
  induction trace with
  | refl => exact ⟨{}, by simp [append]⟩
  | next history step ih => exact prefix_transitive ih (step_keeps_all_four_prefixes step)

theorem recovery_keeps_outcome_and_spent (trace : Trace valid a b)
    (original : a.outcomes id = some result) (spent : a.burned key = true) :
    b.outcomes id = some result ∧ b.burned key = true ∧
      b.originalScope = a.originalScope ∧ b.held = a.held := by
  induction trace with
  | refl => exact ⟨original, spent, rfl, rfl⟩
  | next history step ih =>
    obtain ⟨outcome, burn, scope, hold⟩ := ih
    obtain ⟨sameScope, sameHold⟩ := scope_and_unknown_hold_are_preserved step
    exact ⟨outcome_is_immutable step outcome, spent_is_monotone step burn,
      sameScope.trans scope, sameHold.trans hold⟩

theorem stale_cut_or_epoch_cannot_activate
    (stale : i.cut ≠ a.cut ∨ i.epoch ≠ a.epoch ∨ i.unresolved ≠ []) : ¬ Current a i := by
  intro current
  rcases stale with h | h | h
  · exact h current.1
  · exact h current.2.1
  · exact h current.2.2

theorem equal_lengths_do_not_certify_current (body : i.cut ≠ a.cut) : ¬ Current a i := by
  exact fun h => body h.1

theorem rotation_invalidates_old_image (current : Current a i) :
    ¬ Current {a with epoch := a.epoch + 1} i := by
  simp only [Current] at *
  omega

theorem new_identity_cannot_remove_prior_burn (trace : Trace valid a b)
    (spent : a.burned key = true) : ¬ b.burned key = false := by
  have kept : b.burned key = true := by
    induction trace with
    | refl => exact spent
    | next history step ih => exact spent_is_monotone step ih
  simp_all

theorem exact_replay_binds_original_scope_and_body
    (observed : a.outcomes q.identity = some result)
    (exactCommand : result.command = q) (trace : Trace valid a b) :
    b.outcomes q.identity = some result ∧ result.command.originalScope = q.originalScope ∧
      result.command.canonicalBody = q.canonicalBody := by
  have kept : b.outcomes q.identity = some result := by
    induction trace with
    | refl => exact observed
    | next history step ih => exact outcome_is_immutable step ih
  exact ⟨kept, congrArg Command.originalScope exactCommand,
    congrArg Command.canonicalBody exactCommand⟩

theorem lease_or_epoch_change_does_not_stop_transport {a : Authority}
    (stillLive : a.transportLive = true) :
    ¬ CanStartReplacement {a with epoch := a.epoch + 1} := by
  simp_all [CanStartReplacement]

theorem requested_handoff_blocks_new_admission (requested : a.handoff = true) :
    ¬ OwnerCurrent a actor i := by
  simp_all [OwnerCurrent]

theorem wrong_incarnation_cannot_admit (wrong : actor ≠ a.transportOwner) :
    ¬ OwnerCurrent a actor i := fun h => wrong h.2.1

theorem step_preserves_verified_quiescence
    (known : a.quiesced = true → valid.transportStopped a.transportOwner)
    (step : Transition valid a b) :
    b.quiesced = true → valid.transportStopped b.transportOwner := by
  cases step <;> simp_all

theorem trace_preserves_verified_quiescence
    (known : a.quiesced = true → valid.transportStopped a.transportOwner)
    (trace : Trace valid a b) :
    b.quiesced = true → valid.transportStopped b.transportOwner := by
  induction trace with
  | refl => exact known
  | next history step ih => exact step_preserves_verified_quiescence ih step

theorem reachable_replacement_requires_verified_stop
    (initiallyUnproven : a.quiesced = false) (trace : Trace valid a b)
    (eligible : CanStartReplacement b) : valid.transportStopped b.transportOwner := by
  have base : a.quiesced = true → valid.transportStopped a.transportOwner := by
    simp [initiallyUnproven]
  exact trace_preserves_verified_quiescence base trace eligible.2.1

theorem replacement_invalidates_old_owner (current : OwnerCurrent a actor i) :
    ¬ OwnerCurrent {a with
      transportOwner := a.transportOwner + 1
      epoch := a.epoch + 1} actor i := by
  intro nextOwner
  have oldIdentity := current.2.1
  have newIdentity := nextOwner.2.1
  simp only at newIdentity
  omega

/-- The composition does not turn a current image into a transferable permit.
Native refinement must establish the final guard at the actual socket owner. -/
theorem floor_recovery_and_transport_composition (trace : Trace valid a b)
    (original : a.outcomes id = some result) (spent : a.burned key = true)
    (actualOwner : OwnerCurrent b actor image) :
    Prefix a.cut b.cut ∧ b.outcomes id = some result ∧ b.burned key = true ∧
      b.originalScope = a.originalScope ∧ b.held = a.held ∧
      image.cut = b.cut ∧ image.epoch = b.epoch ∧ actor = b.transportOwner := by
  obtain ⟨outcome, burn, scope, hold⟩ := recovery_keeps_outcome_and_spent trace original spent
  exact ⟨recovery_keeps_all_four_prefixes trace, outcome, burn, scope, hold,
    actualOwner.1.1, actualOwner.1.2.1, actualOwner.2.1⟩

#print axioms outcome_is_immutable
#print axioms recovery_keeps_all_four_prefixes
#print axioms recovery_keeps_outcome_and_spent
#print axioms stale_cut_or_epoch_cannot_activate
#print axioms equal_lengths_do_not_certify_current
#print axioms rotation_invalidates_old_image
#print axioms new_identity_cannot_remove_prior_burn
#print axioms exact_replay_binds_original_scope_and_body
#print axioms lease_or_epoch_change_does_not_stop_transport
#print axioms requested_handoff_blocks_new_admission
#print axioms wrong_incarnation_cannot_admit
#print axioms reachable_replacement_requires_verified_stop
#print axioms replacement_invalidates_old_owner
#print axioms floor_recovery_and_transport_composition
end CommitFloor
/-- Any omitted request can gain permission while every sampled decision remains
unchanged. This is a finite-observation counterexample, not a second Cedar model.
The native schema-bound replay receipt must therefore never supply no-gain. -/
theorem finite_replay_does_not_certify_no_gain (samples : List Nat) (outside : Nat)
    (unseen : outside ∉ samples) :
    ∃ before after : Nat → Bool,
      (∀ key ∈ samples, before key = after key) ∧
      before outside = false ∧ after outside = true := by
  refine ⟨fun _ => false, fun key => decide (key = outside), ?_, rfl, by simp⟩
  intro key sampled
  have different : key ≠ outside := by
    intro same
    subst key
    exact unseen sampled
  simp [different]

#print axioms finite_replay_does_not_certify_no_gain
end Weaver.PublicationRecovery
