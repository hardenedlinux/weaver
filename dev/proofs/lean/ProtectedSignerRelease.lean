import QuorumDurablePromises
namespace Weaver.ProtectedSignerRelease
open Weaver.LogicalMessageAuthority (update)
structure Request where
  voter : Nat
  record : Weaver.AnchorReconfiguration.Record
  history : List Weaver.AnchorReconfiguration.Record
  expected : List Weaver.AnchorReconfiguration.Record
  incarnation : Nat
  serviceEpoch : Nat
  deriving DecidableEq
structure SignerOwner where
  receiptValid : Nat → Nat → Request → Prop
  recoveryValid : Nat → Weaver.QuorumDurablePromises.State → (Nat → Option Request) → Prop
structure State where
  base : Weaver.QuorumDurablePromises.State := Weaver.QuorumDurablePromises.initial
  epoch : Nat := 0
  qualified : Bool := false
  fresh : Bool := false
  pending : Nat → Option Request := fun _ => none
  committed : Nat → Option Request := fun _ => none
  observed : Nat → Option Request := fun _ => none
  released : List Request := []
  delivered : List Request := []
def initial : State := {}
def Current {root : Nat} (s : State) (q : Request) : Prop :=
  q.serviceEpoch = s.epoch ∧ q.incarnation = s.base.incarnation q.voter ∧
  Weaver.AnchorReconfiguration.Header root s.base.base q.record ∧
  Weaver.QuorumDurablePromises.SigningScope s.base q.record
def Formed {root : Nat} (s : State) (q : Request) : Prop :=
  Current (root := root) s q ∧ q.history = s.base.base.history ++ [q.record] ∧ q.expected = s.base.protectedHistory q.voter
def ReleasedSafe (s : State) : Prop := ∀ q, q ∈ s.released → q.history <+: s.base.protectedHistory q.voter
def ReleaseEvidence (s : State) (next : Weaver.QuorumDurablePromises.State) : Prop :=
  next.base.history = s.base.base.history ∨ ∃ r, next.base.history = s.base.base.history ++ [r] ∧
    ∀ v, v ∈ r.oldQ ++ r.newQ → ∃ q ∈ s.delivered, q.voter = v ∧ q.history = next.base.history
variable {c : Weaver.FiniteDomainMigration.Config} {m : Weaver.FiniteStreamManifest.Manifest c}
  {p : Weaver.WriterSettlementClosure.Profile c m} {lineage root namespaceId : Nat}
  {owner : Weaver.GateConsumptionPersistence.EvidenceOwner} {projectionStore : Weaver.AnchorBrokerCommit.RootOwner}
  {family : Weaver.AnchorReconfiguration.Family} {store : Weaver.AnchorReconfiguration.Store} {signerOwner : SignerOwner}
  {eligible : Weaver.AnchorReconfiguration.Scope → Nat → Prop}
