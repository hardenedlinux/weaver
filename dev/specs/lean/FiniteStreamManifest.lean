import ComposedGatewayLifecycle

/-! Arbitrary finite immutable range manifests refine the initialized coordinator.
The physical premise is one original driver tail capability, never reconstructed
from owner records. Offered prefixes are possible exposure, not delivery. -/
namespace Weaver.FiniteStreamManifest
open Weaver.AnchoredRecoveryAndEgress (RangeBinding ClaimBound)
open Weaver.LogicalMessageAuthority (update)
open Weaver.FiniteDomainMigration (sumKeys)
abbrev Coordinator := Weaver.ComposedGatewayLifecycle.State
abbrev Key := Nat × Nat

structure Descriptor where
  offset : Nat
  length : Nat
  quota : Nat
  content : Nat
  route : Nat
  deriving DecidableEq

structure Manifest (c : Weaver.FiniteDomainMigration.Config) where
  count : Nat → Nat
  spec : Nat → Nat → Descriptor
  stream : Nat → Nat
  identity : Nat → Nat
  contentRoot : Nat → Nat
  messageLength : Nat → Nat
  peer : Nat → Nat
  routeBound : ∀ k r, r < count k → (spec k r).route = peer k
  contentBound : ∀ k, contentRoot k = c.payload k
  within : ∀ k r, r < count k → (spec k r).offset + (spec k r).length ≤ messageLength k
  covers : ∀ k b, b < messageLength k → ∃ r, r < count k ∧
    (spec k r).offset ≤ b ∧ b < (spec k r).offset + (spec k r).length
  positive : ∀ k r, r < count k → 0 < (spec k r).length
  orderedOffsets : ∀ k r t, r < t → t < count k →
    (spec k r).offset + (spec k r).length ≤ (spec k t).offset
  disjoint : ∀ k r t, r < count k → t < count k → r ≠ t →
    (spec k r).offset + (spec k r).length ≤ (spec k t).offset ∨
    (spec k t).offset + (spec k t).length ≤ (spec k r).offset
  quotaBound : ∀ k, sumKeys (List.range (count k)) (fun r => (spec k r).quota) ≤ c.cost k

structure RangeState where
  admission : Option Weaver.ComposedGatewayLifecycle.Delegation := none
  accepts : Nat := 0
  cursor : Nat := 0
  -- Slot remains owned even at full cursor until qualified finish or quarantine.
  active : Bool := false
  -- Possible exposure counts are observations. Cursor ownership is the guard.
  offered : Nat → Nat := fun _ => 0

def RangeSafe (length : Nat) (s : RangeState) : Prop :=
  s.accepts ≤ 1 ∧
  (s.admission = none → s.accepts = 0 ∧ s.cursor = 0 ∧ s.active = false) ∧
  (∀ d, s.admission = some d → s.accepts = 1) ∧
  s.cursor ≤ length ∧ (∀ b, s.offered b = if b < s.cursor then 1 else 0) ∧
  (s.active = true → s.admission ≠ none ∧ s.cursor ≤ length)

def setAt (f : Key → α) (key : Key) (value : α) : Key → α := fun j => if j = key then value else f j

def admitRange (s : RangeState) (d : Weaver.ComposedGatewayLifecycle.Delegation) : RangeState :=
  { s with admission := some d, accepts := s.accepts + 1, active := true }

def advanceRange (s : RangeState) (n _length : Nat) : RangeState :=
  { s with
    cursor := s.cursor + n
    active := s.active
    offered := fun b => s.offered b + if s.cursor ≤ b ∧ b < s.cursor + n then 1 else 0 }

theorem initial_range_safe (length) : RangeSafe length {} := by simp [RangeSafe]

theorem admit_range_safe (h : RangeSafe length s) (fresh : s.admission = none) (_positive : 0 < length) :
    RangeSafe length (admitRange s d) := by
  have old := h.2.1 fresh
  simp [RangeSafe, admitRange, old.1, old.2.1, h.2.2.2.2.1]

theorem advance_range_safe (h : RangeSafe length s) (live : s.active = true)
    (bounded : s.cursor + n ≤ length) : RangeSafe length (advanceRange s n length) := by
  have present := (h.2.2.2.2.2 live).1
  refine ⟨h.1, ?_, h.2.2.1, bounded, ?_, ?_⟩
  · intro absent; exact False.elim (present absent)
  · intro b
    simp only [advanceRange, h.2.2.2.2.1 b]
    by_cases a : b < s.cursor
    · have z : b < s.cursor + n := by omega
      have no : ¬ s.cursor ≤ b := by omega
      simp [a, z, no]
    · have ge : s.cursor ≤ b := by omega
      by_cases z : b < s.cursor + n <;> simp [a, z, ge]
  · intro active
    exact ⟨present, bounded⟩

def closeRange (s : RangeState) (length : Nat) : RangeState :=
  { advanceRange s (length - s.cursor) length with active := false }

