-- SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
--
-- SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

import FiniteDomainMigration

/-! Orthogonal recovery and physical-boundary contracts. The external journal,
transport owner and receiver survive host snapshot rollback by explicit premise.
No atomic database/socket operation or source refinement theorem is asserted. -/
namespace Weaver.AnchoredRecoveryAndEgress
open Weaver.LogicalMessageAuthority (update)

namespace Journal
structure Request where
  operation : Nat
  expectedHead : Nat
  lineage : Nat
  root : Nat
  target : Nat
  sourceFence : Nat
  semanticBinding : Nat
  deriving DecidableEq

structure Image where
  sequence : Nat := 0
  payload : Weaver.FiniteDomainMigration.Ledger := Weaver.FiniteDomainMigration.empty
  lineage : Nat := 0

structure Receipt where
  request : Request
  sequence : Nat
  committed : Bool

structure State where
  head : Image := {}
  localImage : Image := {}
  operations : Nat → Option Receipt := fun _ => none
  commands : Nat → Option Receipt := fun _ => none
  decisions : Nat → Nat := fun _ => 0
  online : Bool := true
  sendReferences : Nat := 0
  lastLookup : Option Receipt := none

def initial : State := {}
def Recovered (s : State) : Prop := s.online = true ∧ s.localImage = s.head

def decided (s : State) (command : Nat) (req : Request) (payload : Weaver.FiniteDomainMigration.Ledger)
    (committed : Bool) : State :=
  let receipt : Receipt := ⟨req, s.head.sequence + 1, committed⟩
  { s with
    head := ⟨s.head.sequence + 1, payload, s.head.lineage⟩
    operations := update s.operations req.operation (some receipt)
    commands := update s.commands command (some receipt)
    decisions := update s.decisions req.operation (s.decisions req.operation + 1) }

inductive Step (c : Weaver.FiniteDomainMigration.Config) : State → State → Prop where
  | publish (s command req next) (commandFresh : s.commands command = none)
      (operationFresh : s.operations req.operation = none)
      (expected : req.expectedHead = s.head.sequence) (lineage : req.lineage = s.head.lineage)
      (executed : Weaver.FiniteDomainMigration.Transition c s.head.payload next) :
      Step c s (decided s command req next true)
  | abort (s command req) (commandFresh : s.commands command = none)
      (operationFresh : s.operations req.operation = none)
      (expected : req.expectedHead = s.head.sequence) (lineage : req.lineage = s.head.lineage) :
      Step c s (decided s command req s.head.payload false)
  | rollbackHost (s old : State) : Step c s { s with localImage := old.localImage, lastLookup := old.lastLookup }
  | restoreImage (s) (old : Image) : Step c s { s with localImage := old }
  | recover (s) (online : s.online = true) : Step c s { s with localImage := s.head }
  | partition (s) : Step c s { s with online := false }
  | reconnect (s) : Step c s { s with online := true }
  | lostReply (s) : Step c s { s with lastLookup := none }
  | lookup (s req receipt) (online : s.online = true)
      (stored : s.operations req.operation = some receipt) (exact : receipt.request = req) :
      Step c s { s with lastLookup := some receipt }

inductive Reachable (c : Weaver.FiniteDomainMigration.Config) : State → Prop where
  | init : Reachable c initial
  | next : Reachable c s → Step c s s' → Reachable c s'

structure Invariant (c : Weaver.FiniteDomainMigration.Config) (s : State) : Prop where
  payload : Weaver.FiniteDomainMigration.Reachable c s.head.payload
  decisions : ∀ op, s.decisions op ≤ 1
  references : s.sendReferences = 0
  absent : ∀ op, s.operations op = none → s.decisions op = 0

theorem initial_invariant (c) : Invariant c initial := by
  exact ⟨.init, by simp [initial], rfl, by simp [initial]⟩

