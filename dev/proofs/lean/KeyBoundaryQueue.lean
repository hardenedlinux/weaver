-- SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
--
-- SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

import ProtectedSignerRelease
namespace Weaver.KeyBoundaryQueue
open Weaver.LogicalMessageAuthority (update)
structure Handle where
  epoch : Nat
  serviceEpoch : Nat
  voter : Nat
  incarnation : Nat
  deriving DecidableEq
structure Ticket where
  requestId : Nat
  statement : Weaver.ProtectedSignerRelease.Request
  handleId : Nat
  epoch : Nat
  deriving DecidableEq
structure KeyOwner where
  isolationValid : Nat → Nat → Nat → Nat → Prop
  floorValid : Nat → Nat → Nat → Prop
  activationValid : Nat → Nat → Weaver.ProtectedSignerRelease.State → Prop
  resultValid : Ticket → Prop
structure State where
  base : Weaver.ProtectedSignerRelease.State := Weaver.ProtectedSignerRelease.initial
  epoch : Nat := 0
  enabled : Bool := false
  handles : Nat → Option Handle := fun _ => none
  usedTickets : Nat → Bool := fun _ => false
  queued : Nat → Option Ticket := fun _ => none
  running : Nat → Option Ticket := fun _ => none
  completed : Nat → Option Ticket := fun _ => none
  isolation : Option Nat := none
  barrierKnown : Bool := false
  floorKnown : Bool := false
  produced : List Ticket := []
  exports : List Ticket := []
def initial : State := {}
def LiveHandle (s : State) (t : Ticket) : Prop :=
  t.epoch = s.epoch ∧ s.handles t.handleId = some ⟨s.epoch,s.base.epoch,t.statement.voter,s.base.base.incarnation t.statement.voter⟩
def CompletionSafe (s : State) : Prop := ∀ t, t ∈ s.exports → t ∈ s.produced
def ExportReleased (s : State) : Prop := ∀ t, t ∈ s.exports → t.statement ∈ s.base.released
variable {c : Weaver.FiniteDomainMigration.Config} {m : Weaver.FiniteStreamManifest.Manifest c}
  {p : Weaver.WriterSettlementClosure.Profile c m} {lineage root namespaceId : Nat}
  {owner : Weaver.GateConsumptionPersistence.EvidenceOwner} {projectionStore : Weaver.AnchorBrokerCommit.RootOwner}
  {family : Weaver.AnchorReconfiguration.Family} {store : Weaver.AnchorReconfiguration.Store} {signerOwner : Weaver.ProtectedSignerRelease.SignerOwner}
  {keyOwner : KeyOwner} {eligible : Weaver.AnchorReconfiguration.Scope → Nat → Prop}
