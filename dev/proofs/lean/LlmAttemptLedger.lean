import LlmRouting
namespace Weaver.LlmAttemptLedger
structure Attempt where
  id : Nat
  plan : Weaver.LlmRouting.Plan
  bound : Nat
  epoch : Nat
  deriving DecidableEq
structure Profile where
  duplicateGeneration : Bool
  nonToolInference : Bool
structure Owner where
  router : Weaver.LlmRouting.Owner
  sponsorValid : Nat → Profile → Nat → Prop
  childValid : Attempt → Weaver.LlmRouting.View → Prop
  duplicateValid : Nat → Weaver.LlmRouting.View → Prop
  noExecutionValid : Attempt → Nat → Nat → Prop
  prefixValid : Attempt → Prop
  terminalValid : Attempt → Nat → Prop
  usageValid : Attempt → Nat → Prop
  releaseValid : Attempt → Weaver.LlmRouting.View → Prop
structure State where
  routes : Weaver.LlmRouting.State := Weaver.LlmRouting.initial
  epoch : Nat := 0
  attempts : List Attempt := []
  allocated : Nat := 0
  charged : Nat := 0
  calls : Nat → Nat := fun _ => 0
  retired : Nat → Bool := fun _ => false
  terminal : Nat → Nat := fun _ => 0
  usage : Nat → Option Nat := fun _ => none
  ready : Nat → Bool := fun _ => false
  winner : Option Nat := none
  closed : Bool := false

def initial : State := {}
def total : List Attempt → Nat
  | [] => 0
  | a::tail => a.bound + total tail

def ClosedReady (s : State) : Prop := ∀ a ∈ s.attempts,
  s.retired a.id = true ∧ s.terminal a.id ≠ 0 ∧ (s.usage a.id).isSome = true

def Safe (c : Weaver.LlmRouting.Config) (s : State) : Prop :=
  s.allocated ≤ c.escrow ∧ s.allocated = total s.attempts ∧
  (∀ i, s.calls i ≤ 1) ∧
  (s.closed = true → ClosedReady s) ∧
  (∀ i, s.winner = some i → s.ready i = true) ∧ s.charged ≤ s.allocated

def RetryAllowed (c : Weaver.LlmRouting.Config) (p : Profile) (o : Owner) (s : State) : Prop :=
  s.attempts = [] ∨ (∀ a ∈ s.attempts, s.terminal a.id = 1) ∨
  (p.duplicateGeneration = true ∧ p.nonToolInference = true ∧ o.duplicateValid c.root (Weaver.LlmRouting.view s.routes))

