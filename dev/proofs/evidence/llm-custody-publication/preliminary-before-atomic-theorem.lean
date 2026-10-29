import LlmSourceCustody
namespace Weaver.LlmCustodyPublication

-- Storage-independent custody semantics. Durability is supplied by one protected
-- publication below, not separate fence/outcome writes in this logical owner.
def logicalOwner (sameIntent : LlmAdmissionFloor.Proposal → LlmAdmissionFloor.Proposal → Prop) : LlmSourceCustody.Owner where
  intentDurable := fun _ => True
  armDurable := fun _ => True
  fenceDurable := fun _ _ _ => True
  decisionDurable := fun _ => True
  authentic := fun _ => True
  sameIntent := sameIntent

structure Candidate where
  parent : Nat
  afterState : LlmSourceCustody.State
structure State where
  authority : LlmSourceCustody.State
  journal : List LlmSourceCustody.State
  pending : Nat → Option Candidate
  snapshot : Option LlmSourceCustody.State
  seen : Option Nat
  qualified : Bool
  reply : Option Nat
structure Owner where
  publishDurable : State → Candidate → Prop
  authenticRead : State → Prop

def initial (s : LlmSourceCustody.State) : State := ⟨s,[s],fun _ => none,none,none,false,none⟩
def Ready (s : State) : Prop := s.qualified = true ∧ s.snapshot = some s.authority ∧ s.seen = some s.journal.length

inductive Step (ao : LlmAccountCommit.Owner) (wo : LlmWalActivation.Owner)
    (co : LlmCheckpointTruncation.Owner) (ho : LlmAppendHandoff.Owner)
    (fo : LlmAdmissionFloor.Owner) (jo : LlmSourceJoin.Owner)
    (sameIntent : LlmAdmissionFloor.Proposal → LlmAdmissionFloor.Proposal → Prop)
    (o : Owner) (genesis : LlmAccountCommit.Image) : State → State → Prop where
  | stage (s next slot) (ready : Ready s)
      (preview : LlmSourceCustody.Step ao wo co ho fo jo (logicalOwner sameIntent) genesis s.authority next) :
      Step ao wo co ho fo jo sameIntent o genesis s {s with pending := fun key => if key = slot then some ⟨s.journal.length,next⟩ else s.pending key}
  | publish (s c slot) (deliver : Bool) (staged : s.pending slot = some c) (ready : Ready s)
      (parent : c.parent = s.journal.length)
      (actual : LlmSourceCustody.Step ao wo co ho fo jo (logicalOwner sameIntent) genesis s.authority c.afterState)
      (durable : o.publishDurable s c) :
      Step ao wo co ho fo jo sameIntent o genesis s {s with authority := c.afterState, journal := s.journal ++ [c.afterState], qualified := false, reply := if deliver then some (s.journal.length+1) else none}
  | observe (s) (authentic : o.authenticRead s) :
      Step ao wo co ho fo jo sameIntent o genesis s {s with snapshot := some s.authority, seen := some s.journal.length, qualified := true}
  | restore (s snapshot seen) :
      Step ao wo co ho fo jo sameIntent o genesis s {s with snapshot := snapshot, seen := seen, qualified := false}
  | acknowledge (s index) (committed : index < s.journal.length) :
      Step ao wo co ho fo jo sameIntent o genesis s {s with reply := some (index+1)}
  | loseReply (s) : Step ao wo co ho fo jo sameIntent o genesis s {s with reply := none}
  | restart (s) : Step ao wo co ho fo jo sameIntent o genesis s {s with snapshot := none, seen := none, qualified := false, reply := none}

inductive Run (ao : LlmAccountCommit.Owner) (wo : LlmWalActivation.Owner)
    (co : LlmCheckpointTruncation.Owner) (ho : LlmAppendHandoff.Owner)
    (fo : LlmAdmissionFloor.Owner) (jo : LlmSourceJoin.Owner)
    (sameIntent : LlmAdmissionFloor.Proposal → LlmAdmissionFloor.Proposal → Prop)
    (o : Owner) (genesis : LlmAccountCommit.Image) : State → State → Prop where
  | refl (s) : Run ao wo co ho fo jo sameIntent o genesis s s
  | next : Run ao wo co ho fo jo sameIntent o genesis a b → Step ao wo co ho fo jo sameIntent o genesis b d → Run ao wo co ho fo jo sameIntent o genesis a d

