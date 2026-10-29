import LlmSourceJoin
namespace Weaver.LlmSourceCustody
inductive Phase where
  | idle | prepared | armed | determined | closed
  deriving DecidableEq
structure State where
  logical : Weaver.LlmSourceJoin.State
  fence : Nat
  holder : Nat
  intent : Option Weaver.LlmAdmissionFloor.Proposal
  attempt : Option Weaver.LlmAdmissionFloor.Proposal
  phase : Phase
  outcome : Option Weaver.LlmAdmissionFloor.Record
  resolved : Bool
structure Owner where
  intentDurable : Weaver.LlmAdmissionFloor.Proposal → Prop
  armDurable : State → Prop
  fenceDurable : State → Nat → Nat → Prop
  decisionDurable : Weaver.LlmAdmissionFloor.Record → Prop
  authentic : State → Prop
  sameIntent : Weaver.LlmAdmissionFloor.Proposal → Weaver.LlmAdmissionFloor.Proposal → Prop

def initial (s : Weaver.LlmSourceJoin.State) : State := ⟨s,0,0,none,none,.idle,none,true⟩
def Current (s : State) (holder fence : Nat) := holder = s.holder ∧ fence = s.fence

inductive Step (ao : Weaver.LlmAccountCommit.Owner) (wo : Weaver.LlmWalActivation.Owner)
    (co : Weaver.LlmCheckpointTruncation.Owner) (ho : Weaver.LlmAppendHandoff.Owner)
    (fo : Weaver.LlmAdmissionFloor.Owner) (jo : Weaver.LlmSourceJoin.Owner)
    (o : Owner) (genesis : Weaver.LlmAccountCommit.Image) : State → State → Prop where
  | acquire (s p holder fence) (idle : s.phase = .idle) (current : Current s holder fence)
      (durable : o.intentDurable p) :
      Step ao wo co ho fo jo o genesis s {s with intent := some p, attempt := some p, phase := .prepared, resolved := true}
  | rebase (s p original holder fence) (prepared : s.phase = .prepared) (resolved : s.resolved = true)
      (root : s.intent = some original) (key : p.id = original.id ∧ p.intent = original.intent)
      (scope : o.sameIntent original p) (current : Current s holder fence) (durable : o.intentDurable p) :
      Step ao wo co ho fo jo o genesis s {s with attempt := some p}
  | arm (s p holder fence) (prepared : s.phase = .prepared) (resolved : s.resolved = true)
      (attempt : s.attempt = some p) (current : Current s holder fence)
      (joined : Weaver.LlmSourceJoin.Joined s.logical p) (source : jo.sourceAllows p s.logical)
      (durable : o.armDurable s) :
      Step ao wo co ho fo jo o genesis s {s with phase := .armed, resolved := false}
  | commit (s next p holder fence) (armed : s.phase = .armed) (attempt : s.attempt = some p)
      (current : Current s holder fence) (unknown : s.outcome = none)
      (actual : Weaver.LlmSourceJoin.Step ao wo co ho fo jo genesis s.logical next)
      (changed : next.floorState.committed.length ≠ s.logical.floorState.committed.length)
      (exact : Weaver.LlmAdmissionFloor.latest next.floorState.committed = some ⟨p⟩)
      (durable : o.decisionDurable ⟨p⟩) :
      Step ao wo co ho fo jo o genesis s {s with logical := next, phase := .determined, outcome := some ⟨p⟩, resolved := false}
  | transfer (s nextHolder) (active : s.phase ≠ .closed) (notIdle : s.phase ≠ .idle)
      (durable : o.fenceDurable s (s.fence+1) nextHolder) :
      Step ao wo co ho fo jo o genesis s {s with logical := {s.logical with ticket := none}, fence := s.fence+1, holder := nextHolder, phase := (match s.outcome with | none => .prepared | some _ => .determined), resolved := false}
  | resolve (s holder fence) (current : Current s holder fence) (authentic : o.authentic s) :
      Step ao wo co ho fo jo o genesis s {s with resolved := true}
  | restart (s) : Step ao wo co ho fo jo o genesis s {s with logical := {s.logical with ticket := none}, resolved := false}
  | advance (s next) (notArmed : s.phase ≠ .armed)
      (actual : Weaver.LlmSourceJoin.Step ao wo co ho fo jo genesis s.logical next)
      (same : next.floorState.committed = s.logical.floorState.committed) :
      Step ao wo co ho fo jo o genesis s {s with logical := next}
  | close (s r holder fence) (determined : s.phase = .determined) (outcome : s.outcome = some r)
      (resolved : s.resolved = true) (current : Current s holder fence) :
      Step ao wo co ho fo jo o genesis s {s with phase := .closed}

