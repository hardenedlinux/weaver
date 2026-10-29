import LlmAdmissionFloor
namespace Weaver.LlmSourceJoin
structure Ticket where
  proposal : Weaver.LlmAdmissionFloor.Proposal
  operation : Nat
  intent : Nat
  floor : Weaver.LlmAdmissionFloor.Receipt
  account : Weaver.LlmAccountCommit.Image
  journal : List Weaver.LlmAccountCommit.Record
  worker : Nat
  sourceGeneration : Nat
  sourceQualified : Bool
  qualified : Bool
  sourceRevision : Nat
structure State where
  floorState : Weaver.LlmAdmissionFloor.State
  sourceRevision : Nat
  ticket : Option Ticket
structure Owner where
  authentic : State → Prop
  sourceAllows : Weaver.LlmAdmissionFloor.Proposal → State → Prop

def account (s : State) := s.floorState.logical.logical.logical.core
def current (s : State) (p : Weaver.LlmAdmissionFloor.Proposal) : Ticket :=
  ⟨p,p.id,p.intent,Weaver.LlmAdmissionFloor.current s.floorState,(account s).authority,(account s).journal,(account s).epoch,(account s).sourceGeneration,(account s).sourceQualified,(account s).qualified,s.sourceRevision⟩
def Joined (s : State) (p : Weaver.LlmAdmissionFloor.Proposal) : Prop := s.ticket = some (current s p)
def initial (f : Weaver.LlmAdmissionFloor.State) : State := ⟨f,0,none⟩

inductive Step (ao : Weaver.LlmAccountCommit.Owner) (wo : Weaver.LlmWalActivation.Owner)
    (co : Weaver.LlmCheckpointTruncation.Owner) (ho : Weaver.LlmAppendHandoff.Owner)
    (fo : Weaver.LlmAdmissionFloor.Owner) (o : Owner) (genesis : Weaver.LlmAccountCommit.Image) : State → State → Prop where
  | validate (s p) (qualified : Weaver.LlmAdmissionFloor.Qualified s.floorState)
      (authentic : o.authentic s) (source : o.sourceAllows p s) :
      Step ao wo co ho fo o genesis s {s with ticket := some (current s p)}
  | commit (s next p) (joined : Joined s p) (source : o.sourceAllows p s)
      (actual : Weaver.LlmAdmissionFloor.Step ao wo co ho fo genesis s.floorState next)
      (changed : next.committed.length ≠ s.floorState.committed.length)
      (exact : Weaver.LlmAdmissionFloor.latest next.committed = some ⟨p⟩) :
      Step ao wo co ho fo o genesis s {s with floorState := next, ticket := none}
  | advance (s next) (actual : Weaver.LlmAdmissionFloor.Step ao wo co ho fo genesis s.floorState next)
      (same : next.committed = s.floorState.committed) :
      Step ao wo co ho fo o genesis s {s with floorState := next}
  | sourceChange (s) : Step ao wo co ho fo o genesis s {s with sourceRevision := s.sourceRevision+1}
  | restart (s) : Step ao wo co ho fo o genesis s {s with ticket := none}

inductive Run (ao : Weaver.LlmAccountCommit.Owner) (wo : Weaver.LlmWalActivation.Owner)
    (co : Weaver.LlmCheckpointTruncation.Owner) (ho : Weaver.LlmAppendHandoff.Owner)
    (fo : Weaver.LlmAdmissionFloor.Owner) (o : Owner) (genesis : Weaver.LlmAccountCommit.Image) : State → State → Prop where
  | refl (s) : Run ao wo co ho fo o genesis s s
  | next : Run ao wo co ho fo o genesis a b → Step ao wo co ho fo o genesis b d → Run ao wo co ho fo o genesis a d

theorem floor_projection (event : Step ao wo co ho fo o genesis s t) : Weaver.LlmAdmissionFloor.Run ao wo co ho fo genesis s.floorState t.floorState := by
  cases event with
  | commit next p joined source actual changed exact => exact .next (.refl _) actual
  | advance next actual same => exact .next (.refl _) actual
  | _ => exact .refl _

theorem floor_extend (r : Weaver.LlmAdmissionFloor.Run ao wo co ho fo genesis a b)
    (priorRun : Weaver.LlmAdmissionFloor.Run ao wo co ho fo genesis x a) : Weaver.LlmAdmissionFloor.Run ao wo co ho fo genesis x b := by
  induction r with
  | refl => exact priorRun
  | next prior event ih => exact .next ih event

theorem actual_floor_composition (run : Run ao wo co ho fo o genesis s t)
    (priorRun : Weaver.LlmAdmissionFloor.Run ao wo co ho fo genesis x s.floorState) :
    Weaver.LlmAdmissionFloor.Run ao wo co ho fo genesis x t.floorState := by
  induction run with
  | refl => exact priorRun
  | next prior event ih => exact floor_extend (floor_projection event) ih

theorem final_commit_requires_current_join (event : Step ao wo co ho fo o genesis s t)
    (changed : t.floorState.committed.length ≠ s.floorState.committed.length) :
    ∃ p, Joined s p ∧ o.sourceAllows p s ∧ Weaver.LlmAdmissionFloor.latest t.floorState.committed = some ⟨p⟩ ∧ t.ticket = none := by
  cases event with
  | commit next p joined source actual changed exact => exact ⟨p,joined,source,exact,rfl⟩
  | advance next actual same => exact False.elim (changed (congrArg List.length same))
  | _ => exact False.elim (changed rfl)

