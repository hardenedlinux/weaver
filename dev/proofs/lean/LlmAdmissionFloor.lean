import LlmAppendHandoff
namespace Weaver.LlmAdmissionFloor
-- Immutable recovery metadata; no account balance projection is installed from it.
structure Image where
  root : Weaver.LlmManifestSwitch.Manifest
  closed : List Weaver.LlmManifestSwitch.Segment
  live : List Weaver.LlmManifestSwitch.Segment
  allocated : List Weaver.LlmManifestSwitch.Segment
  rootGeneration : Nat
  appendGeneration : Nat
  frontier : Nat
  sequence : Nat
  cut : Option Weaver.LlmAppendHandoff.Cut
  candidate : Option Weaver.LlmManifestSwitch.Manifest
  worker : Nat
  sourceGeneration : Nat
structure Proposal where
  id : Nat
  intent : Nat
  parent : Nat
  before : Image
  after : Image
  worker : Nat
structure Record where
  proposal : Proposal
structure Receipt where
  revision : Nat
  record : Option Record
structure State where
  logical : Weaver.LlmAppendHandoff.State
  committed : List Record
  pending : List Proposal
  projection : Option Image
  objects : List Weaver.LlmManifestSwitch.Segment
  checkpoints : List Weaver.LlmCheckpointTruncation.Checkpoint
  observed : Option Receipt
  active : Bool
  resolved : Option Record
structure Owner where
  bodyDurable : Image → Prop
  publicationDurable : Record → Prop
  authentic : State → Prop
  archiveAuthentic : State → Prop
  policy : Proposal → State → Prop
  intentMatches : Proposal → Weaver.LlmAppendHandoff.State → Weaver.LlmAppendHandoff.State → Prop

def image (s : Weaver.LlmAppendHandoff.State) : Image :=
  ⟨s.root,s.closed,s.live,s.allocated,s.rootGeneration,s.appendGeneration,s.frontier,s.sequence,s.cut,s.candidate,s.logical.logical.core.epoch,s.logical.logical.core.sourceGeneration⟩
def latest : List Record → Option Record
  | [] => none
  | x::xs => match latest xs with | none => some x | some y => some y

def current (s : State) : Receipt := ⟨s.committed.length,latest s.committed⟩
def Confirmed (s : State) : Prop := s.observed = some (current s)
def Required (s : Weaver.LlmAppendHandoff.State) (cp : Weaver.LlmCheckpointTruncation.Checkpoint) : Prop :=
  s.root.checkpoint = some cp ∨ ∃ m, s.candidate = some m ∧ m.checkpoint = some cp

def Complete (s : State) : Prop :=
  (∀ seg ∈ Weaver.LlmAppendHandoff.refs s.logical, seg ∈ s.objects) ∧
  (∀ cp, Required s.logical cp → cp ∈ s.checkpoints)
def Qualified (s : State) : Prop := Confirmed s ∧ s.projection = some (image s.logical) ∧ Complete s

def seed (s : Weaver.LlmAppendHandoff.State) : Record := ⟨⟨0,0,0,image s,image s,s.logical.logical.core.epoch⟩⟩
def initial (s : Weaver.LlmAppendHandoff.State) : State := ⟨s,[seed s],[],none,[],[],none,false,none⟩
def Safe (s : State) : Prop :=
  (∃ r, latest s.committed = some r ∧ r.proposal.after = image s.logical) ∧
  (s.active = true → Qualified s)