theorem deactivate_range_safe (h : RangeSafe length s) : RangeSafe length { s with active := false } := by
  refine ⟨h.1, ?_, h.2.2.1, h.2.2.2.1, h.2.2.2.2.1, by simp⟩
  intro absent
  exact ⟨(h.2.1 absent).1, (h.2.1 absent).2.1, rfl⟩

structure State where
  control : Coordinator := Weaver.ComposedGatewayLifecycle.initial
  installed : Nat → Option RangeBinding := fun _ => none
  ranges : Key → RangeState := fun _ => {}
  blocked : Nat → Bool := fun _ => false

def initial : State := {}

/-- Structural restriction to coordinator events. The old one-range accept/drain
constructors cannot produce an empty old delegation store. This is a proof
projection filter, not a proposed runtime check of ghost counters. -/
structure ControlAdvance (c : Weaver.FiniteDomainMigration.Config) (s t : Coordinator) : Prop where
  event : Weaver.ComposedGatewayLifecycle.Step c s t
  noOldDelegations : ∀ k, t.delegated k = none

def IdleStream (c : Weaver.FiniteDomainMigration.Config) (m : Manifest c) (s : State) (key : Key) : Prop :=
  ∀ j, m.stream j.1 = m.stream key.1 → (s.ranges j).active = false

def PredecessorsDone (m : Manifest c) (s : State) (key : Key) : Prop :=
  ∀ r, r < key.2 → (s.ranges (key.1,r)).cursor = (m.spec key.1 r).length ∧
    (s.ranges (key.1,r)).active = false

def MessageStarted (s : State) (k : Nat) : Prop :=
  ∃ r d, (s.ranges (k,r)).admission = some d

def MessageComplete (m : Manifest c) (s : State) (k : Nat) : Prop :=
  ∀ r, r < m.count k → (s.ranges (k,r)).cursor = (m.spec k r).length

def StreamCompatible (m : Manifest c) (s : State) (key : Key) : Prop :=
  ∀ other, other ≠ key.1 → m.stream other = m.stream key.1 →
    MessageStarted s other → MessageComplete m s other

structure AdmissionGate (c : Weaver.FiniteDomainMigration.Config) (m : Manifest c) (s : State)
    (key : Key) (binding : RangeBinding) (ticket : Weaver.FiniteDomainMigration.Ticket)
    (epoch incarnation : Nat) (descriptor : Descriptor) : Prop where
  installed : s.installed key.1 = some binding
  member : key.2 < m.count key.1
  exactDescriptor : descriptor = m.spec key.1 key.2
  exactMessage : binding.key = key.1
  fresh : (s.ranges key).admission = none
  current : Weaver.ComposedGatewayLifecycle.CanDelegate c s.control binding ticket epoch incarnation
  notBlocked : s.blocked (m.stream key.1) = false
  idle : IdleStream c m s key
  ordered : PredecessorsDone m s key
  compatible : StreamCompatible m s key

def admitted (s : State) (key : Key) (binding : RangeBinding)
    (ticket : Weaver.FiniteDomainMigration.Ticket) : State :=
  { s with ranges := setAt s.ranges key (admitRange (s.ranges key)
      ⟨s.control.journal.head, binding, ticket, s.control.epoch, s.control.incarnation⟩) }

inductive Step (c : Weaver.FiniteDomainMigration.Config) (m : Manifest c) : State → State → Prop where
  | control (s next) (event : ControlAdvance c s.control next)
      (tailsClosed : ∀ key, (next.journal.head.payload.messages key.1).retired = true → (s.ranges key).active = false) :
      Step c m s { s with control := next }
  | install (s binding ticket epoch incarnation manifestIdentity)
      (fresh : s.installed binding.key = none) (identity : manifestIdentity = m.identity binding.key)
      (gate : Weaver.ComposedGatewayLifecycle.CanDelegate c s.control binding ticket epoch incarnation) :
      Step c m s { s with installed := update s.installed binding.key (some binding) }
  | delegate (s key binding ticket epoch incarnation descriptor)
      (gate : AdmissionGate c m s key binding ticket epoch incarnation descriptor) :
      Step c m s (admitted s key binding ticket)
  | writePrefix (s key d n holderEpoch holderIncarnation)
      (stored : (s.ranges key).admission = some d) (live : (s.ranges key).active = true)
      (holder : holderEpoch = d.epoch ∧ holderIncarnation = d.incarnation)
      (positive : 0 < n) (bound : (s.ranges key).cursor + n ≤ (m.spec key.1 key.2).length) :
      Step c m s { s with ranges := setAt s.ranges key (advanceRange (s.ranges key) n (m.spec key.1 key.2).length) }
  | finishRange (s key d holderEpoch holderIncarnation frontier)
      (stored : (s.ranges key).admission = some d) (live : (s.ranges key).active = true)
      (holder : holderEpoch = d.epoch ∧ holderIncarnation = d.incarnation)
      (exactFrontier : frontier = (s.ranges key).cursor)
      (whole : frontier = (m.spec key.1 key.2).length) :
      Step c m s { s with ranges := setAt s.ranges key { s.ranges key with active := false } }
  | uncertain (s key d holderEpoch holderIncarnation)
      (stored : (s.ranges key).admission = some d) (live : (s.ranges key).active = true)
      (holder : holderEpoch = d.epoch ∧ holderIncarnation = d.incarnation) :
      Step c m s { s with
        ranges := setAt s.ranges key (closeRange (s.ranges key) (m.spec key.1 key.2).length)
        blocked := update s.blocked (m.stream key.1) true }
  | observation (s) : Step c m s s

