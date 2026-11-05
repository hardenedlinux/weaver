-- SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
--
-- SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

import LlmManifestSwitch
namespace Weaver.LlmAppendHandoff
structure Cut where
  id : Nat
  parent : Nat
  rootGeneration : Nat
  appendGeneration : Nat
  records : List Weaver.LlmAccountCommit.Record
structure Receipt where
  root : Nat
  rootGeneration : Nat
  appendGeneration : Nat
  frontier : Nat
  worker : Nat
structure State where
  logical : Weaver.LlmCheckpointTruncation.State
  root : Weaver.LlmManifestSwitch.Manifest
  closed : List Weaver.LlmManifestSwitch.Segment
  live : List Weaver.LlmManifestSwitch.Segment
  objects : List Weaver.LlmManifestSwitch.Segment
  allocated : List Weaver.LlmManifestSwitch.Segment
  rootGeneration : Nat
  appendGeneration : Nat
  frontier : Nat
  sequence : Nat
  cut : Option Cut
  candidate : Option Weaver.LlmManifestSwitch.Manifest
  observed : Option Receipt
structure Owner where
  segmentDurable : Weaver.LlmManifestSwitch.Segment → Prop
  appendDurable : State → Weaver.LlmManifestSwitch.Segment → Prop
  cutDurable : Cut → Prop
  manifestDurable : Weaver.LlmManifestSwitch.Manifest → Prop
  switchDurable : State → Weaver.LlmManifestSwitch.Manifest → Prop
  authentic : State → Prop
  policy : State → Prop

def flat (xs : List Weaver.LlmManifestSwitch.Segment) := xs.flatMap Weaver.LlmManifestSwitch.Segment.records
def snapshot (s : State) := Weaver.LlmManifestSwitch.replay s.root ++ flat s.closed
def replay (s : State) := snapshot s ++ flat s.live
def suffix (s : State) := Weaver.LlmManifestSwitch.frames s.root ++ flat s.closed ++ flat s.live
def candidateSegments (s : State) := match s.candidate with | none => [] | some m => m.segments
def refs (s : State) := s.root.segments ++ s.closed ++ s.live ++ candidateSegments s
def current (s : State) : Receipt := ⟨s.root.id,s.rootGeneration,s.appendGeneration,s.frontier,s.logical.logical.core.epoch⟩
def Confirmed (s : State) := s.observed = some (current s)
def Aligned (s : State) : Prop := ∀ c, s.cut = some c → c.records = snapshot s ∧ c.parent = s.root.id ∧ c.rootGeneration = s.rootGeneration ∧ c.appendGeneration = s.appendGeneration
def Candidate (s : State) : Prop := ∀ m, s.candidate = some m → ∃ c, s.cut = some c ∧ Weaver.LlmManifestSwitch.replay m = c.records
def Bodies (s : State) : Prop :=
  (∀ cp, s.root.checkpoint = some cp → cp ∈ s.logical.blobs) ∧
  (∀ m, s.candidate = some m → ∀ cp, m.checkpoint = some cp → cp ∈ s.logical.blobs)
def Safe (o : Owner) (s : State) : Prop :=
  (∀ seg ∈ refs s, seg ∈ s.objects ∧ o.segmentDurable seg) ∧
  replay s = s.logical.logical.wal ∧ s.root.checkpoint = s.logical.localCheckpoint ∧
  suffix s = s.logical.suffix ∧ Aligned s ∧ Candidate s ∧ Bodies s ∧ o.manifestDurable s.root

def freshCut (s : State) : Cut := ⟨s.sequence+1,s.root.id,s.rootGeneration,s.appendGeneration+1,replay s⟩
def switched (s : State) (m : Weaver.LlmManifestSwitch.Manifest) (cp : Weaver.LlmCheckpointTruncation.Checkpoint) : State :=
  {s with logical := {s.logical with localCheckpoint := some cp, suffix := Weaver.LlmManifestSwitch.frames m ++ flat s.live, logical := {s.logical.logical with receipt := none, active := false}}, root := m, closed := [], rootGeneration := s.rootGeneration+1, cut := none, candidate := none, observed := none}