inductive Step (ao : Weaver.LlmAccountCommit.Owner) (wo : Weaver.LlmWalActivation.Owner)
    (co : Weaver.LlmCheckpointTruncation.Owner) (ho : Weaver.LlmAppendHandoff.Owner)
    (o : Owner) (genesis : Weaver.LlmAccountCommit.Image) : State → State → Prop where
  | propose (s p) (body : o.bodyDurable p.after)
      (identity : ∀ prior ∈ s.pending, prior.id = p.id → prior.intent = p.intent) :
      Step ao wo co ho o genesis s {s with pending := s.pending ++ [p]}
  | commit (s p next) (pending : p ∈ s.pending) (qualified : Qualified s)
      (parent : p.parent = s.committed.length) (before : p.before = image s.logical)
      (after : p.after = image next) (owner : p.worker = s.logical.logical.logical.core.epoch)
      (fresh : ∀ r ∈ s.committed, r.proposal.id ≠ p.id)
      (actual : Weaver.LlmAppendHandoff.Step ao wo co ho genesis s.logical next)
      (noBalance : next.logical.logical.core.authority = s.logical.logical.logical.core.authority)
      (noFinancialCommit : next.logical.logical.core.journal = s.logical.logical.logical.core.journal)
      (body : o.bodyDurable p.after) (intent : o.intentMatches p s.logical next) (policy : o.policy p s) (durable : o.publicationDurable ⟨p⟩) :
      Step ao wo co ho o genesis s {s with logical := next, committed := s.committed ++ [⟨p⟩], observed := none, active := false}
  | financial (s next) (actual : Weaver.LlmAppendHandoff.Step ao wo co ho genesis s.logical next)
      (same : image next = image s.logical) :
      Step ao wo co ho o genesis s {s with logical := next, active := false}
  | resolve (s r) (member : r ∈ s.committed) :
      Step ao wo co ho o genesis s {s with resolved := some r}
  | query (s worker) (owner : worker = s.logical.logical.logical.core.epoch) (authentic : o.authentic s) :
      Step ao wo co ho o genesis s {s with observed := some (current s)}
  | restore (s snapshot objects checkpoints) :
      Step ao wo co ho o genesis s {s with projection := snapshot, objects := objects, checkpoints := checkpoints, observed := none, active := false}
  | fetch (s objects checkpoints) (authentic : o.archiveAuthentic s)
      (segments : ∀ seg ∈ Weaver.LlmAppendHandoff.refs s.logical, seg ∈ objects)
      (bodies : ∀ cp, Required s.logical cp → cp ∈ checkpoints) :
      Step ao wo co ho o genesis s {s with objects := objects, checkpoints := checkpoints, active := false}
  | project (s worker) (confirmed : Confirmed s) (owner : worker = s.logical.logical.logical.core.epoch)
      (authentic : o.archiveAuthentic s) (complete : Complete s) :
      Step ao wo co ho o genesis s {s with projection := some (image s.logical), active := false}
  | activate (s worker) (owner : worker = s.logical.logical.logical.core.epoch) (qualified : Qualified s) :
      Step ao wo co ho o genesis s {s with active := true}
  | loseReply (s) : Step ao wo co ho o genesis s {s with observed := none, active := false}

inductive Run (ao : Weaver.LlmAccountCommit.Owner) (wo : Weaver.LlmWalActivation.Owner)
    (co : Weaver.LlmCheckpointTruncation.Owner) (ho : Weaver.LlmAppendHandoff.Owner)
    (o : Owner) (genesis : Weaver.LlmAccountCommit.Image) : State → State → Prop where
  | refl (s) : Run ao wo co ho o genesis s s
  | next : Run ao wo co ho o genesis a b → Step ao wo co ho o genesis b d → Run ao wo co ho o genesis a d

theorem latest_append (rs : List Record) (r : Record) : latest (rs ++ [r]) = some r := by
  induction rs with
  | nil => rfl
  | cons x xs ih => simp [latest,ih]

theorem safe_step (safe : Safe s) (event : Step ao wo co ho o genesis s t) : Safe t := by
  obtain ⟨head,live⟩ := safe
  cases event with
  | commit p next pending qualified parent before after owner fresh actual noBalance noFinancialCommit body intent policy durable =>
    exact ⟨⟨⟨p⟩,latest_append _ _,after⟩,by simp⟩
  | financial next actual same =>
    obtain ⟨r,selected,aligned⟩ := head
    exact ⟨⟨r,selected,aligned.trans same.symm⟩,by simp⟩
  | propose p body identity => exact ⟨head,live⟩
  | resolve r member => exact ⟨head,live⟩
  | query worker owner authentic =>
    exact ⟨head,by intro active; exact ⟨rfl,(live active).2⟩⟩
  | restore snapshot objects checkpoints => exact ⟨head,by simp⟩
  | fetch objects checkpoints authentic segments bodies => exact ⟨head,by simp⟩
  | project worker confirmed owner authentic complete => exact ⟨head,by simp⟩
  | activate worker owner qualified => exact ⟨head,fun _ => qualified⟩
  | loseReply => exact ⟨head,by simp⟩

