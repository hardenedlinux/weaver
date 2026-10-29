import BrokerConsumptionQueue

/- Same logical range, separately fenced execution permit. No hardware premise. -/
namespace Weaver.LogicalRangeRecovery
structure Scope where
  root : Nat
  claim : Nat
  budget : Nat
  history : Nat
  manifest : Nat
  route : Nat
  lo : Nat
  hi : Nat
  deriving DecidableEq
structure Cut where
  scope : Scope
  epoch : Nat
  revision : Nat
  calls : Nat
  deriving DecidableEq
structure Permit where
  scope : Scope
  epoch : Nat
  activation : Nat
  deriving DecidableEq
structure Receipt where
  call : Permit
  bytes : Nat
  deriving DecidableEq
structure Owner where
  prefixValid : Cut → Prop
  policyValid : Scope → Nat → Prop
  receiptValid : Receipt → Prop
structure State where
  epoch : Nat := 0
  revision : Nat := 0
  calls : Nat := 0
  fenced : Bool := false
  allowed : Bool := true
  observed : Option Cut := none
  jobs : List Cut := []
  decisions : List Permit := []
  permit : Option Permit := none
  invocation : Option Permit := none
  unknown : Bool := false
  full : Bool := false
  receipts : List Receipt := []

def initial : State := {}
def cut (scope : Scope) (s : State) : Cut := ⟨scope,s.epoch,s.revision,s.calls⟩
def issued (scope : Scope) (s : State) : Permit := ⟨scope,s.epoch,s.revision+1⟩
def Safe (scope : Scope) (s : State) : Prop :=
  s.calls ≤ 1 ∧
  (s.unknown = true → s.calls = 1 ∧ s.full = false) ∧
  (s.full = true → s.calls = 1 ∧ s.unknown = false) ∧
  (∀ p, s.permit = some p → p.scope = scope ∧ p.epoch = s.epoch ∧
    p.activation = s.revision ∧ s.calls = 0 ∧ s.fenced = false) ∧
  (∀ p, s.invocation = some p → p.scope = scope ∧ s.calls = 1)

inductive Step (scope : Scope) (owner : Owner) : State → State → Prop where
  | fence (s) : Step scope owner s {s with
      epoch := s.epoch+1, revision := s.revision+1,
      fenced := true, permit := none, observed := none}
  | certify (s c) (closed : s.fenced = true) (exact : c = cut scope s)
      (valid : owner.prefixValid c) : Step scope owner s {s with observed := some c}
  | prepare (s) (seen : s.observed = some (cut scope s)) (closed : s.fenced = true)
      (unused : s.calls = 0) : Step scope owner s {s with jobs := s.jobs ++ [cut scope s]}
  | activate (s c) (registered : c ∈ s.jobs) (exact : c = cut scope s)
      (closed : s.fenced = true) (unused : s.calls = 0) (allowed : s.allowed = true)
      (policy : owner.policyValid scope s.epoch) :
      Step scope owner s {s with
        revision := s.revision+1, fenced := false,
        permit := some (issued scope s), decisions := s.decisions ++ [issued scope s], observed := none}
  | invoke (s p worker) (held : s.permit = some p) (bound : p.scope = scope)
      (epoch : p.epoch = s.epoch) (current : worker = s.epoch) (serial : p.activation = s.revision)
      (unused : s.calls = 0) (allowed : s.allowed = true) (policy : owner.policyValid scope s.epoch) :
      Step scope owner s {s with
        revision := s.revision+1, calls := 1,
        permit := none, invocation := some p, unknown := true, observed := none}
  | fullReceipt (s r) (original : s.invocation = some r.call) (invoked : s.calls = 1)
      (bytes : r.bytes = scope.hi - scope.lo) (authentic : owner.receiptValid r) :
      Step scope owner s {s with unknown := false, full := true, receipts := s.receipts ++ [r]}
  | loseReply (s) : Step scope owner s {s with observed := none}
  | partialOrTimeout (s) : Step scope owner s s
  | revoke (s) : Step scope owner s {s with
      epoch := s.epoch+1, revision := s.revision+1,
      fenced := true, allowed := false, permit := none, observed := none}
  | reauthorize (s) (policy : owner.policyValid scope s.epoch) :
      Step scope owner s {s with
        revision := s.revision+1, allowed := true, permit := none, observed := none}