inductive Step (c : Weaver.FiniteDomainMigration.Config) (m : Weaver.FiniteStreamManifest.Manifest c)
    (p : Weaver.WriterSettlementClosure.Profile c m) (lineage root namespaceId : Nat)
    (owner : Weaver.GateConsumptionPersistence.EvidenceOwner) (projectionStore : Weaver.AnchorBrokerCommit.RootOwner)
    (family : Weaver.AnchorReconfiguration.Family) (store : Weaver.AnchorReconfiguration.Store) (signerOwner : SignerOwner)
    (eligible : Weaver.AnchorReconfiguration.Scope → Nat → Prop) : State → State → Prop where
  | begin (s id q) (live : s.qualified = true) (formed : Formed (root := root) s q)
      (unused : s.pending id = none ∧ s.committed id = none) :
      Step c m p lineage root namespaceId owner projectionStore family store signerOwner eligible s {s with pending := update s.pending id (some q)}
  | commit (s next id q) (held : s.pending id = some q) (unused : s.committed id = none)
      (live : s.qualified = true) (formed : Formed (root := root) s q)
      (event : Weaver.QuorumDurablePromises.Step c m p lineage root namespaceId owner projectionStore family store eligible s.base next)
      (noRoot : next.base = s.base.base) (sameIncarnation : next.incarnation q.voter = q.incarnation)
      (durable : next.protectedHistory q.voter = q.history) :
      Step c m p lineage root namespaceId owner projectionStore family store signerOwner eligible s {s with
        base := next, committed := update s.committed id (some q), fresh := false}
  | observe (s id q) (exact : s.committed id = some q) (authentic : signerOwner.receiptValid s.epoch id q) :
      Step c m p lineage root namespaceId owner projectionStore family store signerOwner eligible s {s with observed := update s.observed id (some q)}
  | release (s id q) (durable : s.committed id = some q) (resolved : s.observed id = some q)
      (live : s.qualified = true) (current : Current (root := root) s q)
      (member : eligible q.record.scope q.voter) (ready : s.base.ready q.voter = true)
      (notRetired : s.base.retired q.voter = false) (promise : q.history <+: s.base.protectedHistory q.voter) :
      Step c m p lineage root namespaceId owner projectionStore family store signerOwner eligible s {s with released := s.released ++ [q]}
  | deliver (s q) (issued : q ∈ s.released) :
      Step c m p lineage root namespaceId owner projectionStore family store signerOwner eligible s {s with delivered := s.delivered ++ [q]}
  | rootEvent (s next) (event : Weaver.QuorumDurablePromises.Step c m p lineage root namespaceId owner projectionStore family store eligible s.base next)
      (evidence : ReleaseEvidence s next) :
      Step c m p lineage root namespaceId owner projectionStore family store signerOwner eligible s {s with base := next, fresh := false}
  | restart (s) :
      Step c m p lineage root namespaceId owner projectionStore family store signerOwner eligible s {s with
        epoch := s.epoch + 1, qualified := false, fresh := false, pending := fun _ => none, observed := fun _ => none}
  -- Exact protected observations are abstract authentic-owner inputs, never snapshot writes.
  | currentRead (s epoch history entries) (authentic : signerOwner.recoveryValid s.epoch s.base s.committed)
      (epochExact : epoch = s.epoch) (historyExact : history = s.base.protectedHistory) (entriesExact : entries = s.committed) :
      Step c m p lineage root namespaceId owner projectionStore family store signerOwner eligible s {s with fresh := true}
  | qualify (s) (fresh : s.fresh = true) :
      Step c m p lineage root namespaceId owner projectionStore family store signerOwner eligible s {s with qualified := true}
  | loseResponse (s) : Step c m p lineage root namespaceId owner projectionStore family store signerOwner eligible s s
inductive Run : State → State → Prop where
  | refl (s) : Run s s
  | next : Run s t → Step c m p lineage root namespaceId owner projectionStore family store signerOwner eligible t u → Run s u

theorem parent_step_or_stutter (event : Step c m p lineage root namespaceId owner projectionStore family store signerOwner eligible s t) :
    s.base = t.base ∨ Weaver.QuorumDurablePromises.Step c m p lineage root namespaceId owner projectionStore family store eligible s.base t.base := by
  cases event with
  | commit _ _ _ _ _ _ _ event => exact .inr event
  | rootEvent _ event => exact .inr event
  | _ => exact .inl rfl

theorem every_released_statement_keeps_its_promise (inv : ReleasedSafe s)
    (event : Step c m p lineage root namespaceId owner projectionStore family store signerOwner eligible s t) : ReleasedSafe t := by
  have grow : Weaver.QuorumDurablePromises.Grows s.base t.base := by
    rcases parent_step_or_stutter event with eq | source
    · intro v; rw [eq]; exact List.prefix_refl _
    · exact Weaver.QuorumDurablePromises.protected_promises_grow source
  cases event with
  | release id q durable resolved live current member ready notRetired promise =>
    intro x hx
    rcases List.mem_append.mp hx with old | new
    · exact inv x old
    · have eq : x = q := by simpa using new
      subst x; exact promise
  | _ => intro q hq; exact (inv q hq).trans (grow q.voter)

