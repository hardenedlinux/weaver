import LlmCheckpointTruncation
namespace Weaver.LlmManifestSwitch
-- Typed immutable objects; native byte identity and durable IO are Owner premises.
structure Segment where
  id : Nat
  records : List Weaver.LlmAccountCommit.Record
structure Manifest where
  id : Nat
  parent : Nat
  checkpoint : Option Weaver.LlmCheckpointTruncation.Checkpoint
  segments : List Segment
structure Receipt where
  manifest : Nat
  generation : Nat
  worker : Nat
structure State where
  logical : Weaver.LlmCheckpointTruncation.State
  root : Manifest
  generation : Nat
  objects : List Segment
  manifests : List Manifest
  allocated : List Segment
  observed : Option Receipt
structure Owner where
  segmentDurable : Segment → Prop
  manifestDurable : Manifest → Prop
  switchDurable : Manifest → Nat → Prop
  rootAuthentic : State → Prop
  policy : State → Manifest → Prop

def frames (m : Manifest) := m.segments.flatMap Segment.records
def replay (m : Manifest) := Weaver.LlmCheckpointTruncation.expanded m.checkpoint (frames m)
def current (s : State) : Receipt := ⟨s.root.id,s.generation,s.logical.logical.core.epoch⟩
def Confirmed (s : State) := s.observed = some (current s)
def Available (o : Owner) (s : State) (m : Manifest) : Prop :=
  m ∈ s.manifests ∧ o.manifestDurable m ∧
  (∀ seg ∈ m.segments, seg ∈ s.objects ∧ o.segmentDurable seg) ∧
  (∀ cp, m.checkpoint = some cp → cp ∈ s.logical.blobs)
def Safe (o : Owner) (s : State) : Prop :=
  Available o s s.root ∧ replay s.root = s.logical.logical.wal ∧
  s.root.checkpoint = s.logical.localCheckpoint ∧ frames s.root = s.logical.suffix

inductive Step (ao : Weaver.LlmAccountCommit.Owner) (wo : Weaver.LlmWalActivation.Owner)
    (co : Weaver.LlmCheckpointTruncation.Owner) (o : Owner) (genesis : Weaver.LlmAccountCommit.Image) : State → State → Prop where
  | segment (s seg) (fresh : ∀ old ∈ s.allocated, old.id ≠ seg.id) (durable : o.segmentDurable seg) :
      Step ao wo co o genesis s {s with objects := s.objects ++ [seg], allocated := s.allocated ++ [seg]}
  | manifest (s m) (fresh : ∀ old ∈ s.manifests, old.id ≠ m.id) (durable : o.manifestDurable m) :
      Step ao wo co o genesis s {s with manifests := s.manifests ++ [m]}
  | switchRoot (s m cp worker expectedGeneration) (selected : m.checkpoint = some cp)
      (parent : m.parent = s.root.id) (cas : expectedGeneration = s.generation) (available : Available o s m)
      (publication : Weaver.LlmCheckpointTruncation.latest s.logical.published = some cp)
      (confirmed : Weaver.LlmCheckpointTruncation.Confirmed s.logical)
      (checkpointDurable : co.blobDurable cp) (authentic : co.prefixAuthentic s.logical)
      (actual : Weaver.LlmCheckpointTruncation.Step ao wo co genesis s.logical
        {s.logical with localCheckpoint := some cp, suffix := frames m, logical := {s.logical.logical with receipt := none, active := false}})
      (coverage : replay m = s.logical.logical.wal) (owner : worker = s.logical.logical.core.epoch)
      (policy : o.policy s m) (durable : o.switchDurable m (s.generation + 1)) :
      Step ao wo co o genesis s {s with logical := {s.logical with localCheckpoint := some cp, suffix := frames m, logical := {s.logical.logical with receipt := none, active := false}}, root := m, generation := s.generation + 1, observed := none}
  | observe (s worker) (authentic : o.rootAuthentic s) (available : Available o s s.root)
      (owner : worker = s.logical.logical.core.epoch) :
      Step ao wo co o genesis s {s with observed := some (current s)}
  | erase (s id worker generation) (confirmed : Confirmed s)
      (owner : worker = s.logical.logical.core.epoch) (cas : generation = s.generation)
      (unreferenced : ∀ seg ∈ s.root.segments, seg.id ≠ id) :
      Step ao wo co o genesis s {s with objects := s.objects.filter (fun seg => seg.id != id)}
  | crash (s) : Step ao wo co o genesis s {s with observed := none, logical := {s.logical with observed := none, logical := {s.logical.logical with receipt := none, active := false}}}
  | authority (s next) (actual : Weaver.LlmCheckpointTruncation.Step ao wo co genesis s.logical next)
      (wal : next.logical.wal = s.logical.logical.wal) (checkpoint : next.localCheckpoint = s.logical.localCheckpoint)
      (suffix : next.suffix = s.logical.suffix) (blobs : next.blobs = s.logical.blobs)
      (noActivation : next.logical.active = true → s.logical.logical.active = true) :
      Step ao wo co o genesis s {s with logical := next}
  | activate (s next worker) (actual : Weaver.LlmCheckpointTruncation.Step ao wo co genesis s.logical next)
      (wal : next.logical.wal = s.logical.logical.wal) (checkpoint : next.localCheckpoint = s.logical.localCheckpoint)
      (suffix : next.suffix = s.logical.suffix) (blobs : next.blobs = s.logical.blobs)
      (confirmed : Confirmed s) (owner : worker = s.logical.logical.core.epoch) :
      Step ao wo co o genesis s {s with logical := next}