inductive Step (ao : Weaver.LlmAccountCommit.Owner) (wo : Weaver.LlmWalActivation.Owner)
    (co : Weaver.LlmCheckpointTruncation.Owner) (o : Owner) (genesis : Weaver.LlmAccountCommit.Image) : State → State → Prop where
  | append (s seg p worker generation frontier)
      (confirmed : Confirmed s) (owner : worker = s.logical.logical.core.epoch)
      (epoch : generation = s.appendGeneration) (cas : frontier = s.frontier)
      (policy : o.policy s) (body : seg.records = [Weaver.LlmWalActivation.frame p])
      (fresh : ∀ old ∈ s.allocated, old.id ≠ seg.id) (durable : o.segmentDurable seg) (admitted : o.appendDurable s seg)
      (stored : p ∈ s.logical.logical.core.prepared) (ready : Weaver.LlmAccountCommit.Ready ao s.logical.logical.core p)
      (exact : s.logical.logical.wal = s.logical.logical.core.journal) (walDurable : wo.walDurable (Weaver.LlmWalActivation.frame p)) :
      Step ao wo co o genesis s {s with logical := {s.logical with suffix := s.logical.suffix ++ seg.records, logical := {s.logical.logical with wal := s.logical.logical.wal ++ [Weaver.LlmWalActivation.frame p]}}, live := s.live ++ [seg], objects := s.objects ++ [seg], allocated := s.allocated ++ [seg], frontier := s.frontier+1, observed := none}
  | sealCut (s worker generation frontier) (none : s.cut = Option.none) (noCandidate : s.candidate = Option.none)
      (confirmed : Confirmed s) (owner : worker = s.logical.logical.core.epoch) (epoch : generation = s.appendGeneration)
      (cas : frontier = s.frontier) (policy : o.policy s) (durable : o.cutDurable (freshCut s)) :
      Step ao wo co o genesis s {s with closed := s.closed ++ s.live, live := [], appendGeneration := s.appendGeneration+1, sequence := s.sequence+1, cut := some (freshCut s), observed := Option.none}
  | stage (s m c) (cut : s.cut = some c) (coverage : Weaver.LlmManifestSwitch.replay m = c.records)
      (parent : m.parent = c.parent) (durable : o.manifestDurable m)
      (objects : ∀ seg ∈ m.segments, seg ∈ s.objects ∧ o.segmentDurable seg)
      (body : ∀ cp, m.checkpoint = some cp → cp ∈ s.logical.blobs) :
      Step ao wo co o genesis s {s with candidate := some m}
  | switchRoot (s m cp c worker generation frontier) (cut : s.cut = some c) (staged : s.candidate = some m)
      (selected : m.checkpoint = some cp) (publication : Weaver.LlmCheckpointTruncation.latest s.logical.published = some cp)
      (publicationConfirmed : Weaver.LlmCheckpointTruncation.Confirmed s.logical)
      (checkpointDurable : co.blobDurable cp) (checkpointAuthentic : co.prefixAuthentic s.logical)
      (manifestDurable : o.manifestDurable m)
      (parent : m.parent = s.root.id) (confirmed : Confirmed s) (owner : worker = s.logical.logical.core.epoch)
      (epoch : generation = s.appendGeneration) (cas : frontier = s.frontier)
      (actual : Weaver.LlmCheckpointTruncation.Step ao wo co genesis s.logical (switched s m cp).logical)
      (policy : o.policy s) (durable : o.switchDurable s m) : Step ao wo co o genesis s (switched s m cp)
  | observe (s worker) (owner : worker = s.logical.logical.core.epoch) (authentic : o.authentic s) :
      Step ao wo co o genesis s {s with observed := some (current s)}
  | erase (s id worker generation frontier) (confirmed : Confirmed s) (owner : worker = s.logical.logical.core.epoch)
      (epoch : generation = s.appendGeneration) (cas : frontier = s.frontier)
      (unreferenced : ∀ seg ∈ refs s, seg.id ≠ id) (policy : o.policy s) :
      Step ao wo co o genesis s {s with objects := s.objects.filter (fun seg => seg.id != id)}
  | crash (s) : Step ao wo co o genesis s {s with observed := none, logical := {s.logical with observed := none, logical := {s.logical.logical with receipt := none, active := false}}}
  | authority (s next) (actual : Weaver.LlmCheckpointTruncation.Step ao wo co genesis s.logical next)
      (wal : next.logical.wal = s.logical.logical.wal) (checkpoint : next.localCheckpoint = s.logical.localCheckpoint)
      (suffix : next.suffix = s.logical.suffix) (blobs : next.blobs = s.logical.blobs) : Step ao wo co o genesis s {s with logical := next}

