import GatewayHeadCAS

/- A software execution-authority refinement. A recorded call is an irreversible
local invocation, not a proof of provider execution or delivery. -/
namespace Weaver.BrokerConsumptionQueue

structure Range where
  lo : Nat
  hi : Nat
  epoch : Nat
  deriving DecidableEq
structure State where
  spent : Bool := false
  intent : Bool := false
  accepted : Bool := false
  acknowledged : Bool := false
  recovered : Bool := true
  epoch : Nat := 0
  allowed : Bool := true
  frontier : Nat := 0
  pending : Option Range := none
  calls : Nat → Nat := fun _ => 0
  ranges : List Range := []
  fullReceipts : List Range := []
  unknown : Bool := false
  completed : Bool := false
  usage : Bool := false
  settled : Bool := false
  settlements : Nat := 0

def initial : State := {}
def Held (s : State) : Prop := s.settled = false
def Safe (length : Nat) (s : State) : Prop :=
  (∀ i, s.calls i ≤ 1) ∧ s.frontier ≤ length ∧
  (∀ r ∈ s.ranges, r.lo < r.hi ∧ r.hi ≤ s.frontier) ∧
  (s.accepted = true → s.intent = true ∧ s.spent = true) ∧
  (s.unknown = true → Held s) ∧
  (s.settled = true → s.completed = true ∧ s.usage = true ∧ s.unknown = false ∧ s.pending = none) ∧
  s.settlements ≤ 1

def Separated (s : State) : Prop := ∀ a ∈ s.ranges, ∀ b ∈ s.ranges,
  a ≠ b → a.hi ≤ b.lo ∨ b.hi ≤ a.lo

structure ReceiptOwner where
  recoveryValid : Nat → Prop
  policyValid : Nat → Prop
  fullValid : Range → Prop
  terminalValid : Nat → Prop
  usageValid : Nat → Prop

inductive Step (owner : ReceiptOwner) (length : Nat) : State → State → Prop where
  | consume (s) (fresh : s.spent = false) : Step owner length s {s with spent := true}
  | persistIntent (s) (spent : s.spent = true) : Step owner length s {s with intent := true}
  | accept (s) (durable : s.intent = true) (spent : s.spent = true) :
      Step owner length s {s with accepted := true}
  | acknowledge (s) (accepted : s.accepted = true) : Step owner length s {s with acknowledged := true}
  | loseReply (s) : Step owner length s {s with acknowledged := false}
  | restart (s) : Step owner length s {s with epoch := s.epoch + 1, acknowledged := false, recovered := false}
  | recover (s) (evidence : owner.recoveryValid s.epoch) : Step owner length s {s with recovered := true}
  | revoke (s) : Step owner length s {s with allowed := false}
  | reauthorize (s) (policy : owner.policyValid s.epoch) : Step owner length s {s with allowed := true}
  | reserveWrite (s n) (accepted : s.accepted = true) (live : s.allowed = true)
      (holding : Held s) (known : s.unknown = false) (idle : s.pending = none)
      (positive : 0 < n) (bounded : s.frontier + n ≤ length)
      (policy : owner.policyValid s.epoch) (recovered : s.recovered = true) :
      Step owner length s {s with
        frontier := s.frontier + n,
        pending := some ⟨s.frontier,s.frontier+n,s.epoch⟩,
        ranges := s.ranges ++ [⟨s.frontier,s.frontier+n,s.epoch⟩]}
  | invoke (s r worker) (pending : s.pending = some r) (epoch : r.epoch = s.epoch)
      (workerCurrent : worker = s.epoch) (live : s.allowed = true)
      (holding : Held s) (known : s.unknown = false) (unused : s.calls r.lo = 0)
      (policy : owner.policyValid s.epoch) (recovered : s.recovered = true) :
      Step owner length s {s with
        calls := fun i => if i = r.lo then 1 else s.calls i,
        unknown := true}
  /- A bound, authentic full-write receipt is data, not new execution authority.
     It can resolve the original interval after a restart. A partial receipt cannot. -/
  | fullReceipt (s r) (pending : s.pending = some r) (invoked : s.calls r.lo = 1)
      (holding : Held s) (evidence : owner.fullValid r) :
      Step owner length s {s with pending := none, unknown := false, fullReceipts := s.fullReceipts ++ [r]}
  | partialOrTimeout (s) : Step owner length s s
  | terminal (s) (accepted : s.accepted = true) (allReserved : s.frontier = length)
      (idle : s.pending = none) (known : s.unknown = false)
      (evidence : owner.terminalValid length) : Step owner length s {s with completed := true}
  | finalUsage (s) (complete : s.completed = true) (evidence : owner.usageValid length) :
      Step owner length s {s with usage := true}
  | settle (s) (complete : s.completed = true) (usage : s.usage = true)
      (known : s.unknown = false) (idle : s.pending = none) (fresh : Held s) (notApplied : s.settlements = 0) :
      Step owner length s {s with settled := true, settlements := s.settlements + 1}