theorem changed_source_invalidates_ticket (s : State) (p : Weaver.LlmAdmissionFloor.Proposal) :
    ¬ Joined {s with sourceRevision := s.sourceRevision+1, ticket := some (current s p)} p := by
  intro h
  have eq := congrArg Ticket.sourceRevision (Option.some.inj h)
  simp [current] at eq

theorem changed_account_invalidates_ticket (s t : State) (p : Weaver.LlmAdmissionFloor.Proposal)
    (old : t.ticket = some (current s p)) (changed : (account s).authority ≠ (account t).authority) : ¬ Joined t p := by
  intro h
  have eq := Option.some.inj (old.symm.trans h)
  exact changed (congrArg Ticket.account eq)

theorem changed_worker_invalidates_ticket (s t : State) (p : Weaver.LlmAdmissionFloor.Proposal)
    (old : t.ticket = some (current s p)) (changed : (account s).epoch ≠ (account t).epoch) : ¬ Joined t p := by
  intro h
  have eq := Option.some.inj (old.symm.trans h)
  exact changed (congrArg Ticket.worker eq)

theorem changed_operation_invalidates_ticket (s : State) (p q : Weaver.LlmAdmissionFloor.Proposal)
    (different : p.id ≠ q.id) : ¬ Joined {s with ticket := some (current s p)} q := by
  intro h; exact different (congrArg Ticket.operation (Option.some.inj h))

theorem source_revision_monotone (event : Step ao wo co ho fo o genesis s t) : s.sourceRevision ≤ t.sourceRevision := by
  cases event <;> simp <;> omega

theorem publication_no_financial_effect (event : Step ao wo co ho fo o genesis s t)
    (changed : t.floorState.committed.length ≠ s.floorState.committed.length) :
    (account t).authority = (account s).authority ∧ (account t).journal = (account s).journal := by
  cases event with
  | commit next p joined source actual different exact =>
    have result := Weaver.LlmAdmissionFloor.publication_has_no_financial_effect actual different
    exact ⟨result.1,result.2.1⟩
  | advance next actual same => exact False.elim (changed (congrArg List.length same))
  | _ => exact False.elim (changed rfl)

theorem original_reservation_once (safe : Weaver.LlmAppendHandoff.Safe ho h)
    (run : Run ao wo co ho fo o genesis (initial (Weaver.LlmAdmissionFloor.initial h)) s)
    (priorRun : Weaver.LlmCheckpointTruncation.Run ao wo co genesis (Weaver.LlmCheckpointTruncation.initial ao balances) h.logical) (key) :
    (account s).authority.writes key ≤ 1 :=
  Weaver.LlmAdmissionFloor.original_reservation_once safe (actual_floor_composition run (.refl _)) priorRun key

theorem unknown_original_hold_retained (safe : Weaver.LlmAppendHandoff.Safe ho h)
    (run : Run ao wo co ho fo o genesis (initial (Weaver.LlmAdmissionFloor.initial h)) s)
    (priorRun : Weaver.LlmCheckpointTruncation.Run ao wo co genesis (Weaver.LlmCheckpointTruncation.initial ao balances) h.logical)
    (source : Weaver.LlmExecutionReconciliation.State S) (unknownUsage : source.metered = false)
    (binding : ∀ tx state, tx.reservation = originalKey → ao.sourceReady tx state → Weaver.LlmAccountCommit.OriginalReady originalKey attempt source tx) :
    (account s).authority.reservations originalKey = none ∧ (account s).authority.holds originalKey = ao.bound originalKey :=
  Weaver.LlmAdmissionFloor.unknown_original_hold_retained safe (actual_floor_composition run (.refl _)) priorRun source unknownUsage binding

theorem original_operation_result_unique (run : Run ao wo co ho fo o genesis (initial (Weaver.LlmAdmissionFloor.initial h)) s) :
    ∀ r ∈ s.floorState.committed, ∀ other ∈ s.floorState.committed, r.proposal.id = other.proposal.id → r = other :=
  Weaver.LlmAdmissionFloor.committed_operation_unique (actual_floor_composition run (.refl _))

theorem pending_intent_retained (run : Run ao wo co ho fo o genesis s t) (member : p ∈ s.floorState.pending) : p ∈ t.floorState.pending := by
  induction run with
  | refl => exact member
  | next prior event ih =>
    cases event with
    | commit next p joined source actual changed exact => exact Weaver.LlmAdmissionFloor.pending_intent_retained actual ih
    | advance next actual same => exact Weaver.LlmAdmissionFloor.pending_intent_retained actual ih
    | _ => exact ih

theorem changed_attempt_invalidates_ticket (s : State) (p q : Weaver.LlmAdmissionFloor.Proposal)
    (different : p ≠ q) : ¬ Joined {s with ticket := some (current s p)} q := by
  intro h; exact different (congrArg Ticket.proposal (Option.some.inj h))

#print axioms changed_attempt_invalidates_ticket
#print axioms floor_projection
#print axioms actual_floor_composition
#print axioms final_commit_requires_current_join
#print axioms changed_source_invalidates_ticket
#print axioms changed_account_invalidates_ticket
#print axioms changed_worker_invalidates_ticket
#print axioms changed_operation_invalidates_ticket
#print axioms source_revision_monotone
#print axioms publication_no_financial_effect
#print axioms original_reservation_once
#print axioms unknown_original_hold_retained
#print axioms original_operation_result_unique
#print axioms pending_intent_retained
end Weaver.LlmSourceJoin
