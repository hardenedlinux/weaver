import LlmWalActivation
namespace Weaver.LlmCheckpointTruncation
structure Checkpoint where
  id : Nat
  parent : Nat
  position : Nat
  image : Weaver.LlmAccountCommit.Image
  covered : List Weaver.LlmAccountCommit.Record
  epoch : Nat
  sourceGeneration : Nat
structure Receipt where
  checkpoint : Option Checkpoint
  generation : Nat
  epoch : Nat
  sourceGeneration : Nat
structure State where
  logical : Weaver.LlmWalActivation.State
  published : List Checkpoint := []
  blobs : List Checkpoint := []
  localCheckpoint : Option Checkpoint := none
  suffix : List Weaver.LlmAccountCommit.Record := []
  observed : Option Receipt := none
structure Owner where
  blobDurable : Checkpoint → Prop
  publicationDurable : Checkpoint → Prop
  prefixAuthentic : State → Prop
  policy : Checkpoint → State → Prop

def latest : List Checkpoint → Option Checkpoint
  | [] => none
  | c::tail => match latest tail with | none => some c | some d => some d

def tip (genesis : Weaver.LlmAccountCommit.Image) : List Weaver.LlmAccountCommit.Record → Weaver.LlmAccountCommit.Image
  | [] => genesis
  | r::tail => tip r.after tail

def expanded (c : Option Checkpoint) (suffix : List Weaver.LlmAccountCommit.Record) :=
  (match c with | none => [] | some cp => cp.covered) ++ suffix

def floor (s : State) : Nat := match latest s.published with | none => 0 | some cp => cp.position

def current (s : State) : Receipt := ⟨latest s.published,s.published.length,s.logical.core.epoch,s.logical.core.sourceGeneration⟩
def Confirmed (s : State) : Prop := s.observed = some (current s)
def Valid (genesis : Weaver.LlmAccountCommit.Image) (s : State) (cp : Checkpoint) : Prop :=
  cp.covered.length = cp.position ∧ cp.image = tip genesis cp.covered ∧
  ∃ tail, s.logical.core.journal = cp.covered ++ tail

def Physical (s : State) : Prop := expanded s.localCheckpoint s.suffix = s.logical.wal ∧ s.localCheckpoint = latest s.published

def Safe (genesis : Weaver.LlmAccountCommit.Image) (s : State) : Prop :=
  (∀ cp ∈ s.published, Valid genesis s cp) ∧
  (s.logical.active = true → Physical s ∧ Confirmed s)

def initial (ao : Weaver.LlmAccountCommit.Owner) (balances : Nat → Weaver.LlmAccountCommit.Balance) : State :=
  let base := Weaver.LlmWalActivation.initial ao balances
  ⟨base,[],[],none,[],some ⟨none,0,0,0⟩⟩

inductive Step (ao : Weaver.LlmAccountCommit.Owner) (wo : Weaver.LlmWalActivation.Owner)
    (o : Owner) (genesis : Weaver.LlmAccountCommit.Image) : State → State → Prop where
  | advance (s next tail) (actual : Weaver.LlmWalActivation.Step ao wo s.logical next)
      (noActivation : next.active = true → s.logical.active = true)
      (represented : expanded s.localCheckpoint tail = next.wal) :
      Step ao wo o genesis s {s with logical := next, suffix := tail}
  | persist (s cp) (valid : Valid genesis s cp) (durable : o.blobDurable cp) (walAuthentic : wo.prefixAuthentic s.logical) :
      Step ao wo o genesis s {s with blobs := s.blobs ++ [cp], logical := {s.logical with receipt := some (Weaver.LlmWalActivation.current s.logical)}}
  | publish (s cp worker) (blob : cp ∈ s.blobs) (valid : Valid genesis s cp)
      (parent : cp.parent = s.published.length) (fresh : ∀ prior ∈ s.published, prior.id ≠ cp.id)
      (progress : floor s < cp.position) (owner : worker = s.logical.core.epoch)
      (stamp : cp.epoch = worker ∧ cp.sourceGeneration = s.logical.core.sourceGeneration)
      (policy : o.policy cp s) (durable : o.publicationDurable cp) :
      Step ao wo o genesis s {s with published := s.published ++ [cp], logical := {s.logical with receipt := none, active := false}}
  | loseBlob (s id) : Step ao wo o genesis s {s with blobs := s.blobs.filter (fun cp => cp.id != id), logical := {s.logical with receipt := none, active := false}}
  | observe (s) (authentic : o.prefixAuthentic s) (walAuthentic : wo.prefixAuthentic s.logical) : Step ao wo o genesis s {s with observed := some (current s), logical := {s.logical with receipt := some (Weaver.LlmWalActivation.current s.logical)}}
  | truncate (s cp tail worker) (selected : latest s.published = some cp) (confirmed : Confirmed s)
      (owner : worker = s.logical.core.epoch) (blob : cp ∈ s.blobs) (durable : o.blobDurable cp)
      (coverage : s.logical.wal = cp.covered ++ tail) (authentic : o.prefixAuthentic s) :
      Step ao wo o genesis s {s with localCheckpoint := some cp, suffix := tail, logical := {s.logical with receipt := none, active := false}}
  | restore (s cp tail) : Step ao wo o genesis s {s with localCheckpoint := cp, suffix := tail, logical := {s.logical with wal := expanded cp tail, active := false}}
  | repair (s cp tail) (selected : cp = latest s.published) (blob : ∀ c, cp = some c → c ∈ s.blobs ∧ o.blobDurable c)
      (coverage : expanded cp tail = s.logical.core.journal) (authentic : o.prefixAuthentic s)
      (walAuthentic : wo.prefixAuthentic s.logical) :
      Step ao wo o genesis s {s with localCheckpoint := cp, suffix := tail, logical := {s.logical with wal := s.logical.core.journal, active := false}}
  | activate (s next worker) (actual : Weaver.LlmWalActivation.Step ao wo s.logical next)
      (live : next.active = true) (wal : next.wal = s.logical.wal)
      (physical : Physical s) (confirmed : Confirmed s) (owner : worker = s.logical.core.epoch) :
      Step ao wo o genesis s {s with logical := next}
  | loseReply (s) : Step ao wo o genesis s {s with observed := none, logical := {s.logical with receipt := none, active := false}}