inductive Step (c : Weaver.FiniteDomainMigration.Config) (m : Weaver.FiniteStreamManifest.Manifest c)
    (p : Weaver.WriterSettlementClosure.Profile c m) (lineage root namespaceId : Nat)
    (owner : Weaver.GateConsumptionPersistence.EvidenceOwner) (projectionStore : Weaver.AnchorBrokerCommit.RootOwner)
    (family : Weaver.AnchorReconfiguration.Family) (store : Weaver.AnchorReconfiguration.Store) (signerOwner : Weaver.ProtectedSignerRelease.SignerOwner)
    (keyOwner : KeyOwner) (eligible : Weaver.AnchorReconfiguration.Scope → Nat → Prop) : State → State → Prop where
  | parentEvent (s next) (event : Weaver.ProtectedSignerRelease.Step c m p lineage root namespaceId owner projectionStore family store signerOwner eligible s.base next)
      (noRelease : next.released = s.base.released) (sameSession : next.epoch = s.base.epoch) :
      Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner eligible s {s with base := next}
  | issueHandle (s handleId voter) (live : s.enabled = true) (qualified : s.base.qualified = true)
      (unused : s.handles handleId = none) :
      Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner eligible s {s with
        handles := update s.handles handleId (some ⟨s.epoch,s.base.epoch,voter,s.base.base.incarnation voter⟩)}
  | enqueue (s job t) (live : s.enabled = true) (handle : LiveHandle s t)
      (durable : s.base.committed t.requestId = some t.statement) (observed : s.base.observed t.requestId = some t.statement)
      (current : Weaver.ProtectedSignerRelease.Current (root := root) s.base t.statement) (unused : s.usedTickets job = false) :
      Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner eligible s {s with
        queued := update s.queued job (some t), usedTickets := update s.usedTickets job true}
  | start (s job t) (held : s.queued job = some t) (live : s.enabled = true) (handle : LiveHandle s t)
      (current : Weaver.ProtectedSignerRelease.Current (root := root) s.base t.statement) :
      Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner eligible s {s with
        queued := update s.queued job none, running := update s.running job (some t)}
  -- Late device completion remains inside the inaccessible mediated boundary.
  | complete (s job t) (running : s.running job = some t) (authentic : keyOwner.resultValid t) :
      Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner eligible s {s with
        running := update s.running job none, completed := update s.completed job (some t), produced := s.produced ++ [t]}
  | emit (s job t) (computed : s.completed job = some t) (live : s.enabled = true) (handle : LiveHandle s t)
      (durable : s.base.committed t.requestId = some t.statement) (observed : s.base.observed t.requestId = some t.statement)
      (qualified : s.base.qualified = true) (current : Weaver.ProtectedSignerRelease.Current (root := root) s.base t.statement)
      (member : eligible t.statement.record.scope t.statement.voter) (ready : s.base.base.ready t.statement.voter = true)
      (notRetired : s.base.base.retired t.statement.voter = false)
      (promise : t.statement.history <+: s.base.base.protectedHistory t.statement.voter) :
      Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner eligible s {s with
        base := {s.base with released := s.base.released ++ [t.statement]}, exports := s.exports ++ [t]}
  | close (s) : Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner eligible s {s with
      enabled := false, isolation := none, barrierKnown := false, floorKnown := false}
  | isolate (s) (closed : s.enabled = false) (authentic : keyOwner.isolationValid root s.epoch s.base.epoch (s.epoch + 1)) :
      Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner eligible s {s with isolation := some (s.epoch + 1), barrierKnown := false, floorKnown := false}
  | observeBarrier (s) (exact : s.isolation = some (s.epoch + 1)) :
      Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner eligible s {s with barrierKnown := true}
  | advance (s) (closed : s.enabled = false) (exact : s.isolation = some (s.epoch + 1)) (known : s.barrierKnown = true)
      (durable : keyOwner.floorValid root (s.epoch + 1) (s.base.epoch + 1)) :
      Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner eligible s {s with
        epoch := s.epoch + 1
        base := {s.base with
          epoch := s.base.epoch + 1
          qualified := false
          fresh := false
          pending := fun _ => none
          observed := fun _ => none}
        barrierKnown := false
        floorKnown := false}
  | observeFloor (s) (exact : s.isolation = some s.epoch) (authentic : keyOwner.floorValid root s.epoch s.base.epoch) :
      Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner eligible s {s with floorKnown := true}
  | activate (s) (closed : s.enabled = false) (barrier : s.isolation = some s.epoch) (known : s.floorKnown = true)
      (qualified : s.base.qualified = true) (authentic : keyOwner.activationValid root s.epoch s.base) :
      Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner eligible s {s with enabled := true}
  | loseBuffer (s job) : Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner eligible s {s with
      queued := update s.queued job none, running := update s.running job none, completed := update s.completed job none}
  | loseResponse (s) : Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner eligible s s
inductive Run : State → State → Prop where
  | refl (s) : Run s s
  | next : Run s t → Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner eligible t u → Run s u

theorem parent_step_or_stutter (event : Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner eligible s t) :
    s.base = t.base ∨ Weaver.ProtectedSignerRelease.Step c m p lineage root namespaceId owner projectionStore family store signerOwner eligible s.base t.base := by
  cases event with
  | parentEvent _ source => exact .inr source
  | emit job ticket computed live handle durable observed qualified current member ready notRetired promise =>
    exact .inr (.release _ _ _ durable observed qualified current member ready notRetired promise)
  | advance => exact .inr (.restart _)
  | _ => exact .inl rfl

theorem closed_boundary_cannot_release (event : Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner eligible s t)
    (closed : s.enabled = false) : t.base.released = s.base.released := by
  cases event with
  | parentEvent next source noRelease => exact noRelease
  | emit job ticket computed live => simp [closed] at live
  | _ => rfl

theorem every_new_export_checks_current_handle (event : Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner eligible s t)
    (changed : t.exports ≠ s.exports) : ∃ ticket, t.exports = s.exports ++ [ticket] ∧ s.enabled = true ∧ LiveHandle s ticket ∧
      s.base.committed ticket.requestId = some ticket.statement ∧ Weaver.ProtectedSignerRelease.Current (root := root) s.base ticket.statement := by
  cases event with
  | emit job ticket computed live handle durable observed qualified current => exact ⟨ticket,rfl,live,handle,durable,current⟩
  | _ => exact False.elim (changed rfl)