inductive Step (c : Weaver.LlmRouting.Config) (p : Profile) (o : Owner) : State → State → Prop where
  | route (s next) (source : Weaver.LlmRouting.Step c o.router s.routes next)
      (noSend : next.dispatches = s.routes.dispatches) : Step c p o s {s with routes := next}
  | allocate (s plan) (stored : plan ∈ s.routes.plans) (bound : Weaver.LlmRouting.Bound c plan)
      (current : plan.view = Weaver.LlmRouting.view s.routes) (eligible : Weaver.LlmRouting.Eligible c s.routes plan.target)
      (wire : o.router.wireValid plan) (policy : o.router.finalPolicyValid plan (Weaver.LlmRouting.view s.routes))
      (sponsor : o.sponsorValid c.root p c.escrow) (retry : RetryAllowed c p o s)
      (budget : s.allocated + c.costBound s.routes.catalog plan.target ≤ c.escrow)
      (winner : s.winner = none) (openRoot : s.closed = false) :
      Step c p o s {s with
        attempts := s.attempts ++ [⟨s.attempts.length,plan,c.costBound s.routes.catalog plan.target,s.epoch⟩],
        allocated := s.allocated + c.costBound s.routes.catalog plan.target}
  | invoke (s a worker) (registered : a ∈ s.attempts) (epoch : a.epoch = s.epoch) (workerCurrent : worker = s.epoch)
      (live : s.retired a.id = false) (fresh : s.calls a.id = 0) (openRoot : s.closed = false)
      (winner : s.winner = none ∨ s.winner = some a.id)
      (current : a.plan.view = Weaver.LlmRouting.view s.routes)
      (eligible : Weaver.LlmRouting.Eligible c s.routes a.plan.target)
      (wire : o.router.wireValid a.plan) (policy : o.childValid a (Weaver.LlmRouting.view s.routes)) :
      Step c p o s {s with calls := fun i => if i = a.id then 1 else s.calls i}
  | retire (s a) (registered : a ∈ s.attempts) :
      Step c p o s {s with retired := fun i => if i = a.id then true else s.retired i}
  | noExecution (s a) (registered : a ∈ s.attempts) (retired : s.retired a.id = true)
      (fresh : s.terminal a.id = 0) (noPrefix : s.ready a.id = false)
      (valid : o.noExecutionValid a s.epoch (s.calls a.id)) (openRoot : s.closed = false) :
      Step c p o s {s with terminal := fun i => if i = a.id then 1 else s.terminal i}
  | terminal (s a kind) (registered : a ∈ s.attempts) (called : s.calls a.id = 1)
      (fresh : s.terminal a.id = 0) (kindValid : kind = 2 ∨ kind = 3)
      (valid : o.terminalValid a kind) (openRoot : s.closed = false) :
      Step c p o s {s with terminal := fun i => if i = a.id then kind else s.terminal i}
  | prefixReady (s a) (registered : a ∈ s.attempts) (called : s.calls a.id = 1)
      (notNegative : s.terminal a.id ≠ 1) (valid : o.prefixValid a) (openRoot : s.closed = false) :
      Step c p o s {s with ready := fun i => if i = a.id then true else s.ready i}
  | commitWinner (s a) (registered : a ∈ s.attempts) (called : s.calls a.id = 1)
      (ready : s.ready a.id = true) (fresh : s.winner = none)
      (release : o.releaseValid a (Weaver.LlmRouting.view s.routes)) (openRoot : s.closed = false) :
      Step c p o s {s with winner := some a.id}
  | finalUsage (s a amount) (registered : a ∈ s.attempts) (retired : s.retired a.id = true)
      (terminal : s.terminal a.id ≠ 0) (fresh : s.usage a.id = none) (bounded : amount ≤ a.bound)
      (totalBound : s.charged + amount ≤ s.allocated) (valid : o.usageValid a amount) (openRoot : s.closed = false) :
      Step c p o s {s with charged := s.charged+amount, usage := fun i => if i = a.id then some amount else s.usage i}
  | restart (s) : Step c p o s {s with epoch := s.epoch+1, retired := fun _ => true}
  | close (s) (ready : ClosedReady s) (fresh : s.closed = false) : Step c p o s {s with closed := true}
  | lostReplyOrTimeout (s) : Step c p o s s

inductive Run (c : Weaver.LlmRouting.Config) (p : Profile) (o : Owner) : State → State → Prop where
  | refl (s) : Run c p o s s
  | next : Run c p o a b → Step c p o b d → Run c p o a d

theorem total_append (xs ys) : total (xs ++ ys) = total xs + total ys := by
  induction xs with
  | nil => simp [total]
  | cons x tail ih => simp [total,ih,Nat.add_assoc]