inductive Run (ao : Weaver.LlmAccountCommit.Owner) (wo : Weaver.LlmWalActivation.Owner)
    (co : Weaver.LlmCheckpointTruncation.Owner) (o : Owner) (genesis : Weaver.LlmAccountCommit.Image) : State → State → Prop where
  | refl (s) : Run ao wo co o genesis s s
  | next : Run ao wo co o genesis a b → Step ao wo co o genesis b d → Run ao wo co o genesis a d

 theorem flat_append (xs ys) : flat (xs ++ ys) = flat xs ++ flat ys := by simp [flat,List.flatMap_append]
 theorem cut_snapshot (s : State) : snapshot {s with closed := s.closed ++ s.live, live := []} = replay s := by simp [snapshot,replay,flat_append,List.append_assoc]

 theorem safe_step (safe : Safe o s) (event : Step ao wo co o genesis s t) : Safe o t := by
  obtain ⟨available,represented,checkpointEq,suffixEq,aligned,candidate,bodies,rootDurable⟩ := safe
  cases event with
  | append seg p worker generation frontier confirmed owner epoch cas policy body fresh durable admitted stored ready exact walDurable =>
    refine ⟨?_,?_,checkpointEq,?_,?_,?_,?_,?_⟩
    · intro x member
      have members : x ∈ refs s ∨ x = seg := by simpa [refs,candidateSegments,List.mem_append,List.mem_cons,or_assoc,or_left_comm,or_comm] using member
      rcases members with old|same
      · exact ⟨List.mem_append_left _ (available x old).1,(available x old).2⟩
      · subst x; exact ⟨by simp,durable⟩
    · simpa [replay,snapshot,flat,List.flatMap_append,List.append_assoc,body] using congrArg (fun xs => xs ++ [Weaver.LlmWalActivation.frame p]) represented
    · simpa [suffix,flat,List.flatMap_append,List.append_assoc] using congrArg (fun xs => xs ++ seg.records) suffixEq
    · exact aligned
    · exact candidate
    · exact bodies
    · exact rootDurable
  | sealCut worker generation frontier none noCandidate confirmed owner epoch cas policy durable =>
    refine ⟨?_,?_,checkpointEq,?_,?_,?_,?_,?_⟩
    · simpa [refs,candidateSegments,noCandidate,List.append_assoc] using available
    · simpa [replay,snapshot,flat_append,List.append_assoc,flat] using represented
    · simpa [suffix,flat_append,List.append_assoc,flat] using suffixEq
    · intro c h; have eq : c = freshCut s := (Option.some.inj h).symm; subst c
      exact ⟨by simp [freshCut,snapshot,replay,flat_append,List.append_assoc],rfl,rfl,rfl⟩
    · intro m h; change s.candidate = some m at h; rw [noCandidate] at h; cases h
    · exact bodies
    · exact rootDurable
  | stage m c cut coverage parent durable objects body =>
    refine ⟨?_,represented,checkpointEq,suffixEq,aligned,?_,?_,rootDurable⟩
    · intro x member
      have members : x ∈ s.root.segments ++ s.closed ++ s.live ∨ x ∈ m.segments := by simpa [refs,candidateSegments,or_assoc] using member
      rcases members with old|new
      · exact available x (List.mem_append_left _ old)
      · exact objects x new
    · intro m' h; have eq : m' = m := (Option.some.inj h).symm; subst m'; exact ⟨c,cut,coverage⟩
    · refine ⟨bodies.1,?_⟩
      intro m' h; have eq : m' = m := (Option.some.inj h).symm; subst m'; exact body
  | switchRoot m cp c worker generation frontier cut staged selected publication publicationConfirmed checkpointDurable checkpointAuthentic manifestDurable parent confirmed owner epoch cas actual policy durable =>
    obtain ⟨cut',same,coverage⟩ := candidate m staged
    have eq : cut' = c := Option.some.inj (same.symm.trans cut); subst cut'
    have captured := (aligned c cut).1
    refine ⟨?_,?_,selected,?_,?_,?_,?_,manifestDurable⟩
    · intro x member
      have members : x ∈ m.segments ∨ x ∈ s.live := by simpa [refs,switched,candidateSegments,List.mem_append] using member
      apply available x
      rcases members with new|live
      · simp [refs,candidateSegments,staged,new]
      · simp [refs,live]
    · simpa [replay,snapshot,switched,flat,coverage,captured] using represented
    · simp [suffix,switched,flat]
    · intro c h; cases h
    · intro m h; cases h
    · exact ⟨bodies.2 m staged,by intro m h; cases h⟩
  | observe worker owner authentic => exact ⟨available,represented,checkpointEq,suffixEq,aligned,candidate,bodies,rootDurable⟩
  | erase id worker generation frontier confirmed owner epoch cas unreferenced policy =>
    refine ⟨?_,represented,checkpointEq,suffixEq,aligned,candidate,bodies,rootDurable⟩
    intro x member
    exact ⟨List.mem_filter.mpr ⟨(available x member).1,by simp [unreferenced x member]⟩,(available x member).2⟩
  | crash => exact ⟨available,represented,checkpointEq,suffixEq,aligned,candidate,bodies,rootDurable⟩
  | authority next actual wal checkpoint suffix blobs =>
    exact ⟨available,represented.trans wal.symm,checkpointEq.trans checkpoint.symm,suffixEq.trans suffix.symm,aligned,candidate,(by simpa [Bodies,blobs] using bodies),rootDurable⟩

 theorem recovery_copy_retained (safe : Safe o s) (run : Run ao wo co o genesis s t) : Safe o t := by
  induction run with
  | refl => exact safe
  | next prior event ih => exact safe_step ih event

 theorem logical_projection (safe : Safe o s) (event : Step ao wo co o genesis s t) : Weaver.LlmCheckpointTruncation.Run ao wo co genesis s.logical t.logical := by
  cases event with
  | append seg p worker generation frontier confirmed owner epoch cas policy body fresh durable admitted stored ready exact walDurable =>
    have actual := Weaver.LlmWalActivation.Step.flush s.logical.logical p stored ready exact walDurable
    have represented : Weaver.LlmCheckpointTruncation.expanded s.logical.localCheckpoint (s.logical.suffix ++ seg.records) = s.logical.logical.wal ++ [Weaver.LlmWalActivation.frame p] := by
      have old : Weaver.LlmCheckpointTruncation.expanded s.logical.localCheckpoint s.logical.suffix = s.logical.logical.wal := by
        rw [←safe.2.2.1,←safe.2.2.2.1]
        simpa [Weaver.LlmCheckpointTruncation.expanded,Weaver.LlmManifestSwitch.replay,suffix,replay,snapshot,List.append_assoc] using safe.2.1
      simpa [body,Weaver.LlmCheckpointTruncation.expanded,List.append_assoc] using congrArg (fun xs => xs ++ [Weaver.LlmWalActivation.frame p]) old
    exact .next (.refl _) (.advance _ _ _ actual (fun h => h) represented)
  | switchRoot m cp c worker generation frontier cut staged selected publication publicationConfirmed checkpointDurable checkpointAuthentic manifestDurable parent confirmed owner epoch cas actual policy durable => exact .next (.refl _) actual
  | crash => exact .next (.refl _) (.loseReply _)
  | authority next actual wal checkpoint suffix blobs => exact .next (.refl _) actual
  | _ => exact .refl _