inductive Run (ao : Weaver.LlmAccountCommit.Owner) (wo : Weaver.LlmWalActivation.Owner)
    (co : Weaver.LlmCheckpointTruncation.Owner) (ho : Weaver.LlmAppendHandoff.Owner)
    (fo : Weaver.LlmAdmissionFloor.Owner) (jo : Weaver.LlmSourceJoin.Owner)
    (o : Owner) (genesis : Weaver.LlmAccountCommit.Image) : State → State → Prop where
  | refl (s) : Run ao wo co ho fo jo o genesis s s
  | next : Run ao wo co ho fo jo o genesis a b → Step ao wo co ho fo jo o genesis b d → Run ao wo co ho fo jo o genesis a d

theorem join_projection (event : Step ao wo co ho fo jo o genesis s t) : Weaver.LlmSourceJoin.Run ao wo co ho fo jo genesis s.logical t.logical := by
  cases event with
  | commit next p holder fence armed attempt current unknown actual changed exact durable => exact .next (.refl _) actual
  | advance next notArmed actual same => exact .next (.refl _) actual
  | transfer nextHolder active notIdle durable => exact .next (.refl _) (.restart _)
  | restart => exact .next (.refl _) (.restart _)
  | _ => exact .refl _

theorem join_extend (r : Weaver.LlmSourceJoin.Run ao wo co ho fo jo genesis a b)
    (priorRun : Weaver.LlmSourceJoin.Run ao wo co ho fo jo genesis x a) : Weaver.LlmSourceJoin.Run ao wo co ho fo jo genesis x b := by
  induction r with
  | refl => exact priorRun
  | next prior event ih => exact .next ih event

theorem actual_join_composition (run : Run ao wo co ho fo jo o genesis s t)
    (priorRun : Weaver.LlmSourceJoin.Run ao wo co ho fo jo genesis x s.logical) :
    Weaver.LlmSourceJoin.Run ao wo co ho fo jo genesis x t.logical := by
  induction run with
  | refl => exact priorRun
  | next prior event ih => exact join_extend (join_projection event) ih

theorem final_cas_requires_current_custody (event : Step ao wo co ho fo jo o genesis s t)
    (changed : t.logical.floorState.committed.length ≠ s.logical.floorState.committed.length) :
    s.phase = .armed ∧ s.outcome = none ∧ ∃ p holder fence, s.attempt = some p ∧ Current s holder fence ∧
      Weaver.LlmSourceJoin.Joined s.logical p ∧ jo.sourceAllows p s.logical ∧ t.outcome = some ⟨p⟩ := by
  cases event with
  | commit next p holder fence armed attempt current unknown actual changed exact durable =>
    obtain ⟨q,joined,source,selected,cleared⟩ := Weaver.LlmSourceJoin.final_commit_requires_current_join actual changed
    have eq : q = p := congrArg Weaver.LlmAdmissionFloor.Record.proposal (Option.some.inj (selected.symm.trans exact))
    subst q; exact ⟨armed,unknown,p,holder,fence,attempt,current,joined,source,rfl⟩
  | advance next notArmed actual same => exact False.elim (changed (congrArg List.length same))
  | _ => exact False.elim (changed rfl)

theorem fence_monotone (event : Step ao wo co ho fo jo o genesis s t) : s.fence ≤ t.fence := by
  cases event <;> simp <;> omega

theorem transfer_preserves_original (s : State) (nextHolder : Nat) :
    ({s with logical := {s.logical with ticket := none}, fence := s.fence+1, holder := nextHolder, phase := (match s.outcome with | none => .prepared | some _ => .determined), resolved := false} : State).intent = s.intent ∧
    ({s with logical := {s.logical with ticket := none}, fence := s.fence+1, holder := nextHolder, phase := (match s.outcome with | none => .prepared | some _ => .determined), resolved := false} : State).outcome = s.outcome := ⟨rfl,rfl⟩

theorem old_fence_rejected (s : State) (holder : Nat) : ¬ Current {s with fence := s.fence+1} holder s.fence := by
  intro h; have eq := h.2; change s.fence = s.fence + 1 at eq; omega