inductive Run (ao : Weaver.LlmAccountCommit.Owner) (wo : Weaver.LlmWalActivation.Owner)
    (o : Owner) (genesis : Weaver.LlmAccountCommit.Image) : State → State → Prop where
  | refl (s) : Run ao wo o genesis s s
  | next : Run ao wo o genesis a b → Step ao wo o genesis b d → Run ao wo o genesis a d

theorem latest_append (xs : List Checkpoint) (cp) : latest (xs ++ [cp]) = some cp := by
  induction xs with
  | nil => rfl
  | cons c tail ih => simp [latest,ih]

theorem valid_after_wal_step (valid : Valid genesis s cp)
    (event : Weaver.LlmWalActivation.Step ao wo s.logical next) :
    Valid genesis {s with logical := next} cp := by
  obtain ⟨length,image,tail,original⟩ := valid
  obtain ⟨added,append⟩ := Weaver.LlmWalActivation.committed_prefix_retained event
  exact ⟨length,image,tail ++ added,by rw [append,original,List.append_assoc]⟩

theorem active_stamps (event : Weaver.LlmWalActivation.Step ao wo s t) (active : t.active = true) :
    t.core.epoch = s.core.epoch ∧ t.core.sourceGeneration = s.core.sourceGeneration := by
  cases event <;> simp_all

theorem logical_projection (event : Step ao wo o genesis s t) : Weaver.LlmWalActivation.Run ao wo s.logical t.logical := by
  cases event with
  | advance next tail actual noActivation represented => exact .next (.refl _) actual
  | persist cp valid durable walAuthentic => exact .next (.refl _) (.observe _ walAuthentic)
  | observe authentic walAuthentic => exact .next (.refl _) (.observe _ walAuthentic)
  | publish cp worker blob valid parent fresh progress owner stamp policy durable => exact .next (.refl _) (.loseReply _)
  | truncate cp tail worker selected confirmed owner blob durable coverage authentic => exact .next (.refl _) (.loseReply _)
  | restore cp tail => exact .next (.refl _) (.restoreWal _ _)
  | repair cp tail selected blob coverage authentic walAuthentic => exact .next (.refl _) (.repairWal _ walAuthentic)
  | activate next worker actual live wal physical confirmed owner => exact .next (.refl _) actual
  | loseBlob id => exact .next (.refl _) (.loseReply _)
  | loseReply => exact .next (.refl _) (.loseReply _)