theorem safe_step (h : Safe c s) (e : Step c p o s t) : Safe c t := by
  rcases h with ⟨budget,totalBound,calls,closed,winnerReady,charges⟩
  cases e with
  | allocate plan stored bound current eligible wire policy sponsor retry hb winner openRoot =>
    refine ⟨hb,?_,calls,?_,?_,?_⟩
    · simp [total_append,total,totalBound]
    · intro bad; simp_all
    · intro i hi; simp_all
    · dsimp; omega
  | invoke a worker registered epoch workerCurrent live fresh openRoot winner current eligible wire policy =>
    refine ⟨budget,totalBound,?_,?_,winnerReady,charges⟩
    · intro i; dsimp; split <;> simp_all
    · intro bad; simp_all
  | noExecution a registered retired fresh noPrefix valid openRoot =>
    exact ⟨budget,totalBound,calls,by intro bad; simp_all,winnerReady,charges⟩
  | terminal a kind registered called fresh kindValid valid openRoot =>
    exact ⟨budget,totalBound,calls,by intro bad; simp_all,winnerReady,charges⟩
  | prefixReady a registered called notNegative valid openRoot =>
    refine ⟨budget,totalBound,calls,by intro bad; simp_all,?_,charges⟩
    intro i hi; dsimp; split <;> simp_all
  | commitWinner a registered called ready fresh release openRoot =>
    refine ⟨budget,totalBound,calls,closed,?_,charges⟩
    intro i eq; have same := Option.some.inj eq; simpa [← same] using ready
  | finalUsage a amount registered retired terminal fresh bounded chargeBound valid openRoot =>
    exact ⟨budget,totalBound,calls,by intro bad; simp_all,winnerReady,chargeBound⟩
  | retire a registered =>
    refine ⟨budget,totalBound,calls,?_,winnerReady,charges⟩
    intro hc a' ha
    have original := closed hc a' ha
    refine ⟨?_,original.2⟩
    dsimp; split <;> simp_all
  | restart =>
    refine ⟨budget,totalBound,calls,?_,winnerReady,charges⟩
    intro hc a ha; have original := closed hc a ha; exact ⟨rfl,original.2⟩
  | close ready fresh => exact ⟨budget,totalBound,calls,by intro _; exact ready,winnerReady,charges⟩
  | _ => exact ⟨budget,totalBound,calls,closed,winnerReady,charges⟩

theorem initialized_safe (run : Run c p o initial s) : Safe c s := by
  induction run with
  | refl => simp [Safe,initial,total,ClosedReady]
  | next prior e ih => exact safe_step ih e

theorem allocated_never_reopens (e : Step c p o s t) : s.allocated ≤ t.allocated := by
  cases e <;> simp <;> omega

theorem each_child_invoked_at_most_once (run : Run c p o initial s) (id) : s.calls id ≤ 1 :=
  (initialized_safe run).2.2.1 id

theorem finite_attempt_budget_is_bounded (run : Run c p o initial s) :
    total s.attempts ≤ c.escrow := by
  have h := initialized_safe run; simpa [← h.2.1] using h.1

theorem winner_never_switches (id : Nat) (e : Step c p o s t) (committed : s.winner = some id) : t.winner = some id := by
  cases e with
  | commitWinner a registered called ready fresh release openRoot => simp_all
  | _ => exact committed

theorem unknown_usage_prevents_close (run : Run c p o initial s) (registered : a ∈ s.attempts)
    (unknown : s.usage a.id = none) : s.closed = false := by
  cases eq : s.closed with
  | false => rfl
  | true => have bad := ((initialized_safe run).2.2.2.1 eq a registered).2.2; simp [unknown] at bad

theorem unsettled_attempt_prevents_close (run : Run c p o initial s) (registered : a ∈ s.attempts)
    (pending : s.terminal a.id = 0) : s.closed = false := by
  cases eq : s.closed with
  | false => rfl
  | true => have bad := ((initialized_safe run).2.2.2.1 eq a registered).2.1; exact False.elim (bad pending)

theorem new_allocation_requires_sponsored_retry (e : Step c p o s t)
    (changed : t.attempts ≠ s.attempts) :
    o.sponsorValid c.root p c.escrow ∧ RetryAllowed c p o s ∧ s.winner = none ∧ s.closed = false := by
  cases e with
  | allocate plan stored bound current eligible wire policy sponsor retry hb winner openRoot => exact ⟨sponsor,retry,winner,openRoot⟩
  | _ => exact False.elim (changed rfl)