theorem determined_outcome_retained (event : Step ao wo co ho fo jo o genesis s t) (known : s.outcome = some r) : t.outcome = some r := by
  cases event with
  | commit next p holder fence armed attempt current unknown actual changed exact durable => rw [known] at unknown; cases unknown
  | _ => exact known

theorem unresolved_cannot_close (s : State) (unknown : s.outcome = none) : ¬ ∃ r, s.outcome = some r := by
  rw [unknown]; simp

theorem source_mutation_blocked_while_armed (event : Step ao wo co ho fo jo o genesis s t)
    (armed : s.phase = .armed) (noPublication : t.logical.floorState.committed = s.logical.floorState.committed) :
    t.logical.sourceRevision = s.logical.sourceRevision := by
  cases event with
  | advance next notArmed actual same => exact False.elim (notArmed armed)
  | commit next p holder fence armed attempt current unknown actual changed exact durable => exact False.elim (changed (congrArg List.length noPublication))
  | _ => rfl

theorem publication_no_financial_effect (event : Step ao wo co ho fo jo o genesis s t)
    (changed : t.logical.floorState.committed.length ≠ s.logical.floorState.committed.length) :
    (Weaver.LlmSourceJoin.account t.logical).authority = (Weaver.LlmSourceJoin.account s.logical).authority ∧
    (Weaver.LlmSourceJoin.account t.logical).journal = (Weaver.LlmSourceJoin.account s.logical).journal := by
  cases event with
  | commit next p holder fence armed attempt current unknown actual changed exact durable => exact Weaver.LlmSourceJoin.publication_no_financial_effect actual changed
  | advance next notArmed actual same => exact False.elim (changed (congrArg List.length same))
  | _ => exact False.elim (changed rfl)

theorem original_reservation_once (safe : Weaver.LlmAppendHandoff.Safe ho h)
    (run : Run ao wo co ho fo jo o genesis (initial (Weaver.LlmSourceJoin.initial (Weaver.LlmAdmissionFloor.initial h))) s)
    (priorRun : Weaver.LlmCheckpointTruncation.Run ao wo co genesis (Weaver.LlmCheckpointTruncation.initial ao balances) h.logical) (key) :
    (Weaver.LlmSourceJoin.account s.logical).authority.writes key ≤ 1 :=
  Weaver.LlmSourceJoin.original_reservation_once safe (actual_join_composition run (.refl _)) priorRun key

theorem unknown_original_hold_retained (safe : Weaver.LlmAppendHandoff.Safe ho h)
    (run : Run ao wo co ho fo jo o genesis (initial (Weaver.LlmSourceJoin.initial (Weaver.LlmAdmissionFloor.initial h))) s)
    (priorRun : Weaver.LlmCheckpointTruncation.Run ao wo co genesis (Weaver.LlmCheckpointTruncation.initial ao balances) h.logical)
    (source : Weaver.LlmExecutionReconciliation.State S) (unknownUsage : source.metered = false)
    (binding : ∀ tx state, tx.reservation = originalKey → ao.sourceReady tx state → Weaver.LlmAccountCommit.OriginalReady originalKey attempt source tx) :
    (Weaver.LlmSourceJoin.account s.logical).authority.reservations originalKey = none ∧ (Weaver.LlmSourceJoin.account s.logical).authority.holds originalKey = ao.bound originalKey :=
  Weaver.LlmSourceJoin.unknown_original_hold_retained safe (actual_join_composition run (.refl _)) priorRun source unknownUsage binding

theorem original_result_unique (run : Run ao wo co ho fo jo o genesis (initial (Weaver.LlmSourceJoin.initial (Weaver.LlmAdmissionFloor.initial h))) s) :
    ∀ r ∈ s.logical.floorState.committed, ∀ other ∈ s.logical.floorState.committed, r.proposal.id = other.proposal.id → r = other :=
  Weaver.LlmSourceJoin.original_operation_result_unique (actual_join_composition run (.refl _))

#print axioms join_projection
#print axioms actual_join_composition
#print axioms final_cas_requires_current_custody
#print axioms fence_monotone
#print axioms transfer_preserves_original
#print axioms old_fence_rejected
#print axioms determined_outcome_retained
#print axioms unresolved_cannot_close
#print axioms source_mutation_blocked_while_armed
#print axioms publication_no_financial_effect
#print axioms original_reservation_once
#print axioms unknown_original_hold_retained
#print axioms original_result_unique
end Weaver.LlmSourceCustody