theorem custody_projection (event : Step ao wo co ho fo jo semantic o genesis s t) :
    LlmSourceCustody.Run ao wo co ho fo jo (logicalOwner semantic) genesis s.authority t.authority := by
  cases event with
  | publish c slot deliver staged ready parent actual durable => exact .next (.refl _) actual
  | _ => exact .refl _

theorem custody_extend (r : LlmSourceCustody.Run ao wo co ho fo jo owner genesis a b)
    (priorRun : LlmSourceCustody.Run ao wo co ho fo jo owner genesis x a) : LlmSourceCustody.Run ao wo co ho fo jo owner genesis x b := by
  induction r with
  | refl => exact priorRun
  | next prior event ih => exact .next ih event

theorem actual_custody_composition (run : Run ao wo co ho fo jo semantic o genesis s t)
    (priorRun : LlmSourceCustody.Run ao wo co ho fo jo (logicalOwner semantic) genesis x s.authority) :
    LlmSourceCustody.Run ao wo co ho fo jo (logicalOwner semantic) genesis x t.authority := by
  induction run with
  | refl => exact priorRun
  | next prior event ih => exact custody_extend (custody_projection event) ih

theorem journal_prefix_step (event : Step ao wo co ho fo jo semantic o genesis s t) : ∃ suffix, t.journal = s.journal ++ suffix := by
  cases event with
  | publish c slot deliver staged ready parent actual durable => exact ⟨[c.afterState],rfl⟩
  | _ => exact ⟨[],by simp⟩

theorem journal_prefix_run (run : Run ao wo co ho fo jo semantic o genesis s t) : ∃ suffix, t.journal = s.journal ++ suffix := by
  induction run with
  | refl => exact ⟨[],by simp⟩
  | next prior event ih =>
    obtain ⟨xs,hxs⟩ := ih
    obtain ⟨ys,hys⟩ := journal_prefix_step event
    exact ⟨xs++ys,by rw [hys,hxs,List.append_assoc]⟩

theorem journal_alignment (run : Run ao wo co ho fo jo semantic o genesis (initial original) s) : s.journal.getLast? = some s.authority := by
  induction run with
  | refl => rfl
  | next prior event ih => cases event <;> simp_all

theorem fence_monotone (event : Step ao wo co ho fo jo semantic o genesis s t) : s.authority.fence ≤ t.authority.fence := by
  cases event with
  | publish c slot deliver staged ready parent actual durable => exact LlmSourceCustody.fence_monotone actual
  | _ => exact Nat.le_refl _

theorem outcome_retained (run : Run ao wo co ho fo jo semantic o genesis s t) (known : s.authority.outcome = some r) : t.authority.outcome = some r := by
  induction run with
  | refl => exact known
  | next prior event ih =>
    cases event with
    | publish c slot deliver staged ready parent actual durable => exact LlmSourceCustody.determined_outcome_retained actual ih
    | _ => exact ih

theorem staging_has_no_authoritative_effect (event : Step ao wo co ho fo jo semantic o genesis s t)
    (unpublished : t.journal = s.journal) : t.authority = s.authority := by
  cases event with
  | publish c slot deliver staged ready parent actual durable =>
    have eq := congrArg List.length unpublished
    simp only [List.length_append,List.length_singleton] at eq
    omega
  | _ => rfl

theorem publication_checks_current_parent (event : Step ao wo co ho fo jo semantic o genesis s t)
    (published : t.journal.length ≠ s.journal.length) :
    Ready s ∧ ∃ c : Candidate, c.parent = s.journal.length ∧ LlmSourceCustody.Step ao wo co ho fo jo (logicalOwner semantic) genesis s.authority c.afterState := by
  cases event with
  | publish c slot deliver staged ready parent actual durable => exact ⟨ready,c,parent,actual⟩
  | _ => exact False.elim (published rfl)