theorem invocation_rechecks_current_route (id : Nat) (e : Step c p o s t) (changed : t.calls id ≠ s.calls id) :
    ∃ a, a ∈ s.attempts ∧ a.epoch = s.epoch ∧ s.retired a.id = false ∧
      a.plan.view = Weaver.LlmRouting.view s.routes ∧ Weaver.LlmRouting.Eligible c s.routes a.plan.target ∧
      o.childValid a (Weaver.LlmRouting.view s.routes) := by
  cases e with
  | invoke a worker registered epoch workerCurrent live fresh openRoot winner current eligible wire policy =>
    exact ⟨a,registered,epoch,live,current,eligible,policy⟩
  | _ => exact False.elim (changed rfl)

structure RootSponsor (c : Weaver.LlmRouting.Config) (p : Profile) (source : Weaver.GatewayHeadCAS.Config)
    (policy : Weaver.GatewayHeadCAS.Owner) (o : Owner) where
  admission : Weaver.BrokerConsumptionQueue.Admission source policy
  root : c.root = admission.key
  allowance : c.escrow = source.cost admission.key
  taskScope : o.sponsorValid c.root p c.escrow

theorem child_total_fits_original_root (sponsor : RootSponsor c p source policy o)
    (run : Run c p o initial s) : total s.attempts ≤ source.cost sponsor.admission.key := by
  rw [← sponsor.allowance]; exact finite_attempt_budget_is_bounded run

theorem shared_account_capacity_remains_booked (sponsor : RootSponsor c p source policy o) (account) :
    Weaver.FiniteDomainMigration.booked source sponsor.admission.after.base account ≤ source.capacity account :=
  Weaver.GatewayHeadCAS.shared_budget_is_bounded (.next sponsor.admission.prior sponsor.admission.event) account

theorem original_root_claim_remains_unique (sponsor : RootSponsor c p source policy o) :
    (sponsor.admission.after.base.messages sponsor.admission.key).claims ≤ 1 ∧
    (sponsor.admission.after.base.messages sponsor.admission.key).sends ≤ 1 :=
  Weaver.GatewayHeadCAS.original_claim_and_offer_once (.next sponsor.admission.prior sponsor.admission.event) sponsor.admission.key

theorem observed_charges_fit_original_root (run : Run c p o initial s) : s.charged ≤ c.escrow := by
  have h := initialized_safe run
  exact Nat.le_trans h.2.2.2.2.2 h.1

theorem winner_locks_child_allocation (id : Nat) (e : Step c p o s t)
    (committed : s.winner = some id) : t.attempts = s.attempts := by
  cases e with
  | allocate plan stored bound current eligible wire policy sponsor retry hb winner openRoot => simp_all
  | _ => rfl

theorem usage_change_requires_registered_fresh_evidence (id : Nat) (e : Step c p o s t)
    (changed : t.usage id ≠ s.usage id) :
    ∃ a amount, a ∈ s.attempts ∧ s.retired a.id = true ∧ s.terminal a.id ≠ 0 ∧
      s.usage a.id = none ∧ amount ≤ a.bound ∧ o.usageValid a amount := by
  cases e with
  | finalUsage a amount registered retired terminal fresh bounded chargeBound valid openRoot =>
    exact ⟨a,amount,registered,retired,terminal,fresh,bounded,valid⟩
  | _ => exact False.elim (changed rfl)

#print axioms observed_charges_fit_original_root
#print axioms winner_locks_child_allocation
#print axioms usage_change_requires_registered_fresh_evidence
#print axioms initialized_safe
#print axioms allocated_never_reopens
#print axioms each_child_invoked_at_most_once
#print axioms finite_attempt_budget_is_bounded
#print axioms winner_never_switches
#print axioms unknown_usage_prevents_close
#print axioms unsettled_attempt_prevents_close
#print axioms new_allocation_requires_sponsored_retry
#print axioms invocation_rechecks_current_route
#print axioms child_total_fits_original_root
#print axioms shared_account_capacity_remains_booked
#print axioms original_root_claim_remains_unique
end Weaver.LlmAttemptLedger
