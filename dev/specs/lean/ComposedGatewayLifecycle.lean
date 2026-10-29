import AnchoredRecoveryAndEgress

/-! One reachable product from the empty finite ledger. A range is the single
bounded exposure unit of an already journaled complete-message offer. This is
not a second complete-message offer or a TCP transmission model. -/
namespace Weaver.ComposedGatewayLifecycle
open Weaver.LogicalMessageAuthority (update)
open Weaver.AnchoredRecoveryAndEgress

structure Delegation where
  image : Journal.Image
  range : RangeBinding
  ticket : Weaver.FiniteDomainMigration.Ticket
  epoch : Nat
  incarnation : Nat

structure State where
  journal : Journal.State := Journal.initial
  epoch : Nat := 0
  ownerEpoch : Nat := 0
  incarnation : Nat := 0
  ready : Bool := true
  ownerOpen : Bool := true
  sealedRequest : Option Journal.Request := none
  delegated : Nat → Option Delegation := fun _ => none
  accepts : Nat → Nat := fun _ => 0
  exposures : Nat → Nat := fun _ => 0
  -- Unique original driver capability, not an outbox reconstructed on restart.
  -- The exposure counter is observational and is not an execution guard.
  pending : Nat → Bool := fun _ => false

def initial : State := {}
def Ready (s : State) : Prop :=
  s.ready = true ∧ s.journal.online = true ∧ Journal.Recovered s.journal

def CanDelegate (c : Weaver.FiniteDomainMigration.Config) (s : State)
    (range : RangeBinding) (ticket : Weaver.FiniteDomainMigration.Ticket)
    (handleEpoch handleIncarnation : Nat) : Prop :=
  Ready s ∧ s.ownerOpen = true ∧ s.ownerEpoch = s.epoch ∧
  handleEpoch = s.epoch ∧ handleIncarnation = s.incarnation ∧
  s.delegated range.key = none ∧ ClaimBound c s.journal.head.payload range ∧
  Weaver.FiniteDomainMigration.Current s.journal.head.payload ticket ∧
  ticket.root = c.root range.key ∧ range.executor = (ticket.worker, ticket.generation, ticket.fence) ∧
  s.journal.head.payload.restricted (c.history (c.root range.key)) = false ∧
  (s.journal.head.payload.messages range.key).sends = 1 ∧
  (s.journal.head.payload.messages range.key).claimStream = (s.journal.head.payload.messages range.key).stream ∧
  (s.journal.head.payload.messages range.key).retired = false

def accept (s : State) (range : RangeBinding) (ticket : Weaver.FiniteDomainMigration.Ticket) : State :=
  { s with delegated := update s.delegated range.key (some ⟨s.journal.head, range, ticket, s.epoch, s.incarnation⟩)
           accepts := update s.accepts range.key (s.accepts range.key + 1)
           pending := update s.pending range.key true }