inductive Run (owner : ReceiptOwner) (length : Nat) : State → State → Prop where
  | refl (s) : Run owner length s s
  | next : Run owner length a b → Step owner length b d → Run owner length a d

theorem safe_step (h : Safe length s) (e : Step owner length s t) : Safe length t := by
  rcases h with ⟨calls,bound,ranges,accepted,unknown,settled,count⟩
  cases e with
  | reserveWrite n ha live holding known idle positive bounded policy recovered =>
    refine ⟨calls,bounded,?_,accepted,unknown,?_,count⟩
    · intro r member
      rcases List.mem_append.mp member with old | fresh
      · have hr := ranges r old; exact ⟨hr.1,Nat.le_trans hr.2 (Nat.le_add_right _ _)⟩
      · have eq : r = ⟨s.frontier,s.frontier+n,s.epoch⟩ := by simpa using fresh
        subst r; simp only; omega
    · intro bad; simp [Held] at holding; simp_all
  | invoke r worker pending epoch workerCurrent live holding known unused policy recovered =>
    refine ⟨?_,bound,ranges,accepted,?_,?_,count⟩
    · intro i; dsimp; split <;> simp_all
    · intro _; exact holding
    · intro bad; simp [Held] at holding; simp_all
  | settle complete usage known idle fresh notApplied =>
    refine ⟨calls,bound,ranges,accepted,?_,?_,?_⟩
    · simp_all
    · intro _; exact ⟨complete,usage,known,idle⟩
    · simp [notApplied]
  | fullReceipt r pending invoked holding evidence =>
    refine ⟨calls,bound,ranges,accepted,by simp,?_,count⟩
    intro bad; simp [Held] at holding; simp_all
  | _ => simp_all [Safe,Held]


theorem initialized_safe (run : Run owner length initial s) : Safe length s := by
  induction run with
  | refl => simp [Safe,initial,Held]
  | next prior e ih => exact safe_step ih e

def ReceiptCoverage (s : State) : Prop := ∀ r ∈ s.ranges, s.pending = some r ∨ r ∈ s.fullReceipts

theorem receipt_coverage_step (h : ReceiptCoverage s) (e : Step owner length s t) : ReceiptCoverage t := by
  cases e with
  | reserveWrite n accepted live holding known idle positive bounded policy recovered =>
    intro r member
    rcases List.mem_append.mp member with old | new
    · rcases h r old with pending | full
      · simp_all
      · exact Or.inr full
    · have eq : r = ⟨s.frontier,s.frontier+n,s.epoch⟩ := by simpa using new
      exact Or.inl (congrArg some eq.symm)
  | fullReceipt r pending invoked holding evidence =>
    intro r' member
    rcases h r' member with active | full
    · have eq : r' = r := Option.some.inj (active.symm.trans pending)
      exact Or.inr (List.mem_append.mpr (Or.inr (by simpa using eq)))
    · exact Or.inr (List.mem_append.mpr (Or.inl full))
  | _ => exact h

theorem initialized_receipt_coverage (run : Run owner length initial s) : ReceiptCoverage s := by
  induction run with
  | refl => simp [ReceiptCoverage,initial]
  | next prior e ih => exact receipt_coverage_step ih e

theorem settlement_has_every_original_range_receipt (run : Run owner length initial s)
    (settled : s.settled = true) : ∀ r ∈ s.ranges, r ∈ s.fullReceipts := by
  have idle := ((initialized_safe run).2.2.2.2.2.1 settled).2.2.2
  intro r member
  rcases initialized_receipt_coverage run r member with pending | full
  · simp_all
  · exact full

theorem frontier_monotone (e : Step owner length s t) : s.frontier ≤ t.frontier := by
  cases e <;> simp <;> omega

