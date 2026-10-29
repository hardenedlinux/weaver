import FiniteDomainMigration
namespace Weaver.GatewayHeadCAS
open Weaver.LogicalMessageAuthority (update)
abbrev Ledger := Weaver.FiniteDomainMigration.Ledger
abbrev Config := Weaver.FiniteDomainMigration.Config
structure Head where
  id : Nat
  key : Nat
  domain : Nat
  budget : Nat
  history : Nat
  payload : Nat
  claimToken : Nat
  claimStream : Nat
  route : Nat
  policy : Nat
  deriving DecidableEq
structure View where
  head : Head
  version : Nat
  worker : Nat
  fence : Nat
  semanticRevision : Nat
  deriving DecidableEq
structure Job where
  id : Nat
  view : View
  deriving DecidableEq
structure Decision where
  job : Job
  snapshot : View
  deriving DecidableEq
structure Joined where
  view : View
  decisions : List Decision
  rows : List Decision
  boot : Nat
  deriving DecidableEq
structure Send where
  decision : Decision
  snapshot : View
  key : Nat
  route : Nat
  payload : Nat
  deriving DecidableEq
structure Owner where
  headReadValid : View → Prop
  policyAllows : Head → Ledger → Prop
  casValid : Job → View → Prop
  rowValid : Decision → Prop
  joinValid : Joined → Prop
structure State where
  base : Ledger := Weaver.FiniteDomainMigration.empty
  head : Option Head := none
  heads : List Head := []
  version : Nat := 0
  worker : Nat := 0
  fence : Nat := 0
  boot : Nat := 0
  observed : Option View := none
  jobs : List Job := []
  decisions : List Decision := []
  rows : List Decision := []
  joined : Option Joined := none
  sends : List Send := []
  authorityOnline : Bool := true
  projectionOnline : Bool := true

def initial : State := {}
def view (s : State) (h : Head) : View := ⟨h,s.version,s.worker,s.fence,s.base.revision⟩
def joinedView (s : State) (h : Head) : Joined := ⟨view s h,s.decisions,s.rows,s.boot⟩
def Canonical (c : Config) (s : State) (h : Head) : Prop := h.key ∈ c.keys ∧ h.domain = c.root h.key ∧
  h.budget = c.budget h.domain ∧ h.history = c.history h.domain ∧ h.payload = c.payload h.key ∧
  (s.base.messages h.key).claimed = true ∧ (s.base.messages h.key).reserved = true ∧
  h.claimToken = (s.base.messages h.key).claimToken ∧ h.claimStream = (s.base.messages h.key).claimStream

def Unresolved (s : State) (key : Nat) : Prop := ∀ d ∈ s.decisions, d.job.view.head.key ≠ key
def UniqueRoots (s : State) : Prop := ∀ a ∈ s.decisions, ∀ b ∈ s.decisions, a.job.view.head.key = b.job.view.head.key → a = b
def RowsBound (s : State) : Prop := ∀ d ∈ s.rows, d ∈ s.decisions
def Audit (s : State) : Prop := ∀ d ∈ s.decisions, d.job.view = d.snapshot
def JoinReady (s : State) (h : Head) : Prop := s.joined = some (joinedView s h) ∧
  (∀ d ∈ s.decisions, d ∈ s.rows) ∧ s.authorityOnline = true ∧ s.projectionOnline = true