inductive Run (scope : Scope) (owner : Owner) : State → State → Prop where
  | refl (s) : Run scope owner s s
  | next : Run scope owner a b → Step scope owner b d → Run scope owner a d

theorem safe_step (h : Safe scope s) (e : Step scope owner s t) : Safe scope t := by
  rcases h with ⟨count,unknown,full,permit,invocation⟩
  cases e with
  | activate c registered exact closed unused allowed policy =>
    refine ⟨count,unknown,full,?_,invocation⟩
    intro p hp
    have eq : p = issued scope s := (Option.some.inj hp).symm
    subst p; exact ⟨rfl,rfl,rfl,unused,rfl⟩
  | invoke p worker held bound epoch current serial unused allowed policy =>
    have notFull : s.full = false := by
      cases same : s.full with
      | false => rfl
      | true => have bad := (full same).1; omega
    refine ⟨by simp,?_,?_,by simp,?_⟩
    · intro _; exact ⟨rfl,notFull⟩
    · intro bad; simp_all
    · intro actual eq
      have same : actual = p := (Option.some.inj eq).symm
      subst actual; exact ⟨bound,rfl⟩
  | fullReceipt r original invoked bytes authentic =>
    refine ⟨count,by simp,?_,?_,invocation⟩
    · intro _; exact ⟨invoked,rfl⟩
    · intro p hp
      have bad := (permit p hp).2.2.2.1
      omega
  | reauthorize policy => exact ⟨count,unknown,full,by simp,invocation⟩
  | _ => simp_all [Safe]

theorem initialized_safe (run : Run scope owner initial s) : Safe scope s := by
  induction run with
  | refl => simp [Safe,initial]
  | next prior e ih => exact safe_step ih e

theorem call_slot_never_resets (e : Step scope owner s t) (called : s.calls = 1) : t.calls = 1 := by
  cases e <;> simp_all

theorem at_most_one_original_invocation (run : Run scope owner initial s) : s.calls ≤ 1 :=
  (initialized_safe run).1

theorem consumed_slot_cannot_rearm (run : Run scope owner initial s) (called : s.calls = 1) : s.permit = none := by
  cases hp : s.permit with
  | none => rfl
  | some p => have bad := ((initialized_safe run).2.2.2.1 p hp).2.2.2.1; omega

theorem activation_rechecks_original_cut (e : Step scope owner s t)
    (new : t.permit = some p) (changed : t.permit ≠ s.permit) :
    ∃ c, c ∈ s.jobs ∧ c = cut scope s ∧ s.fenced = true ∧ s.calls = 0 ∧
      s.allowed = true ∧ owner.policyValid scope s.epoch ∧ p = issued scope s := by
  cases e with
  | activate c registered exact closed unused allowed policy =>
    exact ⟨c,registered,exact,closed,unused,allowed,policy,(Option.some.inj new).symm⟩
  | fence => simp at new
  | invoke => simp at new
  | revoke => simp at new
  | reauthorize => simp at new
  | _ => exact False.elim (changed rfl)

theorem invocation_rechecks_current_permit (e : Step scope owner s t) (changed : t.calls ≠ s.calls) :
    ∃ p worker, s.permit = some p ∧ p.scope = scope ∧ p.epoch = s.epoch ∧ worker = s.epoch ∧
      p.activation = s.revision ∧ s.calls = 0 ∧ s.allowed = true ∧ owner.policyValid scope s.epoch := by
  cases e with
  | invoke p worker held bound epoch current serial unused allowed policy =>
    exact ⟨p,worker,held,bound,epoch,current,serial,unused,allowed,policy⟩
  | _ => exact False.elim (changed rfl)