theorem unqualified_cannot_publish (event : Step ao wo co ho fo jo semantic o genesis s t)
    (unqualified : s.qualified = false) : t.journal.length = s.journal.length := by
  cases event with
  | publish c slot deliver staged ready parent actual durable =>
    have eq := ready.1
    rw [unqualified] at eq
    cases eq
  | _ => rfl

theorem late_ack_cannot_refresh (s : State) (index : Nat) :
    ({s with reply := some (index+1)} : State).snapshot = s.snapshot ∧
    ({s with reply := some (index+1)} : State).seen = s.seen ∧
    ({s with reply := some (index+1)} : State).qualified = s.qualified := ⟨rfl,rfl,rfl⟩

theorem original_result_unique (run : Run ao wo co ho fo jo semantic o genesis
    (initial custodyStart) s)
    (priorCustody : LlmSourceCustody.Run ao wo co ho fo jo (logicalOwner semantic) genesis (LlmSourceCustody.initial (LlmSourceJoin.initial (LlmAdmissionFloor.initial h))) custodyStart) :
    ∀ r ∈ s.authority.logical.floorState.committed, ∀ other ∈ s.authority.logical.floorState.committed, r.proposal.id = other.proposal.id → r = other :=
  LlmSourceCustody.original_result_unique (actual_custody_composition run priorCustody)

theorem original_reservation_once (safe : LlmAppendHandoff.Safe ho h)
    (run : Run ao wo co ho fo jo semantic o genesis (initial custodyStart) s)
    (priorCustody : LlmSourceCustody.Run ao wo co ho fo jo (logicalOwner semantic) genesis (LlmSourceCustody.initial (LlmSourceJoin.initial (LlmAdmissionFloor.initial h))) custodyStart)
    (priorRun : LlmCheckpointTruncation.Run ao wo co genesis (LlmCheckpointTruncation.initial ao balances) h.logical) (key) :
    (LlmSourceJoin.account s.authority.logical).authority.writes key ≤ 1 :=
  LlmSourceCustody.original_reservation_once safe (actual_custody_composition run priorCustody) priorRun key

theorem unknown_original_hold_retained (safe : LlmAppendHandoff.Safe ho h)
    (run : Run ao wo co ho fo jo semantic o genesis (initial custodyStart) s)
    (priorCustody : LlmSourceCustody.Run ao wo co ho fo jo (logicalOwner semantic) genesis (LlmSourceCustody.initial (LlmSourceJoin.initial (LlmAdmissionFloor.initial h))) custodyStart)
    (priorRun : LlmCheckpointTruncation.Run ao wo co genesis (LlmCheckpointTruncation.initial ao balances) h.logical)
    (source : LlmExecutionReconciliation.State S) (unknownUsage : source.metered = false)
    (binding : ∀ tx state, tx.reservation = originalKey → ao.sourceReady tx state → LlmAccountCommit.OriginalReady originalKey attempt source tx) :
    (LlmSourceJoin.account s.authority.logical).authority.reservations originalKey = none ∧ (LlmSourceJoin.account s.authority.logical).authority.holds originalKey = ao.bound originalKey :=
  LlmSourceCustody.unknown_original_hold_retained safe (actual_custody_composition run priorCustody) priorRun source unknownUsage binding

#print axioms custody_projection
#print axioms actual_custody_composition
#print axioms journal_prefix_step
#print axioms journal_prefix_run
#print axioms journal_alignment
#print axioms fence_monotone
#print axioms outcome_retained
#print axioms staging_has_no_authoritative_effect
#print axioms publication_checks_current_parent
#print axioms unqualified_cannot_publish
#print axioms late_ack_cannot_refresh
#print axioms original_result_unique
#print axioms original_reservation_once
#print axioms unknown_original_hold_retained
end Weaver.LlmCustodyPublication
