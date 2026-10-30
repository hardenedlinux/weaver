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

structure State (Key : Type) where
  head : Nat := 0
  fence : Nat := 1
  records : Key → Option Decision := fun _ => none
  commits : List Key := []
  held : Nat := 4
  calls : Nat := 1

variable {Key : Type}

def write [DecidableEq Key] (records : Key → Option Decision) (id : Key) (d : Decision) :=
  fun key => if key = id then some d else records key

def Extends (s t : State Key) : Prop := ∀ id d, s.records id = some d → t.records id = some d
def Safe (held calls : Nat) (s : State Key) : Prop := s.head = s.commits.length ∧ s.held = held ∧ s.calls = calls

inductive Step [DecidableEq Key] : State Key → State Key → Prop where
  | commit (s : State Key) (id : Key) (payload fence : Nat) (fresh : s.records id = none) (monotone : s.fence ≤ fence) :
      Step s {s with head := s.head+1, fence := fence, commits := s.commits ++ [id], records := write s.records id ⟨payload,s.head,fence,true,s.head+1,fence⟩}
  | reject (s : State Key) (id : Key) (payload parent fence : Nat) (fresh : s.records id = none)
      (conflict : parent ≠ s.head ∨ fence < s.fence) :
      Step s {s with records := write s.records id ⟨payload,parent,fence,false,s.head,s.fence⟩}
  | replayOrObservationOrRestart (s) : Step s s

variable {s t : State Key}
variable {held calls : Nat}

theorem step_preserves_original_decisions [DecidableEq Key] (step : Step s t) : Extends s t := by
  intro key d existing
  cases step with
  | commit id payload fence fresh monotone =>
    by_cases same : key = id
    · subst key; rw [fresh] at existing; contradiction
    · simpa [write, same] using existing
  | reject id payload parent fence fresh conflict =>
    by_cases same : key = id
    · subst key; rw [fresh] at existing; contradiction
    · simpa [write, same] using existing
  | replayOrObservationOrRestart => exact existing

theorem step_preserves_accounting [DecidableEq Key] (h : Safe held calls s) (step : Step s t) : Safe held calls t := by
  cases step <;> simp_all [Safe]

inductive Run [DecidableEq Key] : State Key → State Key → Prop where
  | refl (s : State Key) : Run s s
  | next {a b c : State Key} : Run a b → Step b c → Run a c

theorem run_preserves_original_decisions [DecidableEq Key] (run : Run s t) : Extends s t := by
  induction run with
  | refl => intro id d existing; exact existing
  | next history step ih =>
    intro id d existing
    exact step_preserves_original_decisions step id d (ih id d existing)

theorem run_preserves_accounting [DecidableEq Key] (h : Safe held calls s) (run : Run s t) : Safe held calls t := by
  induction run with
  | refl => exact h
  | next history step ih => exact step_preserves_accounting ih step

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
end Weaver.PublicationRecovery