theorem published_fence_clears_execution (s : State) :
    ({s with
      epoch := s.epoch+1, revision := s.revision+1, fenced := true,
      permit := none, observed := none} : State).permit = none := rfl

def ReadProvenance (owner : Owner) (s : State) : Prop :=
  (∀ c, s.observed = some c → owner.prefixValid c) ∧ ∀ c ∈ s.jobs, owner.prefixValid c

theorem read_provenance_step (h : ReadProvenance owner s) (e : Step scope owner s t) : ReadProvenance owner t := by
  cases e with
  | certify c closed exact valid =>
    refine ⟨?_,h.2⟩
    intro actual same; have eq := Option.some.inj same; simpa [← eq] using valid
  | prepare seen closed unused =>
    refine ⟨h.1,?_⟩
    intro c member
    rcases List.mem_append.mp member with old | new
    · exact h.2 c old
    · have eq : c = cut scope s := by simpa using new
      subst c; exact h.1 _ seen
  | fence => exact ⟨by simp,h.2⟩
  | activate => exact ⟨by simp,h.2⟩
  | invoke => exact ⟨by simp,h.2⟩
  | loseReply => exact ⟨by simp,h.2⟩
  | revoke => exact ⟨by simp,h.2⟩
  | reauthorize => exact ⟨by simp,h.2⟩
  | _ => exact h

theorem initialized_job_provenance (run : Run scope owner initial s) : ReadProvenance owner s := by
  induction run with
  | refl => simp [ReadProvenance,initial]
  | next prior e ih => exact read_provenance_step ih e

theorem receipt_rechecks_original_call (e : Step scope owner s t) (fresh : r ∈ t.receipts)
    (absent : r ∉ s.receipts) : s.invocation = some r.call ∧ s.calls = 1 ∧
      r.bytes = scope.hi-scope.lo ∧ owner.receiptValid r := by
  cases e with
  | fullReceipt r' original invoked bytes authentic =>
    rcases List.mem_append.mp fresh with old | new
    · exact False.elim (absent old)
    · have eq : r = r' := by simpa using new
      subst r; exact ⟨original,invoked,bytes,authentic⟩
  | _ => exact False.elim (absent fresh)

-- Erase mutable permit generations only in the older local-write abstraction.
-- Authenticity is proved separately above; the erased owner supplies no crypto.
def abstractOwner : Weaver.BrokerConsumptionQueue.ReceiptOwner :=
  ⟨fun _ => True,fun _ => True,fun _ => True,fun _ => True,fun _ => True⟩
def span (scope : Scope) := scope.hi - scope.lo
def originalRange (scope : Scope) : Weaver.BrokerConsumptionQueue.Range := ⟨0,span scope,0⟩
def project (scope : Scope) (s : State) : Weaver.BrokerConsumptionQueue.State :=
  {spent := true,intent := true,accepted := true,frontier := span scope,
   pending := if s.full then none else some (originalRange scope),
   calls := fun i => if i = 0 then s.calls else 0,
   ranges := [originalRange scope],
   fullReceipts := if s.full then [originalRange scope] else [],unknown := s.unknown}

theorem projection_initial_reachable (nonempty : scope.lo < scope.hi) :
    Weaver.BrokerConsumptionQueue.Run abstractOwner (span scope)
      Weaver.BrokerConsumptionQueue.initial (project scope initial) := by
  have positive : 0 < span scope := by unfold span; omega
  let s1 : Weaver.BrokerConsumptionQueue.State := {spent := true}
  let s2 : Weaver.BrokerConsumptionQueue.State := {spent := true,intent := true}
  let s3 : Weaver.BrokerConsumptionQueue.State := {spent := true,intent := true,accepted := true}
  have r1 : Weaver.BrokerConsumptionQueue.Run abstractOwner (span scope) Weaver.BrokerConsumptionQueue.initial s1 :=
    .next (.refl _) (.consume _ rfl)
  have r2 : Weaver.BrokerConsumptionQueue.Run abstractOwner (span scope) Weaver.BrokerConsumptionQueue.initial s2 :=
    .next r1 (.persistIntent _ rfl)
  have r3 : Weaver.BrokerConsumptionQueue.Run abstractOwner (span scope) Weaver.BrokerConsumptionQueue.initial s3 :=
    .next r2 (.accept _ rfl rfl)
  have step := Weaver.BrokerConsumptionQueue.Step.reserveWrite (owner:=abstractOwner) (length:=span scope) s3 (span scope)
    rfl rfl rfl rfl rfl positive (by simp [s3]) True.intro rfl
  have r4 := Weaver.BrokerConsumptionQueue.Run.next r3 step
  simpa [project,initial,originalRange,s3] using r4