/-- Owner restart closes volatile admission. Its durable open/seal, epoch and
range records are NOT cleared. Unknown old buffers can still drain. -/
inductive Step (c : Weaver.FiniteDomainMigration.Config) : State → State → Prop where
  | payload (s command req next) (openOwner : s.ownerOpen = true)
      (commandFresh : s.journal.commands command = none)
      (operationFresh : s.journal.operations req.operation = none)
      (expected : req.expectedHead = s.journal.head.sequence)
      (lineage : req.lineage = s.journal.head.lineage)
      (executed : Weaver.FiniteDomainMigration.Transition c s.journal.head.payload next) :
      Step c s { s with journal := Journal.decided s.journal command req next true }
  | sealOwner (s req) (ready : Ready s) (openOwner : s.ownerOpen = true)
      (fresh : s.journal.operations req.operation = none)
      (expected : req.expectedHead = s.journal.head.sequence)
      (lineage : req.lineage = s.journal.head.lineage)
      (source : req.sourceFence = s.epoch) :
      Step c s { s with ownerOpen := false, sealedRequest := some req }
  | commit (s command req) (online : s.journal.online = true)
      (sealed : s.ownerOpen = false) (exactSeal : s.sealedRequest = some req)
      (commandFresh : s.journal.commands command = none)
      (operationFresh : s.journal.operations req.operation = none)
      (expected : req.expectedHead = s.journal.head.sequence)
      (lineage : req.lineage = s.journal.head.lineage) (source : req.sourceFence = s.epoch) :
      Step c s { s with journal := Journal.decided s.journal command req s.journal.head.payload true, epoch := s.epoch + 1 }
  | abort (s command req) (online : s.journal.online = true)
      (sealed : s.ownerOpen = false) (exactSeal : s.sealedRequest = some req)
      (commandFresh : s.journal.commands command = none)
      (operationFresh : s.journal.operations req.operation = none)
      (expected : req.expectedHead = s.journal.head.sequence)
      (lineage : req.lineage = s.journal.head.lineage) :
      Step c s { s with journal := Journal.decided s.journal command req s.journal.head.payload false }
  | activate (s req receipt callerIncarnation) (ready : Ready s)
      (sealed : s.ownerOpen = false) (exactSeal : s.sealedRequest = some req)
      (stored : s.journal.operations req.operation = some receipt)
      (exact : receipt.request = req) (committed : receipt.committed = true)
      (head : receipt.sequence = s.journal.head.sequence)
      (source : req.sourceFence + 1 = s.epoch) (advance : s.ownerEpoch < s.epoch)
      (currentCaller : callerIncarnation = s.incarnation) :
      Step c s { s with ownerEpoch := s.epoch, ownerOpen := true, sealedRequest := none }
  | restartOwner (s) : Step c s { s with incarnation := s.incarnation + 1, ready := false }
  | recoverOwner (s) (fresh : Journal.Recovered s.journal) : Step c s { s with ready := true }
  | recoverHost (s) (online : s.journal.online = true) :
      Step c s { s with journal := { s.journal with localImage := s.journal.head } }
  | rollbackHost (s image) : Step c s { s with journal := { s.journal with localImage := image } }
  | partition (s) : Step c s { s with journal := { s.journal with online := false } }
  | reconnect (s) : Step c s { s with journal := { s.journal with online := true } }
  | loseReply (s) : Step c s { s with journal := { s.journal with lastLookup := none } }
  | delegate (s range ticket epoch incarnation) (gate : CanDelegate c s range ticket epoch incarnation) :
      Step c s (accept s range ticket)
  | drain (s key record) (stored : s.delegated key = some record) (capability : s.pending key = true) :
      Step c s { s with exposures := update s.exposures key (s.exposures key + 1), pending := update s.pending key false }

inductive Reachable (c : Weaver.FiniteDomainMigration.Config) : State → Prop where
  | init : Reachable c initial
  | next : Reachable c s → Step c s s' → Reachable c s'

structure Invariant (c : Weaver.FiniteDomainMigration.Config) (s : State) : Prop where
  journal : Journal.Invariant c s.journal
  accepts : ∀ k, s.accepts k ≤ 1
  absent : ∀ k, s.delegated k = none → s.accepts k = 0
  exposures : ∀ k, s.exposures k ≤ 1
  exposureBound : ∀ k, s.exposures k ≤ s.accepts k
  recorded : ∀ k d, s.delegated k = some d → s.accepts k = 1 ∧ d.range.key = k ∧
    Weaver.FiniteDomainMigration.Reachable c d.image.payload ∧ ClaimBound c d.image.payload d.range ∧
    d.image.payload.restricted (c.history (c.root k)) = false ∧
    Weaver.FiniteDomainMigration.Current d.image.payload d.ticket ∧
    d.range.executor = (d.ticket.worker, d.ticket.generation, d.ticket.fence)
  pending : ∀ k, s.pending k = true → s.exposures k = 0
  owner : s.ownerOpen = true → s.ownerEpoch = s.epoch ∧ s.sealedRequest = none

theorem initial_invariant (c) : Invariant c initial := by
  refine ⟨Journal.initial_invariant c, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;> simp [initial]