inductive Step (c : Config) (owner : Owner) : State → State → Prop where
  | semantic (s next) (source : Weaver.FiniteDomainMigration.Transition c s.base next)
      (noSend : ∀ k, (next.messages k).sends = (s.base.messages k).sends) :
      Step c owner s {s with base := next, observed := none, joined := none}
  | changeHead (s h worker) (online : s.authorityOnline = true) (session : worker = s.worker)
      (canonical : Canonical c s h) (fresh : h.id = s.heads.length) :
      Step c owner s {s with head := some h, heads := s.heads ++ [h], version := s.version + 1, fence := s.fence + 1, observed := none, joined := none}
  | restoreHead (s h worker) (online : s.authorityOnline = true) (session : worker = s.worker)
      (historical : h ∈ s.heads) (canonical : Canonical c s h) :
      Step c owner s {s with head := some h, version := s.version + 1, fence := s.fence + 1, observed := none, joined := none}
  | republish (s h) (online : s.authorityOnline = true) (held : s.head = some h) :
      Step c owner s {s with version := s.version + 1, observed := none, joined := none}
  | observeHead (s h v) (online : s.authorityOnline = true) (held : s.head = some h)
      (exact : v = view s h) (authentic : owner.headReadValid v) : Step c owner s {s with observed := some v}
  | prepare (s h) (online : s.authorityOnline = true) (held : s.head = some h)
      (seen : s.observed = some (view s h)) (canonical : Canonical c s h) (freshRoot : Unresolved s h.key) :
      Step c owner s {s with jobs := s.jobs ++ [⟨s.jobs.length,view s h⟩]}
  | commit (s h j worker) (online : s.authorityOnline = true) (held : s.head = some h)
      (registered : j ∈ s.jobs) (session : worker = s.worker) (workerBound : j.view.worker = worker)
      (exact : j.view = view s h) (seen : s.observed = some j.view)
      (canonical : Canonical c s h) (policy : owner.policyAllows h s.base) (freshRoot : Unresolved s h.key)
      (authentic : owner.casValid j (view s h)) :
      Step c owner s {s with decisions := s.decisions ++ [⟨j,view s h⟩], version := s.version + 1, observed := none, joined := none}
  | applyRow (s d) (online : s.projectionOnline = true) (decided : d ∈ s.decisions)
      (fresh : d ∉ s.rows) (authentic : owner.rowValid d) : Step c owner s {s with rows := s.rows ++ [d], joined := none}
  | retryRow (s d) (online : s.projectionOnline = true) (decided : d ∈ s.decisions) (stored : d ∈ s.rows)
      (authentic : owner.rowValid d) : Step c owner s {s with joined := none}
  | observeJoin (s h j) (online : s.authorityOnline = true ∧ s.projectionOnline = true) (held : s.head = some h)
      (exact : j = joinedView s h) (materialized : ∀ d ∈ s.decisions, d ∈ s.rows)
      (authentic : owner.joinValid j) : Step c owner s {s with joined := some j}
  | send (s next h d key route payload) (source : Weaver.FiniteDomainMigration.Transition c s.base next)
      (held : s.head = some h) (joined : JoinReady s h) (decided : d ∈ s.decisions) (selected : d.job.view.head = h)
      (canonical : Canonical c s h) (policy : owner.policyAllows h s.base)
      (effect : key = h.key ∧ route = h.route ∧ payload = h.payload)
      (offered : (next.messages key).sends = (s.base.messages key).sends + 1)
      (onlyKey : ∀ k, k ≠ key → (next.messages k).sends = (s.base.messages k).sends) :
      Step c owner s {s with base := next, sends := s.sends ++ [⟨d,view s h,key,route,payload⟩], observed := none, joined := none}
  | restartBroker (s) : Step c owner s {s with worker := s.worker + 1, fence := s.fence + 1, version := s.version + 1, boot := s.boot + 1, observed := none, joined := none}
  | restartClient (s) : Step c owner s {s with boot := s.boot + 1, observed := none, joined := none}
  | rollbackProjection (s) : Step c owner s {s with rows := [], joined := none}
  | authorityPartition (s) : Step c owner s {s with authorityOnline := false, observed := none, joined := none}
  | projectionPartition (s) : Step c owner s {s with projectionOnline := false, joined := none}
  | reconnect (s) : Step c owner s {s with authorityOnline := true, projectionOnline := true}
  | loseReply (s) : Step c owner s {s with observed := none, joined := none}

inductive Run (c : Config) (owner : Owner) : State → State → Prop where
  | refl (s) : Run c owner s s
  | next : Run c owner a b → Step c owner b d → Run c owner a d

variable {c : Config} {owner : Owner}