theorem projection_step_or_stutter (safe : Safe scope s) (e : Step scope owner s t) :
    Weaver.BrokerConsumptionQueue.Step abstractOwner (span scope) (project scope s) (project scope t) ∨
      project scope t = project scope s := by
  cases e with
  | invoke p worker held bound epoch current serial unused allowed policy =>
    have notUnknown : s.unknown = false := by
      cases eq : s.unknown with
      | false => rfl
      | true => have bad := (safe.2.1 eq).1; omega
    have notFull : s.full = false := by
      cases eq : s.full with
      | false => rfl
      | true => have bad := (safe.2.2.1 eq).1; omega
    left
    have event := Weaver.BrokerConsumptionQueue.Step.invoke (owner:=abstractOwner) (length:=span scope)
      (project scope s) (originalRange scope) 0
      (by simp [project,notFull]) rfl rfl rfl rfl (by simp [project,notUnknown])
      (by simp [project,originalRange,unused]) True.intro rfl
    simpa [project,notFull,originalRange,unused] using event
  | fullReceipt r original invoked bytes authentic =>
    by_cases done : s.full = true
    · right; have known := (safe.2.2.1 done).2; simp [project,done,known]
    · have notFull : s.full = false := by cases eq : s.full <;> simp_all
      left
      have event := Weaver.BrokerConsumptionQueue.Step.fullReceipt (owner:=abstractOwner) (length:=span scope)
        (project scope s) (originalRange scope) (by simp [project,notFull])
        (by simp [project,originalRange,invoked]) rfl True.intro
      simpa [project,notFull] using event
  | _ => right; rfl

theorem initialized_data_path_refines_queue (run : Run scope owner initial s)
    (nonempty : scope.lo < scope.hi) :
    Weaver.BrokerConsumptionQueue.Run abstractOwner (span scope)
      Weaver.BrokerConsumptionQueue.initial (project scope s) := by
  induction run with
  | refl => exact projection_initial_reachable nonempty
  | next prior e ih =>
    rcases projection_step_or_stutter (initialized_safe prior) e with step | same
    · exact .next ih step
    · simpa [same] using ih

theorem unknown_refines_original_hold (run : Run scope owner initial s)
    (nonempty : scope.lo < scope.hi) (unknown : s.unknown = true) :
    Weaver.BrokerConsumptionQueue.Held (project scope s) :=
  Weaver.BrokerConsumptionQueue.unknown_retains_original_hold
    (initialized_data_path_refines_queue run nonempty) unknown

theorem revision_never_decreases (e : Step scope owner s t) : s.revision ≤ t.revision := by
  cases e <;> simp <;> omega

theorem decisions_never_roll_back (e : Step scope owner s t) : s.decisions <+: t.decisions := by
  cases e with
  | activate => exact List.prefix_append _ _
  | _ => exact List.prefix_refl _

theorem prepared_unused_range_has_progress_path (prior : Run scope owner initial s)
    (registered : cut scope s ∈ s.jobs) (closed : s.fenced = true)
    (unused : s.calls = 0) (allowed : s.allowed = true)
    (policy : owner.policyValid scope s.epoch) :
    ∃ t, Run scope owner initial t ∧ t.calls = 1 := by
  let active : State := {s with
    revision := s.revision+1, fenced := false,
    permit := some (issued scope s), decisions := s.decisions ++ [issued scope s], observed := none}
  have activated : Step scope owner s active := .activate s (cut scope s) registered rfl closed unused allowed policy
  have invoked := Step.invoke (scope:=scope) (owner:=owner) active (issued scope s) s.epoch
    rfl rfl rfl rfl rfl unused allowed policy
  exact ⟨_,.next (.next prior activated) invoked,rfl⟩