theorem step_preserves (h : Invariant c s) (step : Step c s s') : Invariant c s' := by
  cases step with
  | payload command req next openOwner cf freshOp expected lineage executed =>
    exact ⟨Journal.step_preserves h.journal (.publish _ _ _ _ cf freshOp expected lineage executed),
      h.accepts, h.absent, h.exposures, h.exposureBound, h.recorded, h.pending, h.owner⟩
  | sealOwner req ready openOwner fresh expected lineage source =>
    exact ⟨h.journal, h.accepts, h.absent, h.exposures, h.exposureBound, h.recorded, h.pending, by simp⟩
  | commit command req online sealed exactSeal cf freshOp expected lineage source =>
    exact ⟨Journal.step_preserves h.journal (.publish _ _ _ _ cf freshOp expected lineage (.resumeOldWorker _)),
      h.accepts, h.absent, h.exposures, h.exposureBound, h.recorded, h.pending, by simp [sealed]⟩
  | abort command req online sealed exactSeal cf freshOp expected lineage =>
    exact ⟨Journal.step_preserves h.journal (.abort _ _ _ cf freshOp expected lineage),
      h.accepts, h.absent, h.exposures, h.exposureBound, h.recorded, h.pending, h.owner⟩
  | activate =>
    exact ⟨h.journal, h.accepts, h.absent, h.exposures, h.exposureBound, h.recorded, h.pending, by simp⟩
  | delegate range ticket epoch incarnation gate =>
    have fresh := gate.2.2.2.2.2.1
    have zero := h.absent range.key fresh
    refine ⟨h.journal, ?_, ?_, h.exposures, ?_, ?_, ?_, h.owner⟩
    · intro k; by_cases eq : k = range.key
      · simp [accept, update, eq, zero]
      · simpa [accept, update, eq] using h.accepts k
    · intro k missing; by_cases eq : k = range.key
      · simp [accept, update, eq] at missing
      · exact (by simpa [accept, update, eq] using h.absent k (by simpa [accept, update, eq] using missing))
    · intro k; by_cases eq : k = range.key
      · simpa [accept, update, eq, zero] using h.exposures range.key
      · simpa [accept, update, eq] using h.exposureBound k
    · intro k d stored; by_cases eq : k = range.key
      · subst k
        have same : d = ⟨s.journal.head, range, ticket, s.epoch, s.incarnation⟩ := by simpa [accept, update] using stored.symm
        subst d
        exact ⟨by simp [accept, update, zero], rfl, h.journal.payload,
          gate.2.2.2.2.2.2.1, gate.2.2.2.2.2.2.2.2.2.2.1,
          gate.2.2.2.2.2.2.2.1, gate.2.2.2.2.2.2.2.2.2.1⟩
      · exact (by simpa [accept, update, eq] using h.recorded k d (by simpa [accept, update, eq] using stored))
    · intro k pending; by_cases eq : k = range.key
      · subst k
        have bound := h.exposureBound range.key
        change s.exposures range.key = 0
        omega
      · exact h.pending k (by simpa [accept, update, eq] using pending)
  | drain key record stored capability =>
    have once := h.pending key capability
    have positive := (h.recorded key record stored).1
    refine ⟨h.journal, h.accepts, h.absent, ?_, ?_, h.recorded, ?_, h.owner⟩
    · intro k; by_cases eq : k = key
      · simp [update, eq, once]
      · simpa [update, eq] using h.exposures k
    · intro k; by_cases eq : k = key
      · simp [update, eq, once, positive]
      · simpa [update, eq] using h.exposureBound k
    · intro k pending; by_cases eq : k = key
      · simp [update, eq] at pending
      · simpa [update, eq] using h.pending k (by simpa [update, eq] using pending)
  | recoverHost online =>
    exact ⟨Journal.step_preserves h.journal (.recover _ online), h.accepts, h.absent, h.exposures, h.exposureBound, h.recorded, h.pending, h.owner⟩
  | rollbackHost image =>
    exact ⟨Journal.step_preserves h.journal (.restoreImage _ image), h.accepts, h.absent, h.exposures, h.exposureBound, h.recorded, h.pending, h.owner⟩
  | partition =>
    exact ⟨Journal.step_preserves h.journal (.partition _), h.accepts, h.absent, h.exposures, h.exposureBound, h.recorded, h.pending, h.owner⟩
  | reconnect =>
    exact ⟨Journal.step_preserves h.journal (.reconnect _), h.accepts, h.absent, h.exposures, h.exposureBound, h.recorded, h.pending, h.owner⟩
  | loseReply =>
    exact ⟨Journal.step_preserves h.journal (.lostReply _), h.accepts, h.absent, h.exposures, h.exposureBound, h.recorded, h.pending, h.owner⟩
  | _ => exact ⟨h.journal, h.accepts, h.absent, h.exposures, h.exposureBound, h.recorded, h.pending, h.owner⟩

theorem reachable_invariant (h : Reachable c s) : Invariant c s := by
  induction h with
  | init => exact initial_invariant c
  | next _ step ih => exact step_preserves ih step

theorem ledger_projection (step : Step c s s') :
    Weaver.FiniteDomainMigration.Transition c s.journal.head.payload s'.journal.head.payload := by
  cases step with
  | payload command req next openOwner cf freshOp expected lineage executed => exact executed
  | _ => exact .resumeOldWorker _

theorem original_claim_and_history_survive (step : Step c s s')
    (claim : (s.journal.head.payload.messages k).claimed = true)
    (history : (s.journal.head.payload.messages k).history = true) :
    (s'.journal.head.payload.messages k).claimed = true ∧
    (s'.journal.head.payload.messages k).claimToken = (s.journal.head.payload.messages k).claimToken ∧
    (s'.journal.head.payload.messages k).claimStream = (s.journal.head.payload.messages k).claimStream ∧
    (s'.journal.head.payload.messages k).history = true :=
  Weaver.FiniteDomainMigration.claim_and_history_survive (ledger_projection step) claim history

theorem original_executor_survives (step : Step c s s')
    (claim : (s.journal.head.payload.messages k).claimed = true) :
    s'.journal.head.payload.claimOwner k = s.journal.head.payload.claimOwner k :=
  Weaver.FiniteDomainMigration.claim_executor_stamp_is_sticky (ledger_projection step) claim

theorem restrictive_history_survives (step : Step c s s') (hr : s.journal.head.payload.restricted b = true) :
    s'.journal.head.payload.restricted b = true :=
  Weaver.FiniteDomainMigration.history_account_is_sticky (ledger_projection step) hr

theorem end_to_end_conservation (h : Reachable c s) (b : Nat) :
    Weaver.FiniteDomainMigration.booked c s.journal.head.payload b ≤ c.capacity b :=
  Weaver.FiniteDomainMigration.finite_budget_bound (reachable_invariant h).journal.payload b

theorem end_to_end_nonce_claim_offer_bound (h : Reachable c s) (k token : Nat) :
    (s.journal.head.payload.messages k).consumes token ≤ 1 ∧
    (s.journal.head.payload.messages k).claims ≤ 1 ∧
    (s.journal.head.payload.messages k).sends ≤ 1 := by
  have payload := (reachable_invariant h).journal.payload
  exact ⟨((Weaver.FiniteDomainMigration.reachable_invariant payload).messages k).1 token,
    Weaver.FiniteDomainMigration.per_message_affinity payload k⟩

theorem end_to_end_free_held_charged (h : Reachable c s) (b : Nat) :
    c.capacity b - Weaver.FiniteDomainMigration.booked c s.journal.head.payload b +
      Weaver.FiniteDomainMigration.sumKeys c.keys (Weaver.FiniteDomainMigration.heldCost c s.journal.head.payload b) +
      Weaver.FiniteDomainMigration.sumKeys c.keys (Weaver.FiniteDomainMigration.chargedCost c s.journal.head.payload b) = c.capacity b :=
  Weaver.FiniteDomainMigration.finite_free_held_charged_conservation (reachable_invariant h).journal.payload b

theorem accepted_range_retains_admission (h : Reachable c s) (stored : s.delegated k = some d) :
    ClaimBound c d.image.payload d.range ∧ d.image.payload.restricted (c.history (c.root k)) = false ∧
    s.accepts k = 1 ∧ s.exposures k ≤ 1 := by
  have hr := (reachable_invariant h).recorded k d stored
  exact ⟨hr.2.2.2.1, hr.2.2.2.2.1, hr.1, (reachable_invariant h).exposures k⟩

theorem accepted_range_retains_original_executor (h : Reachable c s) (stored : s.delegated k = some d) :
    Weaver.FiniteDomainMigration.Current d.image.payload d.ticket ∧
    d.image.payload.claimOwner d.range.key = some (d.ticket.worker, d.ticket.generation, d.ticket.fence) := by
  have hr := (reachable_invariant h).recorded k d stored
  have owner := hr.2.2.2.1.2.2.2.1
  rw [hr.2.2.2.2.2.2] at owner
  exact ⟨hr.2.2.2.2.2.1, owner⟩

theorem restricted_account_blocks_delegate (restricted : s.journal.head.payload.restricted (c.history (c.root range.key)) = true) :
    ¬ CanDelegate c s range ticket epoch incarnation := by
  intro gate
  have allowed := gate.2.2.2.2.2.2.2.2.2.2.1
  simp_all

theorem restart_cannot_replay_range (s : State) :
    ¬ CanDelegate c { s with incarnation := s.incarnation + 1, ready := false } range ticket epoch incarnation := by
  simp [CanDelegate, Ready]

theorem old_incarnation_cannot_delegate (old : inc < s.incarnation) :
    ¬ CanDelegate c s range ticket epoch inc := by
  intro gate
  have same := gate.2.2.2.2.1
  omega

inductive Steps (c : Weaver.FiniteDomainMigration.Config) : State → State → Prop where
  | refl : Steps c s s
  | tail : Steps c s t → Step c t u → Steps c s u

theorem original_claim_survives_trace (trace : Steps c s t)
    (claim : (s.journal.head.payload.messages k).claimed = true)
    (history : (s.journal.head.payload.messages k).history = true) :
    (t.journal.head.payload.messages k).claimed = true ∧
    (t.journal.head.payload.messages k).claimToken = (s.journal.head.payload.messages k).claimToken ∧
    (t.journal.head.payload.messages k).claimStream = (s.journal.head.payload.messages k).claimStream ∧
    (t.journal.head.payload.messages k).history = true ∧
    t.journal.head.payload.claimOwner k = s.journal.head.payload.claimOwner k := by
  induction trace with
  | refl => exact ⟨claim, rfl, rfl, history, rfl⟩
  | tail trace step ih =>
    have next := original_claim_and_history_survive step ih.1 ih.2.2.2.1
    exact ⟨next.1, next.2.1.trans ih.2.1, next.2.2.1.trans ih.2.2.1, next.2.2.2,
      (original_executor_survives step ih.1).trans ih.2.2.2.2⟩

theorem restrictive_history_survives_trace (trace : Steps c s t)
    (history : s.journal.head.payload.restricted b = true) :
    t.journal.head.payload.restricted b = true := by
  induction trace with
  | refl => exact history
  | tail trace step ih => exact restrictive_history_survives step ih

theorem range_record_is_immutable (step : Step c s s') (old : s.delegated k = some d) :
    s'.delegated k = some d := by
  cases step with
  | delegate range ticket epoch incarnation gate =>
    by_cases eq : k = range.key
    · subst k
      have fresh := gate.2.2.2.2.2.1
      simp_all
    · simpa [accept, update, eq] using old
  | _ => exact old

theorem recorded_range_cannot_be_replayed (old : s.delegated range.key = some d) :
    ¬ CanDelegate c s range ticket epoch incarnation := by
  intro gate
  have fresh := gate.2.2.2.2.2.1
  simp_all

theorem activation_has_exact_committed_seal (step : Step c s s')
    (closed : s.ownerOpen = false) (opened : s'.ownerOpen = true) :
    ∃ req receipt, s.sealedRequest = some req ∧
      s.journal.operations req.operation = some receipt ∧ receipt.request = req ∧
      receipt.committed = true ∧ receipt.sequence = s.journal.head.sequence ∧
      Journal.Recovered s.journal ∧ req.sourceFence + 1 = s.epoch := by
  cases step with
  | activate req receipt caller ready sealed exactSeal stored exact committed head source advance currentCaller =>
    exact ⟨req, receipt, exactSeal, stored, exact, committed, head, ready.2.2, source⟩
  | _ => simp_all [accept]

theorem migration_advance_has_matching_seal (step : Step c s s') (advanced : s.epoch < s'.epoch) :
    ∃ req, s.sealedRequest = some req ∧ req.expectedHead = s.journal.head.sequence ∧
      req.lineage = s.journal.head.lineage ∧ req.sourceFence = s.epoch ∧
      s.journal.operations req.operation = none := by
  cases step with
  | commit command req online sealed exactSeal cf freshOp expected lineage source =>
    exact ⟨req, exactSeal, expected, lineage, source, freshOp⟩
  | _ => simp_all [accept]

#print axioms reachable_invariant
#print axioms end_to_end_conservation
#print axioms end_to_end_free_held_charged
#print axioms end_to_end_nonce_claim_offer_bound
#print axioms accepted_range_retains_original_executor
#print axioms original_claim_survives_trace
#print axioms restrictive_history_survives_trace
#print axioms range_record_is_immutable
#print axioms activation_has_exact_committed_seal
#print axioms migration_advance_has_matching_seal
#print axioms accepted_range_retains_admission
end Weaver.ComposedGatewayLifecycle