theorem decisions_never_roll_back (e : Step c owner s t) : s.decisions <+: t.decisions := by
  cases e with
  | commit => exact List.prefix_append _ _
  | _ => exact List.prefix_refl _

theorem unique_roots_step (h : UniqueRoots s) (e : Step c owner s t) : UniqueRoots t := by
  cases e with
  | commit head job worker online held registered session workerBound exact seen canonical policy freshRoot authentic =>
    intro a ha b hb same
    have key : job.view.head.key = head.key := congrArg (fun v : View => v.head.key) exact
    rcases List.mem_append.mp ha with ha | ha
    · rcases List.mem_append.mp hb with hb | hb
      · exact h a ha b hb same
      · have eq : b = ⟨job,view s head⟩ := by simpa using hb
        subst b; exact False.elim (freshRoot a ha (same.trans key))
    · have eq : a = ⟨job,view s head⟩ := by simpa using ha
      subst a
      rcases List.mem_append.mp hb with hb | hb
      · exact False.elim (freshRoot b hb (same.symm.trans key))
      · have eq : b = ⟨job,view s head⟩ := by simpa using hb
        exact eq.symm
  | _ => exact h

theorem rows_bound_step (h : RowsBound s) (e : Step c owner s t) : RowsBound t := by
  have persists := decisions_never_roll_back e
  cases e with
  | applyRow d online decided fresh authentic =>
    intro d' member
    rcases List.mem_append.mp member with old | new
    · exact h d' old
    · have eq : d' = d := by simpa using new
      subst d'; exact decided
  | commit => exact fun d hd => persists.subset (h d hd)
  | rollbackProjection => simp [RowsBound]
  | _ => exact h

theorem audit_step (h : Audit s) (e : Step c owner s t) : Audit t := by
  cases e with
  | commit head job worker online held registered session workerBound exact seen canonical policy freshRoot authentic =>
    intro d member
    rcases List.mem_append.mp member with old | new
    · exact h d old
    · have eq : d = ⟨job,view s head⟩ := by simpa using new
      subst d; exact exact
  | _ => exact h

theorem initialized_unique_roots (events : Run c owner initial s) : UniqueRoots s := by
  induction events with
  | refl => simp [UniqueRoots,initial]
  | next prior e ih => exact unique_roots_step ih e

theorem initialized_rows_are_committed (events : Run c owner initial s) : RowsBound s := by
  induction events with
  | refl => simp [RowsBound,initial]
  | next prior e ih => exact rows_bound_step ih e

theorem initialized_cas_audit (events : Run c owner initial s) : Audit s := by
  induction events with
  | refl => simp [Audit,initial]
  | next prior e ih => exact audit_step ih e

theorem every_new_decision_rechecks_current_head (e : Step c owner s t) (new : t.decisions ≠ s.decisions) :
    ∃ head job, s.head = some head ∧ job ∈ s.jobs ∧ job.view = view s head ∧
      job.view.worker = s.worker ∧ s.observed = some job.view ∧ Unresolved s head.key ∧ owner.casValid job (view s head) := by
  cases e with
  | commit head job worker online held registered session workerBound exact seen canonical policy freshRoot authentic =>
    exact ⟨head,job,held,registered,exact,workerBound.trans session,seen,freshRoot,authentic⟩
  | _ => exact False.elim (new rfl)

theorem version_never_decreases (e : Step c owner s t) : s.version ≤ t.version := by
  cases e <;> simp

theorem changed_fence_clears_cached_authority (e : Step c owner s t) (changed : t.fence ≠ s.fence) : t.observed = none ∧ t.joined = none := by
  cases e with
  | changeHead => exact ⟨rfl,rfl⟩
  | restoreHead => exact ⟨rfl,rfl⟩
  | restartBroker => exact ⟨rfl,rfl⟩
  | _ => exact False.elim (changed rfl)