-- Compose with the original claim and shared account snapshot. The new queue
-- control steps neither allocate a new logical range nor mutate that ledger.
structure Product (c : Weaver.GatewayHeadCAS.Config) (policy : Weaver.GatewayHeadCAS.Owner)
    (scope : Scope) (owner : Owner) (s : State) where
  admission : Weaver.BrokerConsumptionQueue.Admission c policy
  boundRoot : scope.root = admission.key
  boundBudget : scope.budget = c.budget (c.root admission.key)
  boundHistory : scope.history = c.history (c.root admission.key)
  boundClaim : scope.claim = (admission.before.base.messages admission.key).claimToken
  boundManifest : scope.manifest = c.payload admission.key
  boundRoute : ∀ h, admission.before.head = some h → scope.route = h.route
  nonempty : scope.lo < scope.hi
  downstream : Run scope owner initial s

theorem recovery_preserves_original_obligations (p : Product c policy scope owner s) (b) :
    s.calls ≤ 1 ∧ (p.admission.after.base.messages p.admission.key).reserved = true ∧
    (p.admission.after.base.messages p.admission.key).claims ≤ 1 ∧
    (p.admission.after.base.messages p.admission.key).sends ≤ 1 ∧
    Weaver.FiniteDomainMigration.booked c p.admission.after.base b ≤ c.capacity b := by
  have affinity := Weaver.GatewayHeadCAS.original_claim_and_offer_once (.next p.admission.prior p.admission.event) p.admission.key
  exact ⟨at_most_one_original_invocation p.downstream,
    Weaver.BrokerConsumptionQueue.admission_retains_original_reservation p.admission,
    affinity.1,affinity.2,Weaver.GatewayHeadCAS.shared_budget_is_bounded (.next p.admission.prior p.admission.event) b⟩

theorem forgotten_slot_counterexample (scope : Scope) :
    ¬ Safe scope {calls := 2} := by intro h; have bad := h.1; simp at bad

theorem stale_permit_counterexample (scope : Scope) :
    ¬ Safe scope {epoch := 2, permit := some ⟨scope,1,0⟩} := by
  intro h; have bad := (h.2.2.2.1 ⟨scope,1,0⟩ rfl).2.1; simp at bad

theorem unknown_as_full_counterexample (scope : Scope) :
    ¬ Safe scope {calls := 1,unknown := true,full := true} := by
  intro h; have bad := (h.2.1 rfl).2; simp at bad

theorem consumed_rearm_counterexample (scope : Scope) :
    ¬ Safe scope {calls := 1,permit := some ⟨scope,0,0⟩} := by
  intro h; have bad := (h.2.2.2.1 ⟨scope,0,0⟩ rfl).2.2.2.1; simp at bad

#print axioms unknown_refines_original_hold
#print axioms revision_never_decreases
#print axioms decisions_never_roll_back
#print axioms prepared_unused_range_has_progress_path
#print axioms consumed_rearm_counterexample
#print axioms projection_initial_reachable
#print axioms projection_step_or_stutter
#print axioms initialized_data_path_refines_queue
#print axioms initialized_safe
#print axioms call_slot_never_resets
#print axioms at_most_one_original_invocation
#print axioms consumed_slot_cannot_rearm
#print axioms activation_rechecks_original_cut
#print axioms invocation_rechecks_current_permit
#print axioms published_fence_clears_execution
#print axioms initialized_job_provenance
#print axioms receipt_rechecks_original_call
#print axioms recovery_preserves_original_obligations
#print axioms forgotten_slot_counterexample
#print axioms stale_permit_counterexample
#print axioms unknown_as_full_counterexample
end Weaver.LogicalRangeRecovery
