-- SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
--
-- SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

import AnchorReconfiguration

namespace Weaver.QuorumDurablePromises
open Weaver.LogicalMessageAuthority (update)

-- A deliberately conservative sticky-prefix profile, not a Raft/Paxos proof.
-- The full Record is the choice; re-proposing a different term/envelope can block.
structure State where
  base : Weaver.AnchorReconfiguration.State := Weaver.AnchorReconfiguration.initial
  protectedHistory : Nat → List Weaver.AnchorReconfiguration.Record := fun _ => []
  replica : Nat → List Weaver.AnchorReconfiguration.Record := fun _ => []
  incarnation : Nat → Nat := fun _ => 0
  ready : Nat → Bool := fun _ => false
  retired : Nat → Bool := fun _ => false

def initial : State := {}
def Witnessed (s : State) (history : List Weaver.AnchorReconfiguration.Record) (voters : List Nat) : Prop :=
  ∀ v, v ∈ voters → history <+: s.protectedHistory v

def Grows (s t : State) : Prop := ∀ v, s.protectedHistory v <+: t.protectedHistory v

def Publication (s : State) (next : Weaver.AnchorReconfiguration.State) : Prop :=
  next.history = s.base.history ∨ ∃ r, next.history = s.base.history ++ [r] ∧ Witnessed s next.history (r.oldQ ++ r.newQ)

def SigningScope (s : State) (r : Weaver.AnchorReconfiguration.Record) : Prop :=
  r.scope = s.base.scope ∨ ∃ old, s.base.scope = .stable old ∧ r.scope = .joint old (old + 1) ∧ r.body = .enter old (old + 1)

variable {c : Weaver.FiniteDomainMigration.Config} {m : Weaver.FiniteStreamManifest.Manifest c}
  {p : Weaver.WriterSettlementClosure.Profile c m} {lineage root namespaceId : Nat}
  {owner : Weaver.GateConsumptionPersistence.EvidenceOwner}
  {projectionStore : Weaver.AnchorBrokerCommit.RootOwner}
  {family : Weaver.AnchorReconfiguration.Family} {store : Weaver.AnchorReconfiguration.Store}
  {eligible : Weaver.AnchorReconfiguration.Scope → Nat → Prop}

inductive Step (c : Weaver.FiniteDomainMigration.Config) (m : Weaver.FiniteStreamManifest.Manifest c)
    (p : Weaver.WriterSettlementClosure.Profile c m) (lineage root namespaceId : Nat)
    (owner : Weaver.GateConsumptionPersistence.EvidenceOwner)
    (projectionStore : Weaver.AnchorBrokerCommit.RootOwner)
    (family : Weaver.AnchorReconfiguration.Family) (store : Weaver.AnchorReconfiguration.Store)
    (eligible : Weaver.AnchorReconfiguration.Scope → Nat → Prop) : State → State → Prop where
  | publish (s next) (event : Weaver.AnchorReconfiguration.Step c m p lineage root namespaceId owner projectionStore family store s.base next)
      (witness : Publication s next) : Step c m p lineage root namespaceId owner projectionStore family store eligible s {s with base := next}
  | prepare (s v r token)
      (current : token = s.incarnation v)
      (header : Weaver.AnchorReconfiguration.Header root s.base r)
      (scope : SigningScope s r) (member : eligible r.scope v)
      (live : s.ready v = true) (notRetired : s.retired v = false)
      (caughtUp : s.replica v = s.protectedHistory v)
      (prior : s.protectedHistory v <+: s.base.history ++ [r]) :
      Step c m p lineage root namespaceId owner projectionStore family store eligible s {s with
        protectedHistory := update s.protectedHistory v (s.base.history ++ [r])
        replica := update s.replica v (s.base.history ++ [r])}
  | restore (s v snapshot) :
      Step c m p lineage root namespaceId owner projectionStore family store eligible s {s with
        replica := update s.replica v snapshot
        ready := update s.ready v false
        incarnation := update s.incarnation v (s.incarnation v + 1)}
  | recover (s v) (member : eligible s.base.scope v) (notRetired : s.retired v = false)
      (complete : s.base.history = s.protectedHistory v)
      (installed : s.base.installed v = some (Weaver.AnchorReconfiguration.image s.base)) :
      Step c m p lineage root namespaceId owner projectionStore family store eligible s {s with
        replica := update s.replica v (s.protectedHistory v)
        ready := update s.ready v true}
  | retire (s v) :
      Step c m p lineage root namespaceId owner projectionStore family store eligible s {s with
        retired := update s.retired v true
        ready := update s.ready v false
        incarnation := update s.incarnation v (s.incarnation v + 1)}
  | loseResponse (s) : Step c m p lineage root namespaceId owner projectionStore family store eligible s s