theorem separated_step (safe : Safe length s) (h : Separated s)
    (e : Step owner length s t) : Separated t := by
  cases e with
  | reserveWrite n accepted live holding known idle positive bounded policy recovered =>
    intro a ha b hb different
    rcases List.mem_append.mp ha with olda | newa
    · rcases List.mem_append.mp hb with oldb | newb
      · exact h a olda b oldb different
      · have eq : b = ⟨s.frontier,s.frontier+n,s.epoch⟩ := by simpa using newb
        subst b; exact Or.inl (safe.2.2.1 a olda).2
    · have eq : a = ⟨s.frontier,s.frontier+n,s.epoch⟩ := by simpa using newa
      subst a
      rcases List.mem_append.mp hb with oldb | newb
      · exact Or.inr (safe.2.2.1 b oldb).2
      · have eq : b = ⟨s.frontier,s.frontier+n,s.epoch⟩ := by simpa using newb
        exact False.elim (different eq.symm)
  | _ => exact h

theorem initialized_nonoverlapping_ranges (run : Run owner length initial s) : Separated s := by
  induction run with
  | refl => simp [Separated,initial]
  | next prior e ih => exact separated_step (initialized_safe prior) ih e

theorem initialized_at_most_one_invocation (run : Run owner length initial s) (offset) :
    s.calls offset ≤ 1 := (initialized_safe run).1 offset

theorem unknown_retains_original_hold (run : Run owner length initial s)
    (unknown : s.unknown = true) : Held s := (initialized_safe run).2.2.2.2.1 unknown

theorem settlement_requires_terminal_evidence (run : Run owner length initial s)
    (settled : s.settled = true) :
    s.completed = true ∧ s.usage = true ∧ s.unknown = false ∧ s.pending = none :=
  (initialized_safe run).2.2.2.2.2.1 settled

theorem durable_consumption_survives (e : Step owner length s t)
    (spent : s.spent = true) : t.spent = true := by cases e <;> simp_all

theorem accepted_tombstone_survives (e : Step owner length s t)
    (accepted : s.accepted = true) : t.accepted = true := by cases e <;> simp_all

theorem stale_worker_cannot_invoke (s : State) (r : Range) (worker : Nat)
    (stale : worker ≠ s.epoch) : ¬ (s.pending = some r ∧ r.epoch = s.epoch ∧ worker = s.epoch) := by
  simp_all

theorem full_receipt_rechecks_original_pending (e : Step owner length s t)
    (cleared : s.pending ≠ none) (idle : t.pending = none) :
    ∃ r, s.pending = some r ∧ s.calls r.lo = 1 ∧ owner.fullValid r := by
  cases e with
  | fullReceipt r pending invoked holding evidence => exact ⟨r,pending,invoked,evidence⟩
  | reserveWrite => simp at idle
  | _ => exact False.elim (cleared idle)

theorem invocation_rechecks_final_gate (e : Step owner length s t)
    (changed : t.calls i ≠ s.calls i) :
    ∃ r, s.pending = some r ∧ r.epoch = s.epoch ∧ s.allowed = true ∧ s.recovered = true ∧ Held s ∧
      s.unknown = false ∧ s.calls r.lo = 0 ∧ owner.policyValid s.epoch := by
  cases e with
  | invoke r worker pending epoch workerCurrent live holding known unused policy recovered =>
    exact ⟨r,pending,epoch,live,recovered,holding,known,unused,policy⟩
  | _ => exact False.elim (changed rfl)

/- Composition uses an actual parent transition and initialized history,
not a caller-supplied Boolean saying that a record was authorized. -/
structure Admission (c : Weaver.GatewayHeadCAS.Config) (policy : Weaver.GatewayHeadCAS.Owner) where
  before : Weaver.GatewayHeadCAS.State
  after : Weaver.GatewayHeadCAS.State
  key : Nat
  prior : Weaver.GatewayHeadCAS.Run c policy Weaver.GatewayHeadCAS.initial before
  event : Weaver.GatewayHeadCAS.Step c policy before after
  changed : (after.base.messages key).sends ≠ (before.base.messages key).sends

theorem admission_has_current_policy (a : Admission c policy) :
    ∃ h d, a.before.head = some h ∧ h.key = a.key ∧ Weaver.GatewayHeadCAS.JoinReady a.before h ∧
      d ∈ a.before.decisions ∧ d.job.view.head = h ∧ Weaver.GatewayHeadCAS.Canonical c a.before h ∧
      policy.policyAllows h a.before.base :=
  Weaver.GatewayHeadCAS.actual_logical_offer_requires_broker_authority a.event a.changed