theorem initialized_safe (run : Run ao wo co ho o genesis (initial h) s) : Safe s := by
  induction run with
  | refl => exact ⟨⟨seed h,rfl,rfl⟩,by simp [initial]⟩
  | next prior event ih => exact safe_step ih event

theorem logical_projection (event : Step ao wo co ho o genesis s t) : Weaver.LlmAppendHandoff.Run ao wo co ho genesis s.logical t.logical := by
  cases event with
  | commit p next pending qualified parent before after owner fresh actual noBalance noFinancialCommit body intent policy durable => exact .next (.refl _) actual
  | financial next actual same => exact .next (.refl _) actual
  | _ => exact .refl _

theorem handoff_extend (r : Weaver.LlmAppendHandoff.Run ao wo co ho genesis a b)
    (priorRun : Weaver.LlmAppendHandoff.Run ao wo co ho genesis x a) : Weaver.LlmAppendHandoff.Run ao wo co ho genesis x b := by
  induction r with
  | refl => exact priorRun
  | next prior event ih => exact .next ih event

theorem actual_handoff_composition (run : Run ao wo co ho o genesis s t)
    (priorRun : Weaver.LlmAppendHandoff.Run ao wo co ho genesis x s.logical) : Weaver.LlmAppendHandoff.Run ao wo co ho genesis x t.logical := by
  induction run with
  | refl => exact priorRun
  | next prior event ih => exact handoff_extend (logical_projection event) ih

theorem original_reservation_once (safe : Weaver.LlmAppendHandoff.Safe ho h)
    (run : Run ao wo co ho o genesis (initial h) s)
    (priorRun : Weaver.LlmCheckpointTruncation.Run ao wo co genesis (Weaver.LlmCheckpointTruncation.initial ao balances) h.logical) (key) :
    s.logical.logical.logical.core.authority.writes key ≤ 1 :=
  Weaver.LlmAppendHandoff.original_reservation_once safe (actual_handoff_composition run (.refl _)) priorRun key

theorem unknown_original_hold_retained (safe : Weaver.LlmAppendHandoff.Safe ho h)
    (run : Run ao wo co ho o genesis (initial h) s)
    (priorRun : Weaver.LlmCheckpointTruncation.Run ao wo co genesis (Weaver.LlmCheckpointTruncation.initial ao balances) h.logical)
    (source : Weaver.LlmExecutionReconciliation.State S) (unknownUsage : source.metered = false)
    (binding : ∀ tx state, tx.reservation = originalKey → ao.sourceReady tx state → Weaver.LlmAccountCommit.OriginalReady originalKey attempt source tx) :
    s.logical.logical.logical.core.authority.reservations originalKey = none ∧ s.logical.logical.logical.core.authority.holds originalKey = ao.bound originalKey :=
  Weaver.LlmAppendHandoff.unknown_original_hold_retained safe (actual_handoff_composition run (.refl _)) priorRun source unknownUsage binding

theorem committed_prefix_retained (event : Step ao wo co ho o genesis s t) : ∃ added, t.committed = s.committed ++ added := by
  cases event with
  | commit p next pending qualified parent before after owner fresh actual noBalance noFinancialCommit body intent policy durable => exact ⟨[⟨p⟩],rfl⟩
  | _ => exact ⟨[],by simp⟩

theorem pending_intent_retained (event : Step ao wo co ho o genesis s t) (member : p ∈ s.pending) : p ∈ t.pending := by
  cases event with
  | propose p body identity => exact List.mem_append_left _ member
  | _ => exact member