theorem handle_identity_never_retags {handleId : Nat} (event : Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner eligible s t)
    (old : s.handles handleId = some h) : t.handles handleId = some h := by
  cases event with
  | issueHandle other voter live qualified unused =>
    by_cases same : handleId = other
    · subst handleId; rw [old] at unused; contradiction
    · simpa [update, same] using old
  | _ => exact old

theorem protected_key_epoch_never_rolls_back (event : Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner eligible s t) : s.epoch ≤ t.epoch := by
  cases event <;> simp

theorem used_ticket_cannot_be_reissued {job : Nat} (event : Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner eligible s t)
    (old : s.usedTickets job = true) : t.usedTickets job = true := by
  cases event with
  | enqueue other ticket => by_cases same : job = other <;> simp [update, same, old]
  | _ => exact old

def FloorObservationCurrent (s : State) : Prop := s.floorKnown = true → s.isolation = some s.epoch

theorem floor_observation_stays_bound_to_exact_cut (inv : FloorObservationCurrent s)
    (event : Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner eligible s t) : FloorObservationCurrent t := by
  cases event with
  | observeFloor exact => intro _; exact exact
  | close => simp [FloorObservationCurrent]
  | isolate => simp [FloorObservationCurrent]
  | advance => simp [FloorObservationCurrent]
  | _ => exact inv

def ComputedRecorded (s : State) : Prop := ∀ job t, s.completed job = some t → t ∈ s.produced

theorem computed_recorded_step (inv : ComputedRecorded s)
    (event : Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner eligible s t) : ComputedRecorded t := by
  cases event with
  | complete job ticket running authentic =>
    intro other x hx
    by_cases same : other = job
    · subst other; simp [update] at hx; subst x; simp
    · simp [update, same] at hx; exact List.mem_append_left _ (inv other x hx)
  | loseBuffer job =>
    intro other x hx
    by_cases same : other = job
    · subst other; simp [update] at hx
    · simp [update, same] at hx; exact inv other x hx
  | _ => exact inv

theorem exports_have_exact_completion (completion : ComputedRecorded s) (inv : CompletionSafe s)
    (event : Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner eligible s t) : CompletionSafe t := by
  cases event with
  | emit job ticket computed =>
    intro x hx
    rcases List.mem_append.mp hx with old | new
    · exact inv x old
    · have eq : x = ticket := by simpa using new
      subst x; exact completion job ticket computed
  | complete => intro x hx; exact List.mem_append_left _ (inv x hx)
  | _ => exact inv

theorem exports_refine_parent_release (inv : ExportReleased s)
    (event : Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner eligible s t) : ExportReleased t := by
  cases event with
  | parentEvent next source noRelease => simpa [ExportReleased, noRelease] using inv
  | emit job ticket =>
    intro x hx
    rcases List.mem_append.mp hx with old | new
    · exact List.mem_append_left _ (inv x old)
    · have eq : x = ticket := by simpa using new
      subst x; simp
  | _ => exact inv

theorem initialized_product_refines_release (events : Run (c := c) (m := m) (p := p) (lineage := lineage) (root := root) (namespaceId := namespaceId)
    (owner := owner) (projectionStore := projectionStore) (family := family) (store := store) (signerOwner := signerOwner) (keyOwner := keyOwner) (eligible := eligible) initial s) :
    Weaver.ProtectedSignerRelease.Run (c := c) (m := m) (p := p) (lineage := lineage) (root := root) (namespaceId := namespaceId)
      (owner := owner) (projectionStore := projectionStore) (family := family) (store := store) (signerOwner := signerOwner) (eligible := eligible) Weaver.ProtectedSignerRelease.initial s.base := by
  induction events with
  | refl => exact .refl _
  | next _ event ih =>
    rcases parent_step_or_stutter event with eq | source
    · simpa [← eq] using ih
    · exact .next ih source

theorem initialized_queue_safety (events : Run (c := c) (m := m) (p := p) (lineage := lineage) (root := root) (namespaceId := namespaceId)
    (owner := owner) (projectionStore := projectionStore) (family := family) (store := store) (signerOwner := signerOwner) (keyOwner := keyOwner) (eligible := eligible) initial s) :
    ComputedRecorded s ∧ CompletionSafe s ∧ ExportReleased s := by
  induction events with
  | refl => simp [ComputedRecorded, CompletionSafe, ExportReleased, initial]
  | next _ event ih => exact ⟨computed_recorded_step ih.1 event,exports_have_exact_completion ih.1 ih.2.1 event,exports_refine_parent_release ih.2.2 event⟩