inductive Run (ao : Weaver.LlmAccountCommit.Owner) (wo : Weaver.LlmWalActivation.Owner)
    (co : Weaver.LlmCheckpointTruncation.Owner) (o : Owner) (genesis : Weaver.LlmAccountCommit.Image) : State → State → Prop where
  | refl (s) : Run ao wo co o genesis s s
  | next : Run ao wo co o genesis a b → Step ao wo co o genesis b d → Run ao wo co o genesis a d

theorem available_stable (a : Available o s m) (objects : s.objects = t.objects)
    (manifests : s.manifests = t.manifests) (blobs : s.logical.blobs = t.logical.blobs) : Available o t m := by
  simpa only [Available,←objects,←manifests,←blobs] using a

theorem safe_step (safe : Safe o s) (event : Step ao wo co o genesis s t) : Safe o t := by
  obtain ⟨av,replayEq,checkpointEq,suffixEq⟩ := safe
  cases event with
  | segment seg fresh durable =>
    refine ⟨⟨av.1,av.2.1,?_,av.2.2.2⟩,replayEq,checkpointEq,suffixEq⟩
    intro x member; exact ⟨List.mem_append_left _ (av.2.2.1 x member).1,(av.2.2.1 x member).2⟩
  | manifest m fresh durable => exact ⟨⟨List.mem_append_left _ av.1,av.2⟩,replayEq,checkpointEq,suffixEq⟩
  | switchRoot m cp worker expectedGeneration selected parent cas available publication confirmed checkpointDurable authentic actual coverage owner policy durable =>
    exact ⟨available,coverage,selected,rfl⟩
  | observe worker authentic available owner => exact ⟨av,replayEq,checkpointEq,suffixEq⟩
  | erase id worker generation confirmed owner cas unreferenced =>
    refine ⟨⟨av.1,av.2.1,?_,av.2.2.2⟩,replayEq,checkpointEq,suffixEq⟩
    intro x member
    refine ⟨List.mem_filter.mpr ⟨(av.2.2.1 x member).1,?_⟩,(av.2.2.1 x member).2⟩
    simp [unreferenced x member]
  | crash => exact ⟨av,replayEq,checkpointEq,suffixEq⟩
  | authority next actual wal checkpoint suffix blobs noActivation =>
    exact ⟨available_stable av rfl rfl blobs.symm,replayEq.trans wal.symm,checkpointEq.trans checkpoint.symm,suffixEq.trans suffix.symm⟩
  | activate next worker actual wal checkpoint suffix blobs confirmed owner =>
    exact ⟨available_stable av rfl rfl blobs.symm,replayEq.trans wal.symm,checkpointEq.trans checkpoint.symm,suffixEq.trans suffix.symm⟩

theorem recovery_copy_retained (safe : Safe o s) (run : Run ao wo co o genesis s t) : Safe o t := by
  induction run with
  | refl => exact safe
  | next prior event ih => exact safe_step ih event

theorem logical_projection (event : Step ao wo co o genesis s t) :
    Weaver.LlmCheckpointTruncation.Run ao wo co genesis s.logical t.logical := by
  cases event with
  | switchRoot m cp worker expectedGeneration selected parent cas available publication confirmed checkpointDurable authentic actual coverage owner policy durable => exact .next (.refl _) actual
  | crash => exact .next (.refl _) (.loseReply _)
  | authority next actual wal checkpoint suffix blobs noActivation => exact .next (.refl _) actual
  | activate next worker actual wal checkpoint suffix blobs confirmed owner => exact .next (.refl _) actual
  | _ => exact .refl _