theorem actual_checkpoint_composition (safe : Safe o s) (run : Run ao wo co o genesis s t)
    (priorRun : Weaver.LlmCheckpointTruncation.Run ao wo co genesis x s.logical) :
    Weaver.LlmCheckpointTruncation.Run ao wo co genesis x t.logical := by
  induction run with
  | refl => exact priorRun
  | next prior event ih => exact Weaver.LlmManifestSwitch.checkpoint_extend (logical_projection (recovery_copy_retained safe prior) event) ih

theorem original_reservation_once (safe : Safe o s) (run : Run ao wo co o genesis s t)
    (priorRun : Weaver.LlmCheckpointTruncation.Run ao wo co genesis (Weaver.LlmCheckpointTruncation.initial ao balances) s.logical) (key) :
    t.logical.logical.core.authority.writes key ≤ 1 :=
  Weaver.LlmCheckpointTruncation.original_reservation_once (actual_checkpoint_composition safe run priorRun) key

theorem unknown_original_hold_retained (safe : Safe o s) (run : Run ao wo co o genesis s t)
    (priorRun : Weaver.LlmCheckpointTruncation.Run ao wo co genesis (Weaver.LlmCheckpointTruncation.initial ao balances) s.logical)
    (source : Weaver.LlmExecutionReconciliation.State S) (unknownUsage : source.metered = false)
    (binding : ∀ tx state, tx.reservation = originalKey → ao.sourceReady tx state → Weaver.LlmAccountCommit.OriginalReady originalKey attempt source tx) :
    t.logical.logical.core.authority.reservations originalKey = none ∧ t.logical.logical.core.authority.holds originalKey = ao.bound originalKey :=
  Weaver.LlmCheckpointTruncation.unknown_original_hold_retained (actual_checkpoint_composition safe run priorRun) source unknownUsage binding