theorem new_send_requires_exact_current_join (e : Step c owner s t) (changed : t.sends ≠ s.sends) :
    ∃ head d key route payload, s.head = some head ∧ JoinReady s head ∧ d ∈ s.decisions ∧
      d.job.view.head = head ∧ Canonical c s head ∧ owner.policyAllows head s.base ∧
      key = head.key ∧ route = head.route ∧ payload = head.payload := by
  cases e with
  | send next head d key route payload source held joined decided selected canonical policy effect =>
    exact ⟨head,d,key,route,payload,held,joined,decided,selected,canonical,policy,effect⟩
  | _ => exact False.elim (changed rfl)

theorem logical_projection (e : Step c owner s t) : Weaver.FiniteDomainMigration.Transition c s.base t.base := by
  cases e with
  | semantic next source => exact source
  | send next head d key route payload source => exact source
  | _ => exact .resumeOldWorker _

theorem initialized_product_refines_semantics (events : Run c owner initial s) : Weaver.FiniteDomainMigration.Reachable c s.base := by
  induction events with
  | refl => exact .init
  | next prior e ih => exact .next ih (logical_projection e)

theorem original_claim_and_history_survive (e : Step c owner s t) (claimed : (s.base.messages k).claimed = true)
    (history : (s.base.messages k).history = true) :
    (t.base.messages k).claimed = true ∧ (t.base.messages k).claimToken = (s.base.messages k).claimToken ∧
      (t.base.messages k).claimStream = (s.base.messages k).claimStream ∧ (t.base.messages k).history = true :=
  Weaver.FiniteDomainMigration.claim_and_history_survive (logical_projection e) claimed history

theorem original_executor_survives (e : Step c owner s t) (claimed : (s.base.messages k).claimed = true) :
    t.base.claimOwner k = s.base.claimOwner k := Weaver.FiniteDomainMigration.claim_executor_stamp_is_sticky (logical_projection e) claimed

theorem shared_budget_is_bounded (events : Run c owner initial s) (b) : Weaver.FiniteDomainMigration.booked c s.base b ≤ c.capacity b :=
  Weaver.FiniteDomainMigration.finite_budget_bound (initialized_product_refines_semantics events) b

theorem original_claim_and_offer_once (events : Run c owner initial s) (k) :
    (s.base.messages k).claims ≤ 1 ∧ (s.base.messages k).sends ≤ 1 :=
  Weaver.FiniteDomainMigration.per_message_affinity (initialized_product_refines_semantics events) k

theorem free_held_charged_conservation (events : Run c owner initial s) (b) :
    c.capacity b - Weaver.FiniteDomainMigration.booked c s.base b +
      Weaver.FiniteDomainMigration.sumKeys c.keys (Weaver.FiniteDomainMigration.heldCost c s.base b) +
      Weaver.FiniteDomainMigration.sumKeys c.keys (Weaver.FiniteDomainMigration.chargedCost c s.base b) = c.capacity b :=
  Weaver.FiniteDomainMigration.finite_free_held_charged_conservation (initialized_product_refines_semantics events) b
theorem unknown_original_reservation_survives (e : Step c owner s t) (reserved : (s.base.messages k).reserved = true) :
    (t.base.messages k).reserved = true := by
  rcases Weaver.FiniteDomainMigration.local_step_or_stutter (logical_projection e) k with localStep | same
  · have keep : ∀ {a b : Weaver.LogicalMessageAuthority.State}, Weaver.LogicalMessageAuthority.Step a b → a.reserved = true → b.reserved = true := by
      intro a b step held
      cases step <;> simp_all
    exact keep localStep reserved
  · simpa [same] using reserved

theorem newly_committed_job_has_current_scope (e : Step c owner s t)
    (member : d ∈ t.decisions) (new : d ∉ s.decisions) :
    ∃ head, s.head = some head ∧ d.job.view = view s head ∧ d.snapshot = view s head := by
  cases e with
  | commit head job worker online held registered session workerBound exact seen canonical policy freshRoot authentic =>
    rcases List.mem_append.mp member with old | appended
    · exact False.elim (new old)
    · have eq : d = ⟨job,view s head⟩ := by simpa using appended
      subst d; exact ⟨head,held,exact,rfl⟩
  | _ => exact False.elim (new member)