inductive Run : State → State → Prop where
  | refl (s) : Run s s
  | next : Run s t → Step c m p lineage root namespaceId owner projectionStore family store eligible t u → Run s u

-- Every permitted failure/recovery/election preserves the protected witness.
theorem protected_promises_grow (event : Step c m p lineage root namespaceId owner projectionStore family store eligible s t) : Grows s t := by
  intro v
  cases event with
  | prepare voter record token current header scope member live notRetired caughtUp prior =>
    by_cases same : v = voter
    · subst v; simpa [update] using prior
    · simp [update, same]
  | _ => exact List.prefix_refl _

theorem run_preserves_promises (events : Run (c := c) (m := m) (p := p) (lineage := lineage) (root := root)
    (namespaceId := namespaceId) (owner := owner) (projectionStore := projectionStore) (family := family) (store := store) (eligible := eligible) s t) : Grows s t := by
  induction events with
  | refl => intro v; exact List.prefix_refl _
  | next _ event ih => intro v; exact (ih v).trans (protected_promises_grow event v)

theorem historical_acknowledgement_survives_recovery (ack : Witnessed s history voters) (growth : Grows s t) : Witnessed t history voters := by
  intro v member
  exact (ack v member).trans (growth v)

-- A common witness is useful only because its protected history cannot fork.
theorem intersecting_certificates_are_comparable (left : Witnessed s xs lq) (right : Witnessed s ys rq)
    (overlap : ∃ v, v ∈ lq ∧ v ∈ rq) : xs <+: ys ∨ ys <+: xs := by
  rcases overlap with ⟨v, vl, vr⟩
  exact List.prefix_or_prefix_of_prefix (left v vl) (right v vr)

theorem same_position_cannot_confirm_conflicting_prefixes (left : Witnessed s xs lq) (right : Witnessed s ys rq)
    (overlap : ∃ v, v ∈ lq ∧ v ∈ rq) (sameLength : xs.length = ys.length) : xs = ys := by
  rcases intersecting_certificates_are_comparable left right overlap with h | h
  · exact h.eq_of_length sameLength
  · exact (h.eq_of_length sameLength.symm).symm

theorem certificates_across_restart_cannot_conflict
    (events : Run (c := c) (m := m) (p := p) (lineage := lineage) (root := root)
      (namespaceId := namespaceId) (owner := owner) (projectionStore := projectionStore) (family := family) (store := store) (eligible := eligible) s t)
    (left : Witnessed s xs lq) (right : Witnessed t ys rq)
    (overlap : ∃ v, v ∈ lq ∧ v ∈ rq) (sameLength : xs.length = ys.length) : xs = ys :=
  same_position_cannot_confirm_conflicting_prefixes
    (historical_acknowledgement_survives_recovery left (run_preserves_promises events)) right overlap sameLength

theorem retirement_never_reenrolls (event : Step c m p lineage root namespaceId owner projectionStore family store eligible s t)
    (old : s.retired v = true) : t.retired v = true := by
  cases event with
  | retire voter => by_cases same : v = voter <;> simp [update, same, old]
  | _ => exact old

theorem old_joint_bridge_cannot_fork (stable : Weaver.AnchorReconfiguration.Authorized family (.stable old) lq [])
    (joint : Weaver.AnchorReconfiguration.Authorized family (.joint old next) oq nq)
    (left : Witnessed s xs lq) (right : Witnessed s ys oq) : xs <+: ys ∨ ys <+: xs :=
  intersecting_certificates_are_comparable left right (Weaver.AnchorReconfiguration.old_and_joint_quorums_intersect stable joint)

theorem joint_new_bridge_cannot_fork (joint : Weaver.AnchorReconfiguration.Authorized family (.joint old next) oq nq)
    (stable : Weaver.AnchorReconfiguration.Authorized family (.stable next) rq [])
    (left : Witnessed s xs nq) (right : Witnessed s ys rq) : xs <+: ys ∨ ys <+: xs :=
  intersecting_certificates_are_comparable left right (Weaver.AnchorReconfiguration.joint_and_new_quorums_intersect joint stable)