inductive Reachable (c : Weaver.FiniteDomainMigration.Config) (m : Manifest c) : State → Prop where
  | init : Reachable c m initial
  | next : Reachable c m s → Step c m s s' → Reachable c m s'

structure Invariant (c : Weaver.FiniteDomainMigration.Config) (m : Manifest c) (s : State) : Prop where
  control : Weaver.ComposedGatewayLifecycle.Reachable c s.control
  empty : ∀ k, s.control.delegated k = none
  manifests : ∀ k binding, s.installed k = some binding → binding.key = k ∧
    ClaimBound c s.control.journal.head.payload binding
  ranges : ∀ key, RangeSafe (m.spec key.1 key.2).length (s.ranges key)
  records : ∀ key d, (s.ranges key).admission = some d →
    key.2 < m.count key.1 ∧ s.installed key.1 = some d.range ∧ d.range.key = key.1 ∧
    Weaver.FiniteDomainMigration.Reachable c d.image.payload ∧ ClaimBound c d.image.payload d.range ∧
    d.image.payload.restricted (c.history (c.root key.1)) = false ∧
    Weaver.FiniteDomainMigration.Current d.image.payload d.ticket ∧
    d.range.executor = (d.ticket.worker, d.ticket.generation, d.ticket.fence)
  uniqueActive : ∀ a b, (s.ranges a).active = true → (s.ranges b).active = true →
    m.stream a.1 = m.stream b.1 → a = b

theorem initial_invariant (c m) : Invariant c m initial := by
  refine ⟨.init, ?_, ?_, ?_, ?_, ?_⟩
  · simp [initial, Weaver.ComposedGatewayLifecycle.initial]
  · simp [initial]
  · intro key; exact initial_range_safe _
  · simp [initial]
  · simp [initial]

theorem bound_survives_control (event : Weaver.ComposedGatewayLifecycle.Step c a b)
    (reachable : Weaver.ComposedGatewayLifecycle.Reachable c b)
    (bound : ClaimBound c a.journal.head.payload binding) : ClaimBound c b.journal.head.payload binding := by
  have history := ((Weaver.FiniteDomainMigration.reachable_invariant
    (Weaver.ComposedGatewayLifecycle.reachable_invariant reachable).journal.payload).messages binding.key)
  have oldSafe := Weaver.ComposedGatewayLifecycle.ledger_projection event
  rcases Weaver.FiniteDomainMigration.local_step_or_stutter oldSafe binding.key with step | same
  · have sticky := Weaver.LogicalMessageAuthority.claim_origin_is_sticky step bound.2.1
    exact ⟨bound.1, sticky.1, sticky.2.1.trans bound.2.2.1,
      (Weaver.ComposedGatewayLifecycle.original_executor_survives event bound.2.1).trans bound.2.2.2.1,
      history.2.1 sticky.1⟩
  · exact ⟨bound.1, by simpa [same] using bound.2.1, by simpa [same] using bound.2.2.1,
      (Weaver.ComposedGatewayLifecycle.original_executor_survives event bound.2.1).trans bound.2.2.2.1,
      by simpa [same] using bound.2.2.2.2⟩