theorem commit_response_loss_cannot_erase_commitment
    {requestId : Nat} (event : Step c m p lineage root namespaceId owner projectionStore family store signerOwner eligible s t)
    (old : s.committed requestId = some q) : t.committed requestId = some q := by
  cases event with
  | commit next other request held unused =>
    by_cases same : requestId = other
    · subst requestId; rw [old] at unused; contradiction
    · simpa [update, same] using old
  | _ => exact old

def ReleaseCommitted (s : State) : Prop := ∀ q, q ∈ s.released → ∃ requestId, s.committed requestId = some q

theorem release_commitment_step (inv : ReleaseCommitted s)
    (event : Step c m p lineage root namespaceId owner projectionStore family store signerOwner eligible s t) : ReleaseCommitted t := by
  have retained : ∀ id q, s.committed id = some q → t.committed id = some q := by
    intro requestId q old; exact commit_response_loss_cannot_erase_commitment event old
  cases event with
  | release requestId q durable resolved live current member ready notRetired promise =>
    intro x hx
    rcases List.mem_append.mp hx with old | new
    · exact inv x old
    · have eq : x = q := by simpa using new
      subst x; exact ⟨requestId, durable⟩
  | _ =>
    intro q member
    obtain ⟨requestId, committed⟩ := inv q member
    exact ⟨requestId, retained requestId q committed⟩

theorem root_publication_requires_released_quorum
    (event : Step c m p lineage root namespaceId owner projectionStore family store signerOwner eligible s t)
    (changed : t.base.base.history ≠ s.base.base.history) : ∃ r, t.base.base.history = s.base.base.history ++ [r] ∧
      ∀ v, v ∈ r.oldQ ++ r.newQ → ∃ q ∈ s.delivered, q.voter = v ∧ q.history = t.base.base.history := by
  cases event with
  | rootEvent next source evidence =>
    rcases evidence with same | witness
    · exact False.elim (changed same)
    · exact witness
  | commit next requestId q held unused live formed source noRoot =>
    exact False.elim (changed (congrArg Weaver.AnchorReconfiguration.State.history noRoot))
  | _ => exact False.elim (changed rfl)

theorem restart_does_not_restore_old_service_handle (s : State) (q : Request) (old : q.serviceEpoch = s.epoch) :
    q.serviceEpoch ≠ ({s with epoch := s.epoch + 1} : State).epoch := by simp [old]

theorem released_certificates_cannot_conflict (inv : ReleasedSafe s)
    (l : left ∈ s.released) (r : right ∈ s.released)
    (sameSigner : left.voter = right.voter) (samePosition : left.history.length = right.history.length) : left.history = right.history := by
  have a := inv left l
  have b := inv right r
  rw [← sameSigner] at b
  rcases List.prefix_or_prefix_of_prefix a b with h | h
  · exact h.eq_of_length samePosition
  · exact (h.eq_of_length samePosition.symm).symm

theorem initialized_release_invariant (events : Run (c := c) (m := m) (p := p) (lineage := lineage) (root := root) (namespaceId := namespaceId)
    (owner := owner) (projectionStore := projectionStore) (family := family) (store := store) (signerOwner := signerOwner) (eligible := eligible) initial s) : ReleasedSafe s := by
  induction events with
  | refl => intro q hq; simp [initial] at hq
  | next _ event ih => exact every_released_statement_keeps_its_promise ih event

theorem initialized_releases_have_committed_rows (events : Run (c := c) (m := m) (p := p) (lineage := lineage) (root := root) (namespaceId := namespaceId)
    (owner := owner) (projectionStore := projectionStore) (family := family) (store := store) (signerOwner := signerOwner) (eligible := eligible) initial s) : ReleaseCommitted s := by
  induction events with
  | refl => intro q hq; simp [initial] at hq
  | next _ event ih => exact release_commitment_step ih event

def DeliveredOriginal (s : State) : Prop := ∀ q, q ∈ s.delivered → q ∈ s.released

theorem delivered_original_step (inv : DeliveredOriginal s)
    (event : Step c m p lineage root namespaceId owner projectionStore family store signerOwner eligible s t) : DeliveredOriginal t := by
  cases event with
  | deliver q issued =>
    intro x hx
    rcases List.mem_append.mp hx with old | new
    · exact inv x old
    · have eq : x = q := by simpa using new
      subst x; exact issued
  | release requestId q => intro x hx; exact List.mem_append_left _ (inv x hx)
  | _ => exact inv