theorem active_requires_current_floor (run : Run ao wo co ho o genesis (initial h) s) (active : s.active = true) : Qualified s :=
  (initialized_safe run).2 active

theorem publication_has_no_financial_effect (event : Step ao wo co ho o genesis s t)
    (changed : t.committed.length ≠ s.committed.length) :
    t.logical.logical.logical.core.authority = s.logical.logical.logical.core.authority ∧
    t.logical.logical.logical.core.journal = s.logical.logical.logical.core.journal ∧ t.active = false := by
  cases event with
  | commit p next pending qualified parent before after owner fresh actual noBalance noFinancialCommit body intent policy durable => exact ⟨noBalance,noFinancialCommit,rfl⟩
  | _ => exact False.elim (changed rfl)

theorem publication_requires_durable_body (event : Step ao wo co ho o genesis s t)
    (changed : t.committed.length ≠ s.committed.length) :
    ∃ p, p ∈ s.pending ∧ p.parent = s.committed.length ∧ o.bodyDurable p.after ∧ o.publicationDurable ⟨p⟩ ∧ Qualified s ∧ p.worker = s.logical.logical.logical.core.epoch ∧ p.before = image s.logical := by
  cases event with
  | commit p next pending qualified parent before after owner fresh actual noBalance noFinancialCommit body intent policy durable => exact ⟨p,pending,parent,body,durable,qualified,owner,before⟩
  | _ => exact False.elim (changed rfl)

theorem guarded_generation_monotone (event : Step ao wo co ho o genesis s t) : s.logical.appendGeneration ≤ t.logical.appendGeneration := by
  cases event with
  | commit p next pending qualified parent before after owner fresh actual noBalance noFinancialCommit body intent policy durable => exact Weaver.LlmAppendHandoff.append_generation_monotone actual
  | financial next actual same => exact Weaver.LlmAppendHandoff.append_generation_monotone actual
  | _ => exact Nat.le_refl _

theorem reference_copy_retained (safe : Weaver.LlmAppendHandoff.Safe ho h)
    (run : Run ao wo co ho o genesis (initial h) s) : Weaver.LlmAppendHandoff.Safe ho s.logical :=
  Weaver.LlmAppendHandoff.recovery_copy_retained safe (actual_handoff_composition run (.refl _))

theorem committed_operation_unique (run : Run ao wo co ho o genesis (initial h) s) :
    ∀ r ∈ s.committed, ∀ other ∈ s.committed, r.proposal.id = other.proposal.id → r = other := by
  induction run with
  | refl => simp [initial]
  | next prior event ih =>
    cases event with
    | commit p next pending qualified parent before after owner fresh actual noBalance noFinancialCommit body intent policy durable =>
      intro r member other stored same
      rcases List.mem_append.mp member with old|new
      · rcases List.mem_append.mp stored with oldOther|newOther
        · exact ih r old other oldOther same
        · have eq : other = ⟨p⟩ := by simpa using newOther
          subst other; exact False.elim (fresh r old same)
      · have eq : r = ⟨p⟩ := by simpa using new
        subst r
        rcases List.mem_append.mp stored with oldOther|newOther
        · exact False.elim (fresh other oldOther same.symm)
        · have eq : other = ⟨p⟩ := by simpa using newOther
          exact eq.symm
    | _ => exact ih

theorem local_restore_preserves_authority (s : State) (snapshot objects checkpoints) :
    ({s with projection := snapshot, objects := objects, checkpoints := checkpoints, observed := none, active := false} : State).logical = s.logical := rfl

#print axioms committed_operation_unique
#print axioms local_restore_preserves_authority
#print axioms initialized_safe
#print axioms logical_projection
#print axioms actual_handoff_composition
#print axioms original_reservation_once
#print axioms unknown_original_hold_retained
#print axioms committed_prefix_retained
#print axioms pending_intent_retained
#print axioms active_requires_current_floor
#print axioms publication_has_no_financial_effect
#print axioms publication_requires_durable_body
#print axioms guarded_generation_monotone
#print axioms reference_copy_retained
end Weaver.LlmAdmissionFloor
