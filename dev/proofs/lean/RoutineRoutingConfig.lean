import LlmRouting
namespace Weaver.RoutineRoutingConfig
abbrev RouterConfig := LlmRouting.Config
structure Normal where
  root : Nat
  payload : Nat
  profile : Nat
  node : Nat
  response : Nat
  requirements : List Nat
  targets : List Nat
  allowance : Nat
  contextNeeded : Nat
  region : Nat
  deriving DecidableEq
-- These are semantic constraints of the admitted task, never caller labels.
structure Refines (base : RouterConfig) (profile node response : Nat) (n : Normal) : Prop where
  root : n.root = base.root
  payload : n.payload = base.payload
  profile : n.profile = profile
  node : n.node = node
  response : n.response = response
  requirements : ∀ r ∈ base.requirements, r ∈ n.requirements
  allowance : n.allowance ≤ base.escrow
  context : base.contextNeeded ≤ n.contextNeeded
  region : n.region = base.regionNeeded

def lower (base : RouterConfig) (n : Normal) : RouterConfig :=
  {base with
    requirements := n.requirements
    contextNeeded := n.contextNeeded
    escrow := n.allowance
    catalog := fun generation => (base.catalog generation).filter (fun m => decide (m ∈ n.targets))}

structure Package where
  normal : Normal
  sourceClosure : Nat
  contractClosure : Nat
  policyArtifact : Nat
  adapterClosure : Nat
structure CompilerOwner where
  -- Native closure/source/contract admission, not a hash-equality shortcut.
  admitted : Package → Prop
  currentAtCAS : Package → LlmRouting.View → LlmRouting.Plan → Prop

def executionOwner (native : LlmRouting.Owner) (compiler : CompilerOwner) (pkg : Package) : LlmRouting.Owner :=
  {wireValid := native.wireValid,
   finalPolicyValid := fun p v => native.finalPolicyValid p v ∧ compiler.admitted pkg ∧ compiler.currentAtCAS pkg v p,
   responseValid := native.responseValid}

theorem eligible_is_narrowed (valid : Refines base profile node response n)
    (eligible : LlmRouting.Eligible (lower base n) s m) : LlmRouting.Eligible base s m := by
  rcases eligible with ⟨catalog,supports,context,region,policy,history,cost,available⟩
  have selected : m ∈ base.catalog s.catalog ∧ m ∈ n.targets := by
    simpa [lower,List.mem_filter] using catalog
  exact ⟨selected.1,fun r hr => supports r (valid.requirements r hr),
    Nat.le_trans valid.context context,region,policy,history,Nat.le_trans cost valid.allowance,available⟩

theorem selected_target_is_declared (eligible : LlmRouting.Eligible (lower base n) s m) : m ∈ n.targets := by
  have h : m ∈ base.catalog s.catalog ∧ m ∈ n.targets := by
    simpa [lower,List.mem_filter] using eligible.1
  exact h.2

theorem original_budget_is_bound (valid : Refines base profile node response n)
    (eligible : LlmRouting.Eligible (lower base n) s m) : base.costBound s.catalog m ≤ base.escrow :=
  LlmRouting.selected_cost_within_original_escrow (eligible_is_narrowed valid eligible)

theorem required_capability_preserved (valid : Refines base profile node response n)
    (eligible : LlmRouting.Eligible (lower base n) s m) (required : r ∈ base.requirements) :
    base.supports s.catalog m r := (eligible_is_narrowed valid eligible).2.1 r required

theorem history_cannot_be_overridden (valid : Refines base profile node response n)
    (eligible : LlmRouting.Eligible (lower base n) s m) : base.historyAllows s.history m :=
  (eligible_is_narrowed valid eligible).2.2.2.2.2.1

theorem same_normal_same_runtime {a b : Package} (same : a.normal = b.normal) : lower base a.normal = lower base b.normal := by
  rw [same]

theorem all_surfaces_share_runtime {a b c : Package} (schemeJson : a.normal = b.normal) (schemeYaml : a.normal = c.normal) :
    lower base a.normal = lower base b.normal ∧ lower base a.normal = lower base c.normal :=
  ⟨same_normal_same_runtime schemeJson,same_normal_same_runtime schemeYaml⟩

theorem source_provenance_is_separate {a b : Package} (same : a.normal = b.normal) :
    lower base a.normal = lower base b.normal := same_normal_same_runtime same

theorem provenance_changes_without_semantic_change (pkg : Package) :
    ({pkg with sourceClosure := pkg.sourceClosure+1} : Package).normal = pkg.normal ∧
    ({pkg with sourceClosure := pkg.sourceClosure+1} : Package) ≠ pkg := by
  constructor
  · rfl
  · intro same
    have impossible := congrArg Package.sourceClosure same
    simp at impossible

theorem task_identity_is_fixed (valid : Refines base profile node response n) :
    n.root = base.root ∧ n.payload = base.payload ∧ n.profile = profile ∧ n.node = node ∧ n.response = response :=
  ⟨valid.root,valid.payload,valid.profile,valid.node,valid.response⟩

theorem dropped_capability_rejected (missing : ∃ r, r ∈ base.requirements ∧ r ∉ n.requirements) :
    ¬ Refines base profile node response n := by
  intro valid; obtain ⟨r,required,absent⟩ := missing
  exact absent (valid.requirements r required)