theorem safe_step (safe : Safe genesis s) (event : Step ao wo o genesis s t) : Safe genesis t := by
  rcases safe with ⟨published,live⟩
  cases event with
  | advance next tail actual noActivation represented =>
    refine ⟨?_,?_⟩
    · intro cp stored; exact valid_after_wal_step (published cp stored) actual
    · intro active
      have old := live (noActivation active)
      have stamps := active_stamps actual active
      refine ⟨⟨represented,old.1.2⟩,?_⟩
      simpa [Confirmed,current,stamps.1,stamps.2] using old.2
  | persist cp valid durable walAuthentic => exact ⟨published,live⟩
  | publish cp worker blob valid parent fresh progress owner stamp policy durable =>
    refine ⟨?_,by simp⟩
    intro old member; rcases List.mem_append.mp member with prior|last
    · exact published old prior
    · have same : old = cp := by simpa using last
      subst old; exact valid
  | loseBlob id => exact ⟨published,by simp⟩
  | observe authentic walAuthentic =>
    exact ⟨published,by intro active; exact ⟨(live active).1,rfl⟩⟩
  | truncate cp tail worker selected confirmed owner blob durable coverage authentic => exact ⟨published,by simp⟩
  | restore cp tail => exact ⟨published,by simp⟩
  | repair cp tail selected blob coverage authentic walAuthentic => exact ⟨published,by simp⟩
  | activate next worker actual active wal physical confirmed owner =>
    have stamps := active_stamps actual active
    refine ⟨?_,?_⟩
    · intro cp stored; exact valid_after_wal_step (published cp stored) actual
    · intro _; exact ⟨⟨physical.1.trans wal.symm,physical.2⟩,by simpa [Confirmed,current,stamps.1,stamps.2] using confirmed⟩
  | loseReply => exact ⟨published,by simp⟩

theorem initialized_safe (run : Run ao wo o (Weaver.LlmAccountCommit.initial ao balances).authority (initial ao balances) s) :
    Safe (Weaver.LlmAccountCommit.initial ao balances).authority s := by
  induction run with
  | refl => exact ⟨by simp [initial],by intro _; exact ⟨⟨rfl,rfl⟩,rfl⟩⟩
  | next prior event ih => exact safe_step ih event

theorem wal_extend (suffixRun : Weaver.LlmWalActivation.Run ao wo a b) (prefixRun : Weaver.LlmWalActivation.Run ao wo x a) :
    Weaver.LlmWalActivation.Run ao wo x b := by
  induction suffixRun with
  | refl => exact prefixRun
  | next prior event ih => exact .next ih event

theorem actual_wal_composition (run : Run ao wo o genesis s t)
    (prefixRun : Weaver.LlmWalActivation.Run ao wo (Weaver.LlmWalActivation.initial ao balances) s.logical) :
    Weaver.LlmWalActivation.Run ao wo (Weaver.LlmWalActivation.initial ao balances) t.logical := by
  induction run with
  | refl => exact prefixRun
  | next prior event ih => exact wal_extend (logical_projection event) ih

theorem publication_floor_monotone (event : Step ao wo o genesis s t) : floor s ≤ floor t := by
  cases event with
  | publish cp worker blob valid parent fresh progress owner stamp policy durable =>
    simp only [floor,latest_append]; change floor s ≤ cp.position; omega
  | _ => exact Nat.le_refl _

theorem published_checkpoint_retained (event : Step ao wo o genesis s t) (stored : cp ∈ s.published) : cp ∈ t.published := by
  cases event with
  | publish cp worker blob valid parent fresh progress owner stamp policy durable => exact List.mem_append_left _ stored
  | _ => exact stored

theorem active_requires_current_checkpoint (run : Run ao wo o (Weaver.LlmAccountCommit.initial ao balances).authority (initial ao balances) s)
    (active : s.logical.active = true) : s.localCheckpoint = latest s.published ∧ Confirmed s := by
  have h := (initialized_safe run).2 active
  exact ⟨h.1.2,h.2⟩

theorem truncate_preserves_logical_account (s : State) (cp tail) :
    ({s with localCheckpoint := some cp, suffix := tail, logical := {s.logical with receipt := none, active := false}} : State).logical.core.authority = s.logical.core.authority := rfl

theorem published_image_is_complete (run : Run ao wo o (Weaver.LlmAccountCommit.initial ao balances).authority (initial ao balances) s)
    (stored : cp ∈ s.published) : cp.image = tip (Weaver.LlmAccountCommit.initial ao balances).authority cp.covered :=
  ((initialized_safe run).1 cp stored).2.1

theorem old_parent_cannot_publish (s : State) (cp : Checkpoint) (old : cp.parent ≠ s.published.length) : ¬ cp.parent = s.published.length := old

theorem original_reservation_once (run : Run ao wo o genesis (initial ao balances) s) (key) :
    s.logical.core.authority.writes key ≤ 1 :=
  Weaver.LlmWalActivation.original_reservation_once (actual_wal_composition run (.refl _)) key