theorem step_preserves (h : Invariant c m s) (event : Step c m s s') : Invariant c m s' := by
  cases event with
  | control next event tailsClosed =>
    have reachable := Weaver.ComposedGatewayLifecycle.Reachable.next h.control event.event
    refine ⟨reachable, event.noOldDelegations, ?_, h.ranges, h.records, h.uniqueActive⟩
    intro k binding stored
    exact ⟨(h.manifests k binding stored).1,
      bound_survives_control event.event reachable (h.manifests k binding stored).2⟩
  | install binding ticket epoch incarnation manifestIdentity fresh identity gate =>
    refine ⟨h.control, h.empty, ?_, h.ranges, ?_, h.uniqueActive⟩
    · intro k b stored
      by_cases eq : k = binding.key
      · subst k
        have same : b = binding := by simpa [update] using stored.symm
        subst b
        exact ⟨rfl, gate.2.2.2.2.2.2.1⟩
      · exact h.manifests k b (by simpa [update, eq] using stored)
    · intro key d stored
      have old := h.records key d stored
      have ne : key.1 ≠ binding.key := by
        intro eq
        have prior := old.2.1
        rw [eq, fresh] at prior
        contradiction
      exact ⟨old.1, by simpa [update, ne] using old.2.1, old.2.2⟩
  | delegate key binding ticket epoch incarnation descriptor gate =>
    have safe := h.ranges key
    have zero := safe.2.1 gate.fresh
    refine ⟨h.control, h.empty, h.manifests, ?_, ?_, ?_⟩
    · intro j; by_cases eq : j = key
      · subst j
        exact (by simpa [admitted, setAt] using admit_range_safe safe gate.fresh (m.positive _ _ gate.member))
      · simpa [admitted, setAt, eq] using h.ranges j
    · intro j d stored; by_cases eq : j = key
      · subst j
        have same : d = ⟨s.control.journal.head, binding, ticket, s.control.epoch, s.control.incarnation⟩ := by
          simpa [admitted, setAt, admitRange] using stored.symm
        subst d
        exact ⟨gate.member, gate.installed, gate.exactMessage,
          (Weaver.ComposedGatewayLifecycle.reachable_invariant h.control).journal.payload,
          gate.current.2.2.2.2.2.2.1,
          by simpa [gate.exactMessage] using gate.current.2.2.2.2.2.2.2.2.2.2.1,
          gate.current.2.2.2.2.2.2.2.1, gate.current.2.2.2.2.2.2.2.2.2.1⟩
      · exact h.records j d (by simpa [admitted, setAt, eq] using stored)
    · intro a b ha hb stream
      by_cases ea : a = key <;> by_cases eb : b = key
      · exact ea.trans eb.symm
      · subst a
        have old : (s.ranges b).active = true := by simpa [admitted, setAt, eb] using hb
        have off := gate.idle b stream.symm
        simp_all
      · subst b
        have old : (s.ranges a).active = true := by simpa [admitted, setAt, ea] using ha
        have off := gate.idle a stream
        simp_all
      · exact h.uniqueActive a b (by simpa [admitted, setAt, ea] using ha) (by simpa [admitted, setAt, eb] using hb) stream
  | writePrefix key d n holderEpoch holderIncarnation stored live holder positive bound =>
    refine ⟨h.control, h.empty, h.manifests, ?_, ?_, ?_⟩
    · intro j; by_cases eq : j = key
      · subst j; simpa [setAt] using advance_range_safe (h.ranges key) live bound
      · simpa [setAt, eq] using h.ranges j
    · intro j rec record; by_cases eq : j = key
      · subst j; exact h.records key rec (by simpa [setAt, closeRange, advanceRange] using record)
      · exact h.records j rec (by simpa [setAt, eq] using record)
    · intro a b ha hb stream
      have old (j) (hj : (({ s with ranges := setAt s.ranges key (advanceRange (s.ranges key) n (m.spec key.1 key.2).length) } : State).ranges j).active = true) :
          (s.ranges j).active = true := by
        by_cases eq : j = key
        · simpa [eq] using live
        · simpa [setAt, eq] using hj
      exact h.uniqueActive a b (old a ha) (old b hb) stream
  | finishRange key d e inc frontier stored live holder exactFrontier whole =>
    refine ⟨h.control, h.empty, h.manifests, ?_, ?_, ?_⟩
    · intro j; by_cases eq : j = key
      · subst j; simpa [setAt] using deactivate_range_safe (h.ranges key)
      · simpa [setAt, eq] using h.ranges j
    · intro j rec record; by_cases eq : j = key
      · subst j; exact h.records key rec (by simpa [setAt] using record)
      · exact h.records j rec (by simpa [setAt, eq] using record)
    · intro a b ha hb stream
      have old (j) (active : (({ s with ranges := setAt s.ranges key { s.ranges key with active := false } } : State).ranges j).active = true) : (s.ranges j).active = true := by
        by_cases eq : j = key
        · simp [setAt, eq] at active
        · simpa [setAt, eq] using active
      exact h.uniqueActive a b (old a ha) (old b hb) stream
  | uncertain key d holderEpoch holderIncarnation stored live holder =>
    have maximum := (h.ranges key).2.2.2.1
    have bound : (s.ranges key).cursor + ((m.spec key.1 key.2).length - (s.ranges key).cursor) ≤ (m.spec key.1 key.2).length := by omega
    refine ⟨h.control, h.empty, h.manifests, ?_, ?_, ?_⟩
    · intro j; by_cases eq : j = key
      · subst j; simpa [setAt, closeRange] using deactivate_range_safe (advance_range_safe (h.ranges key) live bound)
      · simpa [setAt, eq] using h.ranges j
    · intro j rec record; by_cases eq : j = key
      · subst j; exact h.records key rec (by simpa [setAt, closeRange, advanceRange] using record)
      · exact h.records j rec (by simpa [setAt, eq] using record)
    · intro a b ha hb stream
      have old (j) (hj : (({ s with ranges := setAt s.ranges key (closeRange (s.ranges key) (m.spec key.1 key.2).length) } : State).ranges j).active = true) :
          (s.ranges j).active = true := by
        by_cases eq : j = key
        · simpa [eq] using live
        · simpa [setAt, eq] using hj
      exact h.uniqueActive a b (old a ha) (old b hb) stream
  | observation => exact h

theorem reachable_invariant (h : Reachable c m s) : Invariant c m s := by
  induction h with
  | init => exact initial_invariant c m
  | next _ event ih => exact step_preserves ih event

theorem sum_mono (ks : List Nat) (f g : Nat → Nat) (bound : ∀ k ∈ ks, f k ≤ g k) :
    sumKeys ks f ≤ sumKeys ks g := by
  induction ks with
  | nil => exact Nat.le_refl 0
  | cons a rest ih =>
    have head := bound a (by simp)
    have tail := ih (fun k hk => bound k (by simp [hk]))
    simp only [sumKeys]
    omega

def rangeQuota (m : Manifest c) (s : State) (k r : Nat) : Nat :=
  if (s.ranges (k,r)).admission.isSome then (m.spec k r).quota else 0

def messageQuota (m : Manifest c) (s : State) (k : Nat) : Nat :=
  sumKeys (List.range (m.count k)) (rangeQuota m s k)

def accountQuota (c : Weaver.FiniteDomainMigration.Config) (m : Manifest c) (s : State) (b : Nat) : Nat :=
  sumKeys c.keys (fun k => if c.budget (c.root k) = b then messageQuota m s k else 0)

theorem message_quota_bound (m : Manifest c) (s : State) (k) : messageQuota m s k ≤ c.cost k := by
  apply Nat.le_trans (sum_mono _ _ _ ?_) (m.quotaBound k)
  intro r hr
  simp only [rangeQuota]
  split <;> omega

theorem shared_budget_covered (h : Reachable c m s) (b : Nat) :
    accountQuota c m s b ≤ Weaver.FiniteDomainMigration.booked c s.control.journal.head.payload b ∧
    accountQuota c m s b ≤ c.capacity b := by
  have invariant := reachable_invariant h
  have covered : accountQuota c m s b ≤ Weaver.FiniteDomainMigration.booked c s.control.journal.head.payload b := by
    apply sum_mono
    intro k hk
    by_cases account : c.budget (c.root k) = b
    · cases stored : s.installed k with
      | none =>
        have zero : messageQuota m s k = 0 := by
          unfold messageQuota
          rw [Weaver.FiniteDomainMigration.sum_congr _ _ (fun _ => 0) ?_, Weaver.FiniteDomainMigration.sum_zero]
          intro r hr
          cases entry : (s.ranges (k,r)).admission with
          | none => simp [rangeQuota, entry]
          | some d =>
            have existing := (invariant.records (k,r) d entry).2.1
            simp [stored] at existing
        simp [zero, Weaver.FiniteDomainMigration.allocation, account]
      | some binding =>
        have bindingFact := invariant.manifests k binding stored
        have reserved := bindingFact.2.2.2.2.2
        rw [bindingFact.1] at reserved
        simpa [Weaver.FiniteDomainMigration.allocation, account, reserved] using message_quota_bound m s k
    · simp [Weaver.FiniteDomainMigration.allocation, account]
  exact ⟨covered, Nat.le_trans covered (Weaver.ComposedGatewayLifecycle.end_to_end_conservation invariant.control b)⟩

theorem byte_offered_at_most_once (h : Reachable c m s) (key : Key) (b : Nat) :
    (s.ranges key).offered b ≤ 1 := by
  rw [(reachable_invariant h).ranges key |>.2.2.2.2.1 b]
  split <;> omega

theorem no_cross_range_byte_alias (m : Manifest c) (k r t absolute : Nat)
    (rMember : r < m.count k) (tMember : t < m.count k)
    (inR : (m.spec k r).offset ≤ absolute ∧ absolute < (m.spec k r).offset + (m.spec k r).length)
    (inT : (m.spec k t).offset ≤ absolute ∧ absolute < (m.spec k t).offset + (m.spec k t).length) : r = t := by
  by_cases eq : r = t
  · exact eq
  · rcases m.disjoint k r t rMember tMember eq with left | right <;> omega

theorem manifest_exact_partition (m : Manifest c) (k b : Nat) (inside : b < m.messageLength k) :
    ∃ r, r < m.count k ∧ (m.spec k r).offset ≤ b ∧ b < (m.spec k r).offset + (m.spec k r).length ∧
      ∀ t, t < m.count k → (m.spec k t).offset ≤ b → b < (m.spec k t).offset + (m.spec k t).length → t = r := by
  obtain ⟨r, member, lower, upper⟩ := m.covers k b inside
  exact ⟨r, member, lower, upper, fun t mt lo hi => no_cross_range_byte_alias m k t r b mt member ⟨lo,hi⟩ ⟨lower,upper⟩⟩

theorem original_manifest_is_immutable (step : Step c m s s') (stored : s.installed k = some binding) :
    s'.installed k = some binding := by
  cases step with
  | install newBinding ticket epoch incarnation manifestIdentity fresh identity gate =>
    by_cases eq : k = newBinding.key
    · subst k; simp_all
    · simpa [update, eq] using stored
  | _ => exact stored

theorem range_admission_is_immutable (step : Step c m s s') (stored : (s.ranges key).admission = some d) :
    (s'.ranges key).admission = some d := by
  cases step with
  | delegate newKey binding ticket epoch incarnation descriptor gate =>
    by_cases eq : key = newKey
    · subst key; have fresh := gate.fresh; simp_all
    · simpa [admitted, setAt, eq] using stored
  | writePrefix k => by_cases eq : key = k <;> simpa [setAt, closeRange, advanceRange, eq] using stored
  | uncertain k => by_cases eq : key = k <;> simpa [setAt, closeRange, advanceRange, eq] using stored
  | finishRange k => by_cases eq : key = k <;> simpa [setAt, eq] using stored
  | _ => exact stored

theorem live_stream_has_one_tail (h : Reachable c m s) (a b : Key)
    (ha : (s.ranges a).active = true) (hb : (s.ranges b).active = true)
    (same : m.stream a.1 = m.stream b.1) : a = b :=
  (reachable_invariant h).uniqueActive a b ha hb same

theorem delegated_range_has_original_admission (h : Reachable c m s)
    (stored : (s.ranges key).admission = some d) :
    s.installed key.1 = some d.range ∧ ClaimBound c d.image.payload d.range ∧
    d.image.payload.restricted (c.history (c.root key.1)) = false ∧
    Weaver.FiniteDomainMigration.Current d.image.payload d.ticket := by
  have facts := (reachable_invariant h).records key d stored
  exact ⟨facts.2.1, facts.2.2.2.2.1, facts.2.2.2.2.2.1, facts.2.2.2.2.2.2.1⟩

theorem blocked_stream_cannot_delegate (blocked : s.blocked (m.stream key.1) = true) :
    ¬ AdmissionGate c m s key binding ticket epoch incarnation descriptor := by
  intro gate
  have allowed := gate.notBlocked
  simp_all

theorem restricted_history_cannot_delegate
    (history : s.control.journal.head.payload.restricted (c.history (c.root key.1)) = true) :
    ¬ AdmissionGate c m s key binding ticket epoch incarnation descriptor := by
  intro gate
  apply Weaver.ComposedGatewayLifecycle.restricted_account_blocks_delegate (range := binding) ?_ gate.current
  simpa [gate.exactMessage] using history

theorem admitted_range_has_exact_peer (gate : AdmissionGate c m s key binding ticket epoch incarnation descriptor) :
    descriptor.route = m.peer key.1 := by
  rw [gate.exactDescriptor]
  exact m.routeBound _ _ gate.member

theorem range_step_projects (step : Step c m s s') :
    Weaver.FiniteDomainMigration.Transition c s.control.journal.head.payload s'.control.journal.head.payload := by
  cases step with
  | control next event tailsClosed => exact Weaver.ComposedGatewayLifecycle.ledger_projection event.event
  | _ => exact .resumeOldWorker _

inductive Steps (c : Weaver.FiniteDomainMigration.Config) (m : Manifest c) : State → State → Prop where
  | refl : Steps c m s s
  | tail : Steps c m s t → Step c m t u → Steps c m s u

theorem original_claim_and_history_survive_trace (trace : Steps c m s t)
    (claim : (s.control.journal.head.payload.messages k).claimed = true)
    (history : (s.control.journal.head.payload.messages k).history = true) :
    (t.control.journal.head.payload.messages k).claimed = true ∧
    (t.control.journal.head.payload.messages k).claimToken = (s.control.journal.head.payload.messages k).claimToken ∧
    (t.control.journal.head.payload.messages k).claimStream = (s.control.journal.head.payload.messages k).claimStream ∧
    (t.control.journal.head.payload.messages k).history = true ∧
    t.control.journal.head.payload.claimOwner k = s.control.journal.head.payload.claimOwner k := by
  induction trace with
  | refl => exact ⟨claim, rfl, rfl, history, rfl⟩
  | tail trace step ih =>
    have projection := range_step_projects step
    have next := Weaver.FiniteDomainMigration.claim_and_history_survive projection ih.1 ih.2.2.2.1
    have owner := Weaver.FiniteDomainMigration.claim_executor_stamp_is_sticky projection ih.1
    exact ⟨next.1, next.2.1.trans ih.2.1, next.2.2.1.trans ih.2.2.1, next.2.2.2,
      owner.trans ih.2.2.2.2⟩

theorem cursor_never_rewinds (step : Step c m s s') (key : Key) :
    (s.ranges key).cursor ≤ (s'.ranges key).cursor := by
  cases step with
  | delegate newKey => by_cases eq : key = newKey <;> simp [admitted, setAt, admitRange, eq]
  | writePrefix newKey => by_cases eq : key = newKey <;> simp [setAt, advanceRange, eq]
  | uncertain newKey => by_cases eq : key = newKey <;> simp [setAt, closeRange, advanceRange, eq]
  | finishRange newKey => by_cases eq : key = newKey <;> simp [setAt, eq]
  | _ => exact Nat.le_refl _

theorem quarantine_is_monotone (step : Step c m s s') (old : s.blocked stream = true) :
    s'.blocked stream = true := by
  cases step with
  | uncertain key => by_cases eq : stream = m.stream key.1 <;> simp_all [update]
  | _ => exact old

theorem active_prefix_admission_cannot_replay (record : (s.ranges key).admission = some d) :
    ¬ AdmissionGate c m s key binding ticket epoch incarnation descriptor := by
  intro gate
  have fresh := gate.fresh
  simp_all

theorem range_quota_never_released (step : Step c m s s') (k r : Nat) :
    rangeQuota m s k r ≤ rangeQuota m s' k r := by
  cases old : (s.ranges (k,r)).admission with
  | none => simp [rangeQuota, old]
  | some d =>
    have after := range_admission_is_immutable step old
    simp [rangeQuota, old, after]

theorem message_quota_never_released (step : Step c m s s') (k : Nat) :
    messageQuota m s k ≤ messageQuota m s' k :=
  sum_mono _ _ _ (fun r _ => range_quota_never_released step k r)

theorem account_history_survives_trace (trace : Steps c m s t)
    (history : s.control.journal.head.payload.restricted b = true) :
    t.control.journal.head.payload.restricted b = true := by
  induction trace with
  | refl => exact history
  | tail trace step ih => exact Weaver.FiniteDomainMigration.history_account_is_sticky (range_step_projects step) ih

theorem canonical_body_byte_affinity (h : Reachable c m s) (k r t b : Nat)
    (rm : r < m.count k) (tm : t < m.count k)
    (inR : (m.spec k r).offset ≤ b ∧ b < (m.spec k r).offset + (m.spec k r).length)
    (inT : (m.spec k t).offset ≤ b ∧ b < (m.spec k t).offset + (m.spec k t).length) :
    r = t ∧ (s.ranges (k,r)).offered (b - (m.spec k r).offset) ≤ 1 :=
  ⟨no_cross_range_byte_alias m k r t b rm tm inR inT, byte_offered_at_most_once h _ _⟩

theorem advancing_frontier_retains_slot (s : RangeState) (n length : Nat) :
    (advanceRange s n length).active = s.active := rfl

theorem occupied_range_blocks_new_delegation (busy : (s.ranges prior).active = true)
    (same : m.stream prior.1 = m.stream key.1) :
    ¬ AdmissionGate c m s key binding ticket epoch incarnation descriptor := by
  intro gate
  have closed := gate.idle prior same
  simp_all

theorem old_holder_is_not_retagged (step : Step c m s s') (stored : (s.ranges key).admission = some d) :
    ∃ after, (s'.ranges key).admission = some after ∧ after.epoch = d.epoch ∧ after.incarnation = d.incarnation :=
  ⟨d, range_admission_is_immutable step stored, rfl, rfl⟩

theorem owner_restart_does_not_rebuild_ranges (s : State) (next : Coordinator)
    (_event : ControlAdvance c s.control next) :
    ({ s with control := next } : State).ranges = s.ranges ∧
    ({ s with control := next } : State).installed = s.installed ∧
    ({ s with control := next } : State).blocked = s.blocked := ⟨rfl,rfl,rfl⟩

def MessagesSafe (m : Manifest c) (s : State) : Prop :=
  ∀ a b, a ≠ b → m.stream a = m.stream b → MessageStarted s a → MessageStarted s b →
    MessageComplete m s a ∨ MessageComplete m s b

theorem complete_message_stays_complete (inv : Invariant c m s') (step : Step c m s s')
    (complete : MessageComplete m s k) : MessageComplete m s' k := by
  intro r member
  have old := complete r member
  have advance := cursor_never_rewinds step (k,r)
  have bound := (inv.ranges (k,r)).2.2.2.1
  change (s'.ranges (k,r)).cursor ≤ (m.spec k r).length at bound
  omega

theorem messages_step_preserves (inv : Invariant c m s') (safe : MessagesSafe m s)
    (step : Step c m s s') : MessagesSafe m s' := by
  have move (k) (done : MessageComplete m s k) : MessageComplete m s' k := complete_message_stays_complete inv step done
  cases step with
  | delegate key binding ticket epoch incarnation descriptor gate =>
    intro a b different same startedA startedB
    have oldStarted (k) (differentKey : k ≠ key.1) (started : MessageStarted (admitted s key binding ticket) k) : MessageStarted s k := by
      obtain ⟨r,d,record⟩ := started
      have ne : (k,r) ≠ key := by intro eq; exact differentKey (congrArg Prod.fst eq)
      exact ⟨r,d,by simpa [admitted, setAt, ne] using record⟩
    by_cases ea : a = key.1
    · subst a
      have eb : b ≠ key.1 := Ne.symm different
      exact Or.inr (move b (gate.compatible b eb same.symm (oldStarted b eb startedB)))
    · by_cases eb : b = key.1
      · subst b
        exact Or.inl (move a (gate.compatible a ea same (oldStarted a ea startedA)))
      · rcases safe a b different same (oldStarted a ea startedA) (oldStarted b eb startedB) with left | right
        · exact Or.inl (move a left)
        · exact Or.inr (move b right)
  | writePrefix key d n e inc stored live holder positive bound =>
    intro a b different same startedA startedB
    have oldStarted (k) (started : MessageStarted { s with ranges := setAt s.ranges key (advanceRange (s.ranges key) n (m.spec key.1 key.2).length) } k) : MessageStarted s k := by
      obtain ⟨r,d,record⟩ := started
      by_cases eq : (k,r) = key
      · exact ⟨r,d,by simpa [setAt, closeRange, advanceRange, eq] using record⟩
      · exact ⟨r,d,by simpa [setAt, eq] using record⟩
    rcases safe a b different same (oldStarted a startedA) (oldStarted b startedB) with left | right
    · exact Or.inl (move a left)
    · exact Or.inr (move b right)
  | uncertain key d e inc stored live holder =>
    intro a b different same startedA startedB
    have oldStarted (k) (started : MessageStarted { s with
        ranges := setAt s.ranges key (closeRange (s.ranges key) (m.spec key.1 key.2).length)
        blocked := update s.blocked (m.stream key.1) true } k) : MessageStarted s k := by
      obtain ⟨r,d,record⟩ := started
      by_cases eq : (k,r) = key
      · exact ⟨r,d,by simpa [setAt, closeRange, advanceRange, eq] using record⟩
      · exact ⟨r,d,by simpa [setAt, eq] using record⟩
    rcases safe a b different same (oldStarted a startedA) (oldStarted b startedB) with left | right
    · exact Or.inl (move a left)
    · exact Or.inr (move b right)
  | finishRange key d e inc frontier stored live holder exactFrontier whole =>
    intro a b different same startedA startedB
    have oldStarted (k) (started : MessageStarted { s with ranges := setAt s.ranges key { s.ranges key with active := false } } k) : MessageStarted s k := by
      obtain ⟨r,d,record⟩ := started
      by_cases eq : (k,r) = key
      · exact ⟨r,d,by simpa [setAt, eq] using record⟩
      · exact ⟨r,d,by simpa [setAt, eq] using record⟩
    rcases safe a b different same (oldStarted a startedA) (oldStarted b startedB) with left | right
    · exact Or.inl (move a left)
    · exact Or.inr (move b right)
  | _ => exact safe

theorem one_unfinished_message_per_stream (h : Reachable c m s) : MessagesSafe m s := by
  induction h with
  | init => simp [MessagesSafe, MessageStarted, initial]
  | next prior step ih => exact messages_step_preserves (reachable_invariant (.next prior step)) ih step

def RetirementSafe (s : State) : Prop :=
  ∀ key, (s.control.journal.head.payload.messages key.1).retired = true → (s.ranges key).active = false

theorem retirement_step_preserves (safe : RetirementSafe s) (step : Step c m s s') : RetirementSafe s' := by
  cases step with
  | control next event tailsClosed => exact tailsClosed
  | delegate key binding ticket epoch incarnation descriptor gate =>
    intro j retired
    by_cases eq : j = key
    · subst j
      have unretired := gate.current.2.2.2.2.2.2.2.2.2.2.2.2.2
      have conflict : (s.control.journal.head.payload.messages binding.key).retired = true := by simpa [admitted, gate.exactMessage] using retired
      simp_all
    · simpa [admitted, setAt, eq] using safe j retired
  | writePrefix key d n e inc stored live holder positive bound =>
    intro j retired
    by_cases eq : j = key
    · subst j; have off := safe key retired; simp_all
    · simpa [setAt, eq] using safe j retired
  | uncertain key d e inc stored live holder =>
    intro j retired
    by_cases eq : j = key
    · subst j; have off := safe key retired; simp_all
    · simpa [setAt, eq] using safe j retired
  | finishRange key d e inc frontier stored live holder exactFrontier whole =>
    intro j retired
    by_cases eq : j = key
    · simp [setAt, eq]
    · simpa [setAt, eq] using safe j retired
  | _ => exact safe

theorem retired_message_has_no_live_tail (h : Reachable c m s) : RetirementSafe s := by
  induction h with
  | init => simp [RetirementSafe, initial, Weaver.ComposedGatewayLifecycle.initial, Weaver.AnchoredRecoveryAndEgress.Journal.initial,
      Weaver.FiniteDomainMigration.empty, Weaver.LogicalMessageAuthority.initial]
  | next _ step ih => exact retirement_step_preserves ih step

#print axioms reachable_invariant
#print axioms shared_budget_covered
#print axioms admitted_range_has_exact_peer
#print axioms retired_message_has_no_live_tail
#print axioms one_unfinished_message_per_stream
#print axioms advancing_frontier_retains_slot
#print axioms occupied_range_blocks_new_delegation
#print axioms byte_offered_at_most_once
#print axioms manifest_exact_partition
#print axioms original_manifest_is_immutable
#print axioms range_admission_is_immutable
#print axioms cursor_never_rewinds
#print axioms quarantine_is_monotone
#print axioms live_stream_has_one_tail
#print axioms delegated_range_has_original_admission
#print axioms original_claim_and_history_survive_trace
#print axioms account_history_survives_trace
#print axioms message_quota_never_released
#print axioms canonical_body_byte_affinity
end Weaver.FiniteStreamManifest