theorem initialized_floor_observation_is_current (events : Run (c := c) (m := m) (p := p) (lineage := lineage) (root := root) (namespaceId := namespaceId)
    (owner := owner) (projectionStore := projectionStore) (family := family) (store := store) (signerOwner := signerOwner) (keyOwner := keyOwner) (eligible := eligible) initial s) : FloorObservationCurrent s := by
  induction events with
  | refl => simp [FloorObservationCurrent, initial]
  | next _ event ih => exact floor_observation_stays_bound_to_exact_cut ih event

theorem actual_exported_prefixes_cannot_conflict (events : Run (c := c) (m := m) (p := p) (lineage := lineage) (root := root) (namespaceId := namespaceId)
    (owner := owner) (projectionStore := projectionStore) (family := family) (store := store) (signerOwner := signerOwner) (keyOwner := keyOwner) (eligible := eligible) initial s)
    (left : a ∈ s.exports) (right : b ∈ s.exports) (sameSigner : a.statement.voter = b.statement.voter)
    (sameLength : a.statement.history.length = b.statement.history.length) : a.statement.history = b.statement.history := by
  exact Weaver.ProtectedSignerRelease.released_certificates_cannot_conflict
    (Weaver.ProtectedSignerRelease.initialized_release_invariant (initialized_product_refines_release events))
    ((initialized_queue_safety events).2.2 a left) ((initialized_queue_safety events).2.2 b right) sameSigner sameLength
theorem original_consumption_and_settlement_remain_unique (events : Run (c := c) (m := m) (p := p) (lineage := lineage) (root := root)
    (namespaceId := namespaceId) (owner := owner) (projectionStore := projectionStore) (family := family) (store := store) (signerOwner := signerOwner) (keyOwner := keyOwner) (eligible := eligible) initial s) (k) :
    s.base.base.base.base.base.burnCount k ≤ 1 ∧ s.base.base.base.base.dispatchCount k ≤ 1 ∧ s.base.base.base.base.base.base.authority.writes k ≤ 1 :=
  Weaver.ProtectedSignerRelease.original_consumption_and_settlement_remain_unique (initialized_product_refines_release events) k

theorem original_budget_remains_conserved (events : Run (c := c) (m := m) (p := p) (lineage := lineage) (root := root)
    (namespaceId := namespaceId) (owner := owner) (projectionStore := projectionStore) (family := family) (store := store) (signerOwner := signerOwner) (keyOwner := keyOwner) (eligible := eligible) initial s) (b) :
    Weaver.SettlementAnchorRecovery.accountMaterialized c s.base.base.base.base.base.base b ≤ Weaver.FiniteDomainMigration.booked c s.base.base.base.base.base.base.authority.source.base.base.control.journal.head.payload b ∧
    Weaver.SettlementAnchorRecovery.accountMaterialized c s.base.base.base.base.base.base b ≤ c.capacity b :=
  Weaver.ProtectedSignerRelease.original_budget_remains_conserved (initialized_product_refines_release events) b

theorem unknown_original_reservation_stays_held (events : Run (c := c) (m := m) (p := p) (lineage := lineage) (root := root)
    (namespaceId := namespaceId) (owner := owner) (projectionStore := projectionStore) (family := family) (store := store) (signerOwner := signerOwner) (keyOwner := keyOwner) (eligible := eligible) initial s)
    (sealed : s.base.base.base.base.base.seals k = some a) :
    (s.base.base.base.base.base.base.authority.source.base.base.control.journal.head.payload.messages k).reserved = true :=
  Weaver.ProtectedSignerRelease.unknown_original_reservation_stays_held (initialized_product_refines_release events) sealed

#print axioms initialized_floor_observation_is_current
#print axioms floor_observation_stays_bound_to_exact_cut
#print axioms protected_key_epoch_never_rolls_back
#print axioms used_ticket_cannot_be_reissued
#print axioms closed_boundary_cannot_release
#print axioms every_new_export_checks_current_handle
#print axioms handle_identity_never_retags
#print axioms initialized_queue_safety
#print axioms initialized_product_refines_release
#print axioms actual_exported_prefixes_cannot_conflict
#print axioms original_consumption_and_settlement_remain_unique
#print axioms original_budget_remains_conserved
#print axioms unknown_original_reservation_stays_held
end Weaver.KeyBoundaryQueue