structure Product (c : Weaver.GatewayHeadCAS.Config) (policy : Weaver.GatewayHeadCAS.Owner)
    (owner : ReceiptOwner) (length : Nat) (s : State) where
  admission : Admission c policy
  downstream : Run owner length initial s

-- Downstream steps stutter on the immutable semantic ledger snapshot. This
-- proves reservation accounting preservation, not a new financial refund API.
theorem product_unknown_keeps_hold (p : Product c policy owner length s)
    (unknown : s.unknown = true) : Held s := unknown_retains_original_hold p.downstream unknown

theorem queue_refinement_preserves_original_affinity (a : Admission c policy)
    (_run : Run owner length initial s) (k) :
    (a.after.base.messages k).claims ≤ 1 ∧ (a.after.base.messages k).sends ≤ 1 :=
  Weaver.GatewayHeadCAS.original_claim_and_offer_once (.next a.prior a.event) k

theorem queue_refinement_preserves_shared_budget (a : Admission c policy)
    (_run : Run owner length initial s) (b) :
    Weaver.FiniteDomainMigration.booked c a.after.base b ≤ c.capacity b :=
  Weaver.GatewayHeadCAS.shared_budget_is_bounded (.next a.prior a.event) b

theorem admission_retains_original_reservation (a : Admission c policy) :
    (a.after.base.messages a.key).reserved = true := by
  rcases admission_has_current_policy a with ⟨h,d,held,key,joined,decided,selected,canonical,allowed⟩
  rcases canonical with ⟨_,_,_,_,_,_,reserved,_,_⟩
  have before : (a.before.base.messages a.key).reserved = true := by simpa [key] using reserved
  exact Weaver.GatewayHeadCAS.unknown_original_reservation_survives a.event before

theorem end_to_end_unknown_preserves_obligations (p : Product c policy owner length s)
    (unknown : s.unknown = true) (b) :
    Held s ∧ (p.admission.after.base.messages p.admission.key).reserved = true ∧
    (p.admission.after.base.messages p.admission.key).claims ≤ 1 ∧
    (p.admission.after.base.messages p.admission.key).sends ≤ 1 ∧
    Weaver.FiniteDomainMigration.booked c p.admission.after.base b ≤ c.capacity b := by
  have affinity := queue_refinement_preserves_original_affinity p.admission p.downstream p.admission.key
  exact ⟨product_unknown_keeps_hold p unknown,admission_retains_original_reservation p.admission,
    affinity.1,affinity.2,queue_refinement_preserves_shared_budget p.admission p.downstream b⟩

-- Explicit unsafe-state witnesses; they are not constructors of Step.
theorem repeated_sdk_invocation_counterexample :
    ¬ Safe 4 {spent := true, intent := true, accepted := true, calls := fun _ => 2} := by
  intro h; have bad := h.1 0; simp at bad

theorem unknown_refund_counterexample :
    ¬ Safe 4 {unknown := true, settled := true} := by
  intro h; have bad := h.2.2.2.2.1 rfl; simp [Held] at bad

theorem overlapping_tail_counterexample :
    ¬ Separated {ranges := [⟨0,3,0⟩,⟨2,4,1⟩]} := by
  intro h
  have bad := h ⟨0,3,0⟩ (by simp) ⟨2,4,1⟩ (by simp) (by decide)
  rcases bad with bad | bad <;> simp at bad

#print axioms admission_retains_original_reservation
#print axioms end_to_end_unknown_preserves_obligations
#print axioms product_unknown_keeps_hold
#print axioms initialized_receipt_coverage
#print axioms settlement_has_every_original_range_receipt
#print axioms initialized_safe
#print axioms initialized_nonoverlapping_ranges
#print axioms initialized_at_most_one_invocation
#print axioms unknown_retains_original_hold
#print axioms settlement_requires_terminal_evidence
#print axioms durable_consumption_survives
#print axioms accepted_tombstone_survives
#print axioms stale_worker_cannot_invoke
#print axioms full_receipt_rechecks_original_pending
#print axioms invocation_rechecks_final_gate
#print axioms admission_has_current_policy
#print axioms queue_refinement_preserves_original_affinity
#print axioms queue_refinement_preserves_shared_budget
#print axioms repeated_sdk_invocation_counterexample
#print axioms unknown_refund_counterexample
#print axioms overlapping_tail_counterexample
end Weaver.BrokerConsumptionQueue