theorem unknown_original_hold_retained (run : Run ao wo o genesis (initial ao balances) s)
    (source : Weaver.LlmExecutionReconciliation.State S) (unknownUsage : source.metered = false)
    (binding : ∀ tx state, tx.reservation = originalKey → ao.sourceReady tx state → Weaver.LlmAccountCommit.OriginalReady originalKey attempt source tx) :
    s.logical.core.authority.reservations originalKey = none ∧ s.logical.core.authority.holds originalKey = ao.bound originalKey :=
  Weaver.LlmWalActivation.unknown_budget_hold_retained (actual_wal_composition run (.refl _)) source unknownUsage binding
theorem new_publication_requires_complete_body (event : Step ao wo o genesis s t)
    (changed : t.published.length ≠ s.published.length) :
    ∃ cp, cp ∈ s.blobs ∧ Valid genesis s cp ∧ cp.parent = s.published.length ∧ floor s < cp.position ∧ o.publicationDurable cp := by
  cases event with
  | publish cp worker blob valid parent fresh progress owner stamp policy durable => exact ⟨cp,blob,valid,parent,progress,durable⟩
  | _ => exact False.elim (changed rfl)

theorem truncation_preserves_replay (s : State) (cp : Checkpoint) (tail)
    (coverage : s.logical.wal = cp.covered ++ tail) (position : cp.covered.length = cp.position) :
    expanded (some cp) tail = s.logical.wal ∧ tail.length + cp.position = s.logical.wal.length := by
  refine ⟨coverage.symm,?_⟩
  rw [coverage,List.length_append,position]; omega

theorem publication_has_no_financial_effect (event : Step ao wo o genesis s t)
    (changed : t.published.length ≠ s.published.length) :
    t.logical.core.authority = s.logical.core.authority ∧ t.logical.active = false := by
  cases event with
  | publish cp worker blob valid parent fresh progress owner stamp policy durable => exact ⟨rfl,rfl⟩
  | _ => exact False.elim (changed rfl)

theorem old_checkpoint_snapshot_stays_closed (run : Run ao wo o (Weaver.LlmAccountCommit.initial ao balances).authority (initial ao balances) s)
    (old : s.localCheckpoint ≠ latest s.published) : s.logical.active = false := by
  cases active : s.logical.active with
  | false => rfl
  | true => exact False.elim (old (active_requires_current_checkpoint run active).1)

theorem checkpoint_ids_unique (run : Run ao wo o genesis (initial ao balances) s) :
    ∀ cp ∈ s.published, ∀ other ∈ s.published, cp.id = other.id → cp = other := by
  induction run with
  | refl => simp [initial]
  | next prior event ih =>
    cases event with
    | publish added worker blob valid parent fresh progress owner stamp policy durable =>
      intro cp member other stored same
      rcases List.mem_append.mp member with old|new
      · rcases List.mem_append.mp stored with oldOther|newOther
        · exact ih cp old other oldOther same
        · have eq : other = added := by simpa using newOther
          subst other; exact False.elim (fresh cp old same)
      · have eq : cp = added := by simpa using new
        subst cp
        rcases List.mem_append.mp stored with oldOther|newOther
        · exact False.elim (fresh other oldOther same.symm)
        · have eq : other = added := by simpa using newOther
          exact eq.symm
    | _ => exact ih

end Weaver.LlmCheckpointTruncation
#print axioms Weaver.LlmCheckpointTruncation.logical_projection
#print axioms Weaver.LlmCheckpointTruncation.initialized_safe
#print axioms Weaver.LlmCheckpointTruncation.actual_wal_composition
#print axioms Weaver.LlmCheckpointTruncation.publication_floor_monotone
#print axioms Weaver.LlmCheckpointTruncation.published_checkpoint_retained
#print axioms Weaver.LlmCheckpointTruncation.active_requires_current_checkpoint
#print axioms Weaver.LlmCheckpointTruncation.truncate_preserves_logical_account
#print axioms Weaver.LlmCheckpointTruncation.published_image_is_complete
#print axioms Weaver.LlmCheckpointTruncation.old_parent_cannot_publish
#print axioms Weaver.LlmCheckpointTruncation.original_reservation_once
#print axioms Weaver.LlmCheckpointTruncation.unknown_original_hold_retained
#print axioms Weaver.LlmCheckpointTruncation.new_publication_requires_complete_body
#print axioms Weaver.LlmCheckpointTruncation.truncation_preserves_replay
#print axioms Weaver.LlmCheckpointTruncation.publication_has_no_financial_effect
#print axioms Weaver.LlmCheckpointTruncation.old_checkpoint_snapshot_stays_closed
#print axioms Weaver.LlmCheckpointTruncation.checkpoint_ids_unique