theorem step_preserves (h : Invariant c s) (step : Step c s s') : Invariant c s' := by
  cases step with
  | publish command req next commandFresh operationFresh expected lineage executed =>
    have counterFresh := h.absent req.operation operationFresh
    refine ⟨.next h.payload executed, ?_, h.references, ?_⟩
    · intro op
      by_cases eq : op = req.operation
      · simp [decided, update, eq, counterFresh]
      · simpa [decided, update, eq] using h.decisions op
    · intro op missing
      by_cases eq : op = req.operation
      · simp [decided, update, eq] at missing
      · have old : s.operations op = none := by simpa [decided, update, eq] using missing
        simpa [decided, update, eq] using h.absent op old
  | abort command req commandFresh operationFresh expected lineage =>
    have counterFresh := h.absent req.operation operationFresh
    refine ⟨h.payload, ?_, h.references, ?_⟩
    · intro op
      by_cases eq : op = req.operation
      · simp [decided, update, eq, counterFresh]
      · simpa [decided, update, eq] using h.decisions op
    · intro op missing
      by_cases eq : op = req.operation
      · simp [decided, update, eq] at missing
      · have old : s.operations op = none := by simpa [decided, update, eq] using missing
        simpa [decided, update, eq] using h.absent op old
  | _ => exact ⟨h.payload, h.decisions, h.references, h.absent⟩

theorem reachable_invariant (h : Reachable c s) : Invariant c s := by
  induction h with
  | init => exact initial_invariant c
  | next _ step ih => exact step_preserves ih step

theorem operation_decided_at_most_once (h : Reachable c s) (op : Nat) : s.decisions op ≤ 1 :=
  (reachable_invariant h).decisions op

theorem operation_receipt_is_immutable (step : Step c s s') (old : s.operations op = some receipt) :
    s'.operations op = some receipt := by
  cases step with
  | publish command req next commandFresh operationFresh expected lineage executed =>
    by_cases eq : op = req.operation
    · subst op; simp_all
    · simpa [decided, update, eq] using old
  | abort command req commandFresh operationFresh expected lineage =>
    by_cases eq : op = req.operation
    · subst op; simp_all
    · simpa [decided, update, eq] using old
  | _ => exact old

theorem recovered_payload_retains_finite_invariants (h : Reachable c s) (fresh : Recovered s) :
    Weaver.FiniteDomainMigration.Invariant c s.localImage.payload := by
  have hr := fresh.2
  rw [hr]
  exact Weaver.FiniteDomainMigration.reachable_invariant (reachable_invariant h).payload

theorem recovered_budget_conservation (h : Reachable c s) (fresh : Recovered s) (b : Nat) :
    c.capacity b - Weaver.FiniteDomainMigration.booked c s.localImage.payload b +
      Weaver.FiniteDomainMigration.sumKeys c.keys (Weaver.FiniteDomainMigration.heldCost c s.localImage.payload b) +
      Weaver.FiniteDomainMigration.sumKeys c.keys (Weaver.FiniteDomainMigration.chargedCost c s.localImage.payload b) = c.capacity b := by
  rw [fresh.2]
  exact Weaver.FiniteDomainMigration.finite_free_held_charged_conservation (reachable_invariant h).payload b

theorem stale_image_cannot_be_recovered (s : State) (old : Image) (stale : old.sequence < s.head.sequence) :
    ¬ Recovered { s with localImage := old } := by
  intro hh
  have same := congrArg Image.sequence hh.2
  simp only at same
  omega

theorem anchor_outage_blocks_recovery (s : State) : ¬ Recovered { s with online := false } := by
  simp [Recovered]

theorem lookup_does_not_create_send_reference (h : Reachable c s) : s.sendReferences = 0 :=
  (reachable_invariant h).references

theorem host_only_check_cannot_distinguish (check : Image → Bool) (image : Image)
    (oldHead newHead : Image) :
    check ({ initial with head := oldHead, localImage := image } : State).localImage =
      check ({ initial with head := newHead, localImage := image } : State).localImage := rfl
end Journal

namespace Egress
structure State where
  anchorEpoch : Nat := 0
  anchorOnline : Bool := true
  hostEpoch : Nat := 0
  handleEpoch : Nat := 0
  ownerEpoch : Nat := 0
  ownerOpen : Bool := true
  accepted : Bool := false
  bufferEpoch : Nat := 0
  emitted : Bool := false
  wireEmissions : Nat := 0
  receiverEpoch : Nat := 0
  receiverApplied : Bool := false
  applications : Nat := 0

def initial : State := {}
def CanHandoff (s : State) : Prop :=
  s.anchorOnline = true ∧ s.hostEpoch = s.anchorEpoch ∧ s.ownerOpen = true ∧
  s.ownerEpoch = s.anchorEpoch ∧ s.handleEpoch = s.ownerEpoch ∧ s.accepted = false

def CanApply (s : State) : Prop :=
  s.emitted = true ∧ s.bufferEpoch = s.receiverEpoch ∧ s.receiverApplied = false

/-- Seal and handoff serialize at the independent actual transport owner.
Accepted buffers may drain after seal. Receiver fencing constrains applications,
not disclosure or wire arrival. The model has one original claimed range. -/
inductive Step : State → State → Prop where
  | handoff (s) (guard : CanHandoff s) : Step s { s with accepted := true, bufferEpoch := s.handleEpoch }
  | seal (s) : Step s { s with ownerOpen := false }
  | publishMigration (s) (sealed : s.ownerOpen = false) : Step s { s with anchorEpoch := s.anchorEpoch + 1 }
  | activate (s) (sealed : s.ownerOpen = false) (online : s.anchorOnline = true)
      (advanced : s.ownerEpoch < s.anchorEpoch) :
      Step s { s with ownerEpoch := s.anchorEpoch, ownerOpen := true }
  | recoverHost (s) (online : s.anchorOnline = true) : Step s { s with hostEpoch := s.anchorEpoch }
  | rollbackHost (s epoch) : Step s { s with hostEpoch := epoch }
  | partition (s) : Step s { s with anchorOnline := false }
  | reconnect (s) : Step s { s with anchorOnline := true }
  | drain (s) (accepted : s.accepted = true) (once : s.emitted = false) :
      Step s { s with emitted := true, wireEmissions := s.wireEmissions + 1 }
  | receiverBarrier (s) : Step s { s with receiverEpoch := s.anchorEpoch }
  | applyAtReceiver (s) (guard : CanApply s) :
      Step s { s with receiverApplied := true, applications := s.applications + 1 }
  | lostReply (s) : Step s s

inductive Reachable : State → Prop where
  | init : Reachable initial
  | next : Reachable s → Step s s' → Reachable s'

def Safe (s : State) : Prop :=
  s.wireEmissions ≤ (if s.emitted then 1 else 0) ∧
  (s.emitted = true → s.accepted = true) ∧
  s.applications ≤ (if s.receiverApplied then 1 else 0) ∧
  (s.ownerOpen = true → s.ownerEpoch = s.anchorEpoch)

theorem initial_safe : Safe initial := by simp [Safe, initial]

theorem step_preserves (h : Safe s) (step : Step s s') : Safe s' := by
  rcases h with ⟨wire, emitted, applications, owner⟩
  cases step <;> simp_all [Safe, CanHandoff, CanApply]

theorem reachable_safe (h : Reachable s) : Safe s := by
  induction h with
  | init => exact initial_safe
  | next _ step ih => exact step_preserves ih step

theorem accepted_range_cannot_be_reaccepted (accepted : s.accepted = true) : ¬ CanHandoff s := by
  simp [CanHandoff, accepted]

theorem sealed_owner_rejects_held_handle (s : State) : ¬ CanHandoff { s with ownerOpen := false } := by
  simp [CanHandoff]

theorem new_epoch_rejects_old_handle (s : State) (old : s.handleEpoch < s.anchorEpoch) : ¬ CanHandoff s := by
  intro h
  have equal := h.2.2.2.2.1.trans h.2.2.2.1
  omega

theorem seal_does_not_retract_accepted_buffer (s : State) (accepted : s.accepted = true)
    (notEmitted : s.emitted = false) :
    Step { s with ownerOpen := false }
      { s with ownerOpen := false, emitted := true, wireEmissions := s.wireEmissions + 1 } :=
  .drain _ accepted notEmitted

theorem post_seal_wire_emission_is_reachable :
    ∃ s, Reachable s ∧ s.ownerOpen = false ∧ s.wireEmissions = 1 := by
  let a : State := { initial with accepted := true, bufferEpoch := 0 }
  have ha : Reachable a := .next .init (.handoff initial (by simp [CanHandoff, initial]))
  have hs : Reachable { a with ownerOpen := false } := .next ha (.seal a)
  exact ⟨_, .next hs (.drain _ rfl rfl), rfl, rfl⟩

theorem receiver_fence_rejects_old_buffer (old : s.bufferEpoch < s.receiverEpoch) : ¬ CanApply s := by
  intro h
  have same := h.2.1
  omega

theorem per_range_wire_bound (h : Reachable s) : s.wireEmissions ≤ 1 := by
  have hw := (reachable_safe h).1
  split at hw <;> omega

theorem receiver_application_bound (h : Reachable s) : s.applications ≤ 1 := by
  have ha := (reachable_safe h).2.2.1
  split at ha <;> omega
end Egress

structure RangeBinding where
  key : Nat
  token : Nat
  executor : Nat × Nat × Nat

def ClaimBound (c : Weaver.FiniteDomainMigration.Config)
    (ledger : Weaver.FiniteDomainMigration.Ledger) (range : RangeBinding) : Prop :=
  range.key ∈ c.keys ∧ (ledger.messages range.key).claimed = true ∧
  (ledger.messages range.key).claimToken = range.token ∧
  ledger.claimOwner range.key = some range.executor ∧ (ledger.messages range.key).reserved = true

/-- Refinement target for a real final-owner acceptance. Concrete authentication,
range/content bounds, Cedar admission and driver mediation are additional
source premises, not a fabricated local Boolean. -/
inductive ProtectedHandoff (c : Weaver.FiniteDomainMigration.Config) (j : Journal.State)
    (e : Egress.State) (range : RangeBinding) : Egress.State → Prop where
  | accept (recovered : Journal.Recovered j) (claim : ClaimBound c j.head.payload range)
      (gate : Egress.CanHandoff e) :
      ProtectedHandoff c j e range { e with accepted := true, bufferEpoch := e.handleEpoch }

theorem protected_handoff_requires_original_claim (h : ProtectedHandoff c j e range out) :
    Journal.Recovered j ∧ ClaimBound c j.head.payload range ∧ Egress.CanHandoff e := by
  cases h with
  | accept recovered claim gate => exact ⟨recovered, claim, gate⟩

theorem recovered_claim_is_exact (recovered : Journal.Recovered j)
    (claim : ClaimBound c j.head.payload range) : ClaimBound c j.localImage.payload range := by
  rw [recovered.2]
  exact claim

/-- The seal precedes the anchored decision; these are logical projections
of one journal publication, not an atomic database/socket transaction. The
actual request-to-transition projection and actor durability need qualification. -/
theorem joint_publication_preserves (hj : Journal.Invariant c j) (he : Egress.Safe e)
    (commandFresh : j.commands command = none) (operationFresh : j.operations req.operation = none)
    (expected : req.expectedHead = j.head.sequence)
    (lineage : req.lineage = j.head.lineage)
    (executed : Weaver.FiniteDomainMigration.Transition c j.head.payload next)
    (sealed : e.ownerOpen = false) :
    Journal.Invariant c (Journal.decided j command req next true) ∧
    Egress.Safe { e with anchorEpoch := e.anchorEpoch + 1 } := by
  exact ⟨Journal.step_preserves hj (.publish _ _ _ _ commandFresh operationFresh expected lineage executed),
    Egress.step_preserves he (.publishMigration _ sealed)⟩

theorem same_epoch_seal_cannot_reopen (e : Egress.State)
    (same : e.ownerEpoch = e.anchorEpoch) : ¬ e.ownerEpoch < e.anchorEpoch := by omega

theorem new_reference_is_not_created_by_status (s : Journal.State) :
    ({ s with localImage := s.head } : Journal.State).sendReferences = s.sendReferences := rfl

#print axioms Journal.reachable_invariant
#print axioms Journal.recovered_budget_conservation
#print axioms Journal.operation_receipt_is_immutable
#print axioms Egress.reachable_safe
#print axioms Egress.post_seal_wire_emission_is_reachable
#print axioms joint_publication_preserves
#print axioms protected_handoff_requires_original_claim
end Weaver.AnchoredRecoveryAndEgress