theorem prepared_row_is_not_committed_counterexample (j : Job) :
    ¬ RowsBound {jobs := [j], rows := [⟨j,j.view⟩]} := by
  simp [RowsBound]

theorem duplicate_root_decision_counterexample (d : Decision) :
    ¬ UniqueRoots {decisions := [d,{d with job := {d.job with id := d.job.id + 1}}]} := by
  intro unique
  have bad := unique d (by simp) {d with job := {d.job with id := d.job.id + 1}} (by simp) rfl
  have ids := congrArg (fun r : Decision => r.job.id) bad
  simp at ids

theorem stale_fence_decision_counterexample (j : Job) :
    ¬ Audit {decisions := [⟨j,{j.view with fence := j.view.fence + 1}⟩]} := by
  intro audit
  have bad := audit ⟨j,{j.view with fence := j.view.fence + 1}⟩ (by simp)
  have fences := congrArg View.fence bad
  simp at fences

theorem nonce_consumption_once (events : Run c owner initial s) (k nonce) : (s.base.messages k).consumes nonce ≤ 1 :=
  ((Weaver.FiniteDomainMigration.reachable_invariant (initialized_product_refines_semantics events)).messages k).1 nonce

theorem new_join_requires_authentic_current_images (e : Step c owner s t) (changed : t.joined ≠ s.joined)
    (accepted : t.joined = some receipt) : ∃ head, s.head = some head ∧ receipt = joinedView s head ∧
      (∀ d ∈ s.decisions, d ∈ s.rows) ∧ owner.joinValid receipt := by
  cases e with
  | observeJoin head j online held exact materialized authentic =>
    have eq : j = receipt := Option.some.inj accepted
    refine ⟨head,held,eq.symm.trans exact,materialized,?_⟩
    simpa [eq] using authentic
  | observeHead => exact False.elim (changed rfl)
  | prepare => exact False.elim (changed rfl)
  | reconnect => exact False.elim (changed rfl)
  | _ => simp at accepted

theorem actual_logical_offer_requires_broker_authority (e : Step c owner s t)
    (changed : (t.base.messages k).sends ≠ (s.base.messages k).sends) :
    ∃ head d, s.head = some head ∧ head.key = k ∧ JoinReady s head ∧ d ∈ s.decisions ∧
      d.job.view.head = head ∧ Canonical c s head ∧ owner.policyAllows head s.base := by
  cases e with
  | semantic next source noSend => exact False.elim (changed (noSend k))
  | send next head d key route payload source held joined decided selected canonical policy effect offered onlyKey =>
    have same : k = key := by
      by_cases eq : k = key
      · exact eq
      · exact False.elim (changed (onlyKey k eq))
    subst k
    exact ⟨head,d,held,effect.1.symm,joined,decided,selected,canonical,policy⟩
  | _ => exact False.elim (changed rfl)

#print axioms actual_logical_offer_requires_broker_authority
#print axioms nonce_consumption_once
#print axioms new_join_requires_authentic_current_images
#print axioms unknown_original_reservation_survives
#print axioms newly_committed_job_has_current_scope
#print axioms prepared_row_is_not_committed_counterexample
#print axioms duplicate_root_decision_counterexample
#print axioms stale_fence_decision_counterexample
#print axioms decisions_never_roll_back
#print axioms initialized_unique_roots
#print axioms initialized_rows_are_committed
#print axioms initialized_cas_audit
#print axioms every_new_decision_rechecks_current_head
#print axioms version_never_decreases
#print axioms changed_fence_clears_cached_authority
#print axioms new_send_requires_exact_current_join
#print axioms initialized_product_refines_semantics
#print axioms original_claim_and_history_survive
#print axioms original_executor_survives
#print axioms shared_budget_is_bounded
#print axioms original_claim_and_offer_once
#print axioms free_held_charged_conservation
end Weaver.GatewayHeadCAS