theorem append_prefix_retained (event : Step ao wo co o genesis s t) : ∃ added, t.logical.logical.wal = s.logical.logical.wal ++ added := by
  cases event with
  | append seg p worker generation frontier confirmed owner epoch cas policy body fresh durable admitted stored ready exact walDurable => exact ⟨[Weaver.LlmWalActivation.frame p],rfl⟩
  | authority next actual wal checkpoint suffix blobs => exact ⟨[],by simpa using wal⟩
  | _ => exact ⟨[],by simp [switched]⟩

theorem switched_live_tail_retained (s m cp) : (switched s m cp).live = s.live ∧ (switched s m cp).logical.suffix = Weaver.LlmManifestSwitch.frames m ++ flat s.live := ⟨rfl,rfl⟩

theorem current_tail_not_collectible (s : State) (seg : Weaver.LlmManifestSwitch.Segment) (member : seg ∈ s.live) :
    ¬ (∀ x ∈ refs s, x.id ≠ seg.id) := by
  intro h; exact h seg (by simp [refs,member]) rfl

theorem append_generation_monotone (event : Step ao wo co o genesis s t) : s.appendGeneration ≤ t.appendGeneration := by
  cases event <;> simp [switched] <;> omega

theorem root_generation_monotone (event : Step ao wo co o genesis s t) : s.rootGeneration ≤ t.rootGeneration := by
  cases event <;> simp [switched] <;> omega

theorem durable_cut_required (event : Step ao wo co o genesis s t) (changed : s.appendGeneration ≠ t.appendGeneration) :
    o.cutDurable (freshCut s) ∧ Confirmed s := by
  cases event with
  | sealCut worker generation frontier none noCandidate confirmed owner epoch cas policy durable => exact ⟨durable,confirmed⟩
  | _ => exact False.elim (changed rfl)

theorem cut_records_retained (safe : Safe o s) (run : Run ao wo co o genesis s t) (selected : t.cut = some c) : c.records = snapshot t :=
  ((recovery_copy_retained safe run).2.2.2.2.1 c selected).1

theorem admission_requires_durable_descriptor (event : Step ao wo co o genesis s t)
    (changed : s.logical.logical.wal ≠ t.logical.logical.wal) :
    Confirmed s ∧ ∃ seg p, o.appendDurable s seg ∧ o.segmentDurable seg ∧
      seg.records = [Weaver.LlmWalActivation.frame p] ∧ Weaver.LlmAccountCommit.Ready ao s.logical.logical.core p := by
  cases event with
  | append seg p worker generation frontier confirmed owner epoch cas policy body fresh durable admitted stored ready exact walDurable =>
    exact ⟨confirmed,seg,p,admitted,durable,body,ready⟩
  | authority next actual wal checkpoint suffix blobs => exact False.elim (changed wal.symm)
  | _ => exact False.elim (changed rfl)

#print axioms admission_requires_durable_descriptor
#print axioms recovery_copy_retained
#print axioms logical_projection
#print axioms actual_checkpoint_composition
#print axioms original_reservation_once
#print axioms unknown_original_hold_retained
#print axioms append_prefix_retained
#print axioms switched_live_tail_retained
#print axioms current_tail_not_collectible
#print axioms append_generation_monotone
#print axioms root_generation_monotone
#print axioms durable_cut_required
#print axioms cut_records_retained
end Weaver.LlmAppendHandoff