theorem published_extension_has_protected_witnesses (event : Step c m p lineage root namespaceId owner projectionStore family store eligible s t)
    (changed : t.base.history ≠ s.base.history) : ∃ r, t.base.history = s.base.history ++ [r] ∧ Witnessed t t.base.history (r.oldQ ++ r.newQ) := by
  cases event with
  | publish _ _ witness =>
    rcases witness with same | ⟨r, eq, qualified⟩
    · exact False.elim (changed same)
    · exact ⟨r, eq, qualified⟩
  | _ => exact False.elim (changed rfl)

theorem restored_old_handle_is_not_current (s : State) (v token : Nat) (old : token = s.incarnation v) :
    token ≠ ({s with incarnation := update s.incarnation v (s.incarnation v + 1)} : State).incarnation v := by
  simp [update, old]

theorem base_step_or_stutter (event : Step c m p lineage root namespaceId owner projectionStore family store eligible s t) :
    s.base = t.base ∨ Weaver.AnchorReconfiguration.Step c m p lineage root namespaceId owner projectionStore family store s.base t.base := by
  cases event with
  | publish _ event _ => exact Or.inr event
  | _ => exact Or.inl rfl

theorem initialized_product_refines_execution (events : Run (c := c) (m := m) (p := p) (lineage := lineage) (root := root)
    (namespaceId := namespaceId) (owner := owner) (projectionStore := projectionStore) (family := family) (store := store) (eligible := eligible) initial s) :
    Weaver.AnchorReconfiguration.Reachable c m p lineage root namespaceId owner projectionStore family store s.base := by
  induction events with
  | refl => exact .init
  | next _ event ih =>
    rcases base_step_or_stutter event with eq | source
    · simpa [← eq] using ih
    · exact .next ih source

theorem original_consumption_and_settlement_remain_unique (events : Run (c := c) (m := m) (p := p) (lineage := lineage) (root := root)
    (namespaceId := namespaceId) (owner := owner) (projectionStore := projectionStore) (family := family) (store := store) (eligible := eligible) initial s) (k) :
    s.base.base.base.burnCount k ≤ 1 ∧ s.base.base.dispatchCount k ≤ 1 ∧ s.base.base.base.base.authority.writes k ≤ 1 :=
  Weaver.AnchorReconfiguration.one_original_consumption_and_application (initialized_product_refines_execution events) k

theorem original_budget_remains_conserved (events : Run (c := c) (m := m) (p := p) (lineage := lineage) (root := root)
    (namespaceId := namespaceId) (owner := owner) (projectionStore := projectionStore) (family := family) (store := store) (eligible := eligible) initial s) (b) :
    Weaver.SettlementAnchorRecovery.accountMaterialized c s.base.base.base.base b ≤ Weaver.FiniteDomainMigration.booked c s.base.base.base.base.authority.source.base.base.control.journal.head.payload b ∧
    Weaver.SettlementAnchorRecovery.accountMaterialized c s.base.base.base.base b ≤ c.capacity b :=
  Weaver.AnchorReconfiguration.original_shared_budget_conserved (initialized_product_refines_execution events) b

theorem unknown_original_reservation_stays_held (events : Run (c := c) (m := m) (p := p) (lineage := lineage) (root := root)
    (namespaceId := namespaceId) (owner := owner) (projectionStore := projectionStore) (family := family) (store := store) (eligible := eligible) initial s)
    (sealed : s.base.base.base.seals k = some a) :
    (s.base.base.base.base.authority.source.base.base.control.journal.head.payload.messages k).reserved = true :=
  Weaver.AnchorReconfiguration.original_unknown_reservation_retained (initialized_product_refines_execution events) sealed

#print axioms certificates_across_restart_cannot_conflict
#print axioms retirement_never_reenrolls
#print axioms unknown_original_reservation_stays_held
#print axioms protected_promises_grow
#print axioms run_preserves_promises
#print axioms historical_acknowledgement_survives_recovery
#print axioms same_position_cannot_confirm_conflicting_prefixes
#print axioms old_joint_bridge_cannot_fork
#print axioms joint_new_bridge_cannot_fork
#print axioms published_extension_has_protected_witnesses
#print axioms restored_old_handle_is_not_current
#print axioms initialized_product_refines_execution
#print axioms original_consumption_and_settlement_remain_unique
#print axioms original_budget_remains_conserved
end Weaver.QuorumDurablePromises