theorem enlarged_allowance_rejected (excess : base.escrow < n.allowance) :
    ¬ Refines base profile node response n := by
  intro valid; have bound := valid.allowance; omega

theorem changed_profile_rejected (wrong : n.profile ≠ profile) : ¬ Refines base profile node response n := by
  intro valid; exact wrong valid.profile

theorem changed_response_rejected (wrong : n.response ≠ response) : ¬ Refines base profile node response n := by
  intro valid; exact wrong valid.response

theorem no_empty_route_fallback (none : n.targets = []) : ¬ LlmRouting.Eligible (lower base n) s m := by
  intro eligible
  have member := selected_target_is_declared eligible
  simp [none] at member

theorem final_dispatch_rechecks_parent (valid : Refines base profile node response n)
    (event : LlmRouting.Step (lower base n) owner s t) (changed : t.dispatches ≠ s.dispatches) :
    ∃ p, LlmRouting.Bound base p ∧ LlmRouting.Eligible base s p.target ∧
      p.view = LlmRouting.view s ∧ owner.wireValid p ∧ owner.finalPolicyValid p (LlmRouting.view s) := by
  obtain ⟨p,stored,bound,current,eligible,wire,policy,fresh⟩ := LlmRouting.actual_dispatch_rechecks_target event changed
  exact ⟨p,bound,eligible_is_narrowed valid eligible,current,wire,policy⟩

theorem artifact_current_at_dispatch
    (event : LlmRouting.Step (lower base pkg.normal) (executionOwner native compiler pkg) s t)
    (changed : t.dispatches ≠ s.dispatches) :
    ∃ p, native.finalPolicyValid p (LlmRouting.view s) ∧ compiler.admitted pkg ∧ compiler.currentAtCAS pkg (LlmRouting.view s) p := by
  obtain ⟨p,stored,bound,current,eligible,wire,policy,fresh⟩ := LlmRouting.actual_dispatch_rechecks_target event changed
  exact ⟨p,policy.1,policy.2⟩

theorem no_extra_provider_attempt (run : LlmRouting.Run (lower base n) owner LlmRouting.initial s) : s.dispatches.length ≤ 1 :=
  LlmRouting.one_provider_admission_per_root run

theorem no_response_splicing (run : LlmRouting.Run (lower base n) owner LlmRouting.initial s) : s.responses.length ≤ 1 :=
  LlmRouting.one_response_source_per_root run

theorem advice_does_not_grant_authority (valid : Refines base profile node response n)
    (event : LlmRouting.Step (lower base n) owner s t) (member : p ∈ t.plans) (fresh : p ∉ s.plans) :
    LlmRouting.Bound base p ∧ LlmRouting.Eligible base s p.target := by
  obtain ⟨bound,eligible⟩ := LlmRouting.every_new_proposal_is_eligible event member fresh
  exact ⟨bound,eligible_is_narrowed valid eligible⟩

theorem telemetry_is_not_authority (s : LlmRouting.State) : LlmRouting.view {s with metrics := s.metrics+1} = LlmRouting.view s :=
  LlmRouting.soft_metrics_do_not_change_authority s

theorem cost_fits_actual_step_reservation (bridge : LlmRouting.AdmissionBridge (lower base n) source policy) :
    base.costBound bridge.before.catalog bridge.selected.target ≤ source.cost bridge.admission.key :=
  LlmRouting.selected_route_fits_source_reservation bridge

theorem shared_account_capacity_retained (bridge : LlmRouting.AdmissionBridge (lower base n) source policy) (account) :
    FiniteDomainMigration.booked source bridge.admission.after.base account ≤ source.capacity account :=
  LlmRouting.original_account_capacity_survives bridge account

theorem original_claim_retained (bridge : LlmRouting.AdmissionBridge (lower base n) source policy) :
    (bridge.admission.after.base.messages bridge.admission.key).claims ≤ 1 ∧
    (bridge.admission.after.base.messages bridge.admission.key).sends ≤ 1 :=
  LlmRouting.original_claim_is_not_recreated bridge

#print axioms eligible_is_narrowed
#print axioms selected_target_is_declared
#print axioms original_budget_is_bound
#print axioms required_capability_preserved
#print axioms history_cannot_be_overridden
#print axioms same_normal_same_runtime
#print axioms all_surfaces_share_runtime
#print axioms source_provenance_is_separate
#print axioms provenance_changes_without_semantic_change
#print axioms task_identity_is_fixed
#print axioms dropped_capability_rejected
#print axioms enlarged_allowance_rejected
#print axioms changed_profile_rejected
#print axioms changed_response_rejected
#print axioms no_empty_route_fallback
#print axioms final_dispatch_rechecks_parent
#print axioms artifact_current_at_dispatch
#print axioms no_extra_provider_attempt
#print axioms no_response_splicing
#print axioms advice_does_not_grant_authority
#print axioms telemetry_is_not_authority
#print axioms cost_fits_actual_step_reservation
#print axioms shared_account_capacity_retained
#print axioms original_claim_retained
end Weaver.RoutineRoutingConfig