theorem checkpoint_extend (r : Weaver.LlmCheckpointTruncation.Run ao wo co genesis a b)
    (priorRun : Weaver.LlmCheckpointTruncation.Run ao wo co genesis x a) :
    Weaver.LlmCheckpointTruncation.Run ao wo co genesis x b := by
  induction r with
  | refl => exact priorRun
  | next prior event ih => exact .next ih event

theorem actual_checkpoint_composition (run : Run ao wo co o genesis s t)
    (priorRun : Weaver.LlmCheckpointTruncation.Run ao wo co genesis x s.logical) :
    Weaver.LlmCheckpointTruncation.Run ao wo co genesis x t.logical := by
  induction run with
  | refl => exact priorRun
  | next prior event ih => exact checkpoint_extend (logical_projection event) ih

theorem original_reservation_once (run : Run ao wo co o genesis s t)
    (priorRun : Weaver.LlmCheckpointTruncation.Run ao wo co genesis (Weaver.LlmCheckpointTruncation.initial ao balances) s.logical) (key) :
    t.logical.logical.core.authority.writes key ≤ 1 :=
  Weaver.LlmCheckpointTruncation.original_reservation_once (actual_checkpoint_composition run priorRun) key

theorem unknown_original_hold_retained (run : Run ao wo co o genesis s t)
    (priorRun : Weaver.LlmCheckpointTruncation.Run ao wo co genesis (Weaver.LlmCheckpointTruncation.initial ao balances) s.logical)
    (source : Weaver.LlmExecutionReconciliation.State S) (unknownUsage : source.metered = false)
    (binding : ∀ tx state, tx.reservation = originalKey → ao.sourceReady tx state → Weaver.LlmAccountCommit.OriginalReady originalKey attempt source tx) :
    t.logical.logical.core.authority.reservations originalKey = none ∧ t.logical.logical.core.authority.holds originalKey = ao.bound originalKey :=
  Weaver.LlmCheckpointTruncation.unknown_original_hold_retained (actual_checkpoint_composition run priorRun) source unknownUsage binding

theorem switched_response_is_unknown (s : State) (m cp) :
    ({s with root := m, generation := s.generation+1, observed := none, logical := {s.logical with localCheckpoint := some cp, suffix := frames m, logical := {s.logical.logical with receipt := none, active := false}}} : State).observed = none := rfl

theorem erase_preserves_account (s : State) (id : Nat) :
    ({s with objects := s.objects.filter (fun seg => seg.id != id)} : State).logical = s.logical := rfl

theorem deletion_preserves_selected_segments (event : Step ao wo co o genesis s t)
    (_same : t.root = s.root) (safe : Safe o s) :
    ∀ seg ∈ t.root.segments, seg ∈ t.objects :=
  fun seg member => ((safe_step safe event).1.2.2.1 seg member).1

theorem generation_monotone (event : Step ao wo co o genesis s t) : s.generation ≤ t.generation := by
  cases event <;> simp <;> omega

theorem stale_owner_cannot_erase (s : State) (worker : Nat) (old : worker ≠ s.logical.logical.core.epoch) :
    ¬ worker = s.logical.logical.core.epoch := old

theorem referenced_segment_cannot_be_erased (s : State) (seg : Segment) (member : seg ∈ s.root.segments) :
    ¬ (∀ x ∈ s.root.segments, x.id ≠ seg.id) := by
  intro h; exact h seg member rfl

theorem durable_switch_required (event : Step ao wo co o genesis s t) (changed : s.generation ≠ t.generation) :
    ∃ m, Available o s m ∧ m.parent = s.root.id ∧ o.switchDurable m (s.generation+1) := by
  cases event with
  | switchRoot m cp worker expectedGeneration selected parent cas available publication confirmed checkpointDurable authentic actual coverage owner policy durable => exact ⟨m,available,parent,durable⟩
  | _ => exact False.elim (changed rfl)

#print axioms recovery_copy_retained
#print axioms logical_projection
#print axioms actual_checkpoint_composition
#print axioms original_reservation_once
#print axioms unknown_original_hold_retained
#print axioms switched_response_is_unknown
#print axioms erase_preserves_account
#print axioms deletion_preserves_selected_segments
#print axioms generation_monotone
#print axioms stale_owner_cannot_erase
#print axioms referenced_segment_cannot_be_erased
#print axioms durable_switch_required
end Weaver.LlmManifestSwitch