theorem late_delivery_cannot_create_a_new_statement (events : Run (c := c) (m := m) (p := p) (lineage := lineage) (root := root) (namespaceId := namespaceId)
    (owner := owner) (projectionStore := projectionStore) (family := family) (store := store) (signerOwner := signerOwner) (eligible := eligible) initial s) : DeliveredOriginal s := by
  induction events with
  | refl => intro q hq; simp [initial] at hq
  | next _ event ih => exact delivered_original_step ih event

theorem initialized_product_refines_promises (events : Run (c := c) (m := m) (p := p) (lineage := lineage) (root := root) (namespaceId := namespaceId)
    (owner := owner) (projectionStore := projectionStore) (family := family) (store := store) (signerOwner := signerOwner) (eligible := eligible) initial s) :
    Weaver.QuorumDurablePromises.Run (c := c) (m := m) (p := p) (lineage := lineage) (root := root) (namespaceId := namespaceId)
      (owner := owner) (projectionStore := projectionStore) (family := family) (store := store) (eligible := eligible) Weaver.QuorumDurablePromises.initial s.base := by
  induction events with
  | refl => exact .refl _
  | next _ event ih =>
    rcases parent_step_or_stutter event with eq | source
    · simpa [← eq] using ih
    · exact .next ih source
theorem original_consumption_and_settlement_remain_unique (events : Run (c := c) (m := m) (p := p) (lineage := lineage) (root := root)
    (namespaceId := namespaceId) (owner := owner) (projectionStore := projectionStore) (family := family) (store := store) (signerOwner := signerOwner) (eligible := eligible) initial s) (k) :
    s.base.base.base.base.burnCount k ≤ 1 ∧ s.base.base.base.dispatchCount k ≤ 1 ∧ s.base.base.base.base.base.authority.writes k ≤ 1 :=
  Weaver.QuorumDurablePromises.original_consumption_and_settlement_remain_unique (initialized_product_refines_promises events) k

theorem original_budget_remains_conserved (events : Run (c := c) (m := m) (p := p) (lineage := lineage) (root := root)
    (namespaceId := namespaceId) (owner := owner) (projectionStore := projectionStore) (family := family) (store := store) (signerOwner := signerOwner) (eligible := eligible) initial s) (b) :
    Weaver.SettlementAnchorRecovery.accountMaterialized c s.base.base.base.base.base b ≤ Weaver.FiniteDomainMigration.booked c s.base.base.base.base.base.authority.source.base.base.control.journal.head.payload b ∧
    Weaver.SettlementAnchorRecovery.accountMaterialized c s.base.base.base.base.base b ≤ c.capacity b :=
  Weaver.QuorumDurablePromises.original_budget_remains_conserved (initialized_product_refines_promises events) b

theorem unknown_original_reservation_stays_held (events : Run (c := c) (m := m) (p := p) (lineage := lineage) (root := root)
    (namespaceId := namespaceId) (owner := owner) (projectionStore := projectionStore) (family := family) (store := store) (signerOwner := signerOwner) (eligible := eligible) initial s)
    (sealed : s.base.base.base.base.seals k = some a) :
    (s.base.base.base.base.base.authority.source.base.base.control.journal.head.payload.messages k).reserved = true :=
  Weaver.QuorumDurablePromises.unknown_original_reservation_stays_held (initialized_product_refines_promises events) sealed

#print axioms late_delivery_cannot_create_a_new_statement
#print axioms root_publication_requires_released_quorum
#print axioms initialized_releases_have_committed_rows
#print axioms every_released_statement_keeps_its_promise
#print axioms commit_response_loss_cannot_erase_commitment
#print axioms restart_does_not_restore_old_service_handle
#print axioms released_certificates_cannot_conflict
#print axioms initialized_release_invariant
#print axioms initialized_product_refines_promises
#print axioms original_consumption_and_settlement_remain_unique
#print axioms original_budget_remains_conserved
#print axioms unknown_original_reservation_stays_held
end Weaver.ProtectedSignerRelease
