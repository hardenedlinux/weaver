import LlmCustodyPublication
namespace Weaver.LlmCallerCustody

-- Context is supplied by the authenticated transport, never deserialized from a request.
structure Context where
  workload : Nat
  incarnation : Nat
  key : Nat
  recovery : Bool
structure Capability where
  serial : Nat
  domain : Nat
  workload : Nat
  incarnation : Nat
  key : Nat
  holder : Nat
  fence : Nat
  original : Option LlmAdmissionFloor.Proposal
  expires : Nat
  publish : Bool
structure State where
  logical : LlmCustodyPublication.State
  grant : Capability
  used : List Nat
  capJournal : List Capability
  now : Nat
-- Enrollment includes trusted issuance and proof of possession of the new key.
-- Authentic context includes audience/channel/request binding; it is a native premise.
structure Owner where
  authentic : Context → Prop
  enrolled : Nat → Nat → Nat → Prop
  recoveryAllows : Context → State → Capability → Prop
  envelopeDurable : State → LlmCustodyPublication.State → Capability → Prop

def Bound (s : State) (c : Context) (presented : Capability) (o : Owner) : Prop :=
  o.authentic c ∧ c.recovery = false ∧ presented = s.grant ∧
  c.workload = s.grant.workload ∧ c.incarnation = s.grant.incarnation ∧
  c.key = s.grant.key ∧ s.now < s.grant.expires ∧ s.grant.publish = true ∧
  s.grant.holder = s.logical.authority.holder ∧ s.grant.fence = s.logical.authority.fence ∧
  s.grant.original = s.logical.authority.intent

def Scope (a b : Capability) : Prop :=
  b.domain = a.domain ∧ b.workload = a.workload ∧ b.original = a.original ∧
  b.expires = a.expires ∧ b.publish = a.publish

def Fits (c : Capability) (s : LlmCustodyPublication.State) : Prop :=
  c.holder = s.authority.holder ∧ c.fence = s.authority.fence ∧ c.original = s.authority.intent

inductive Permit (o : Owner) (s : State) (c : Context) (presented next : Capability)
    (afterState : LlmCustodyPublication.State) : Prop where
  | worker (bound : Bound s c presented o) (same : next = s.grant)
      (fits : Fits next afterState) : Permit o s c presented next afterState
  | rotate (bound : Bound s c presented o) (scope : Scope s.grant next)
      (serial : next.serial = s.grant.serial + 1)
      (incarnation : next.incarnation = s.grant.incarnation)
      (changed : next.key ≠ s.grant.key)
      (enrolled : o.enrolled next.workload next.incarnation next.key)
      (reset : afterState.authority = {s.logical.authority with logical := {s.logical.authority.logical with ticket := none}, resolved := false})
      (fits : Fits next afterState) : Permit o s c presented next afterState
  | handoff (authentic : o.authentic c) (role : c.recovery = true)
      (allowed : o.recoveryAllows c s next) (scope : Scope s.grant next)
      (serial : next.serial = s.grant.serial + 1)
      (fresh : next.incarnation ∉ s.used)
      (enrolled : o.enrolled next.workload next.incarnation next.key)
      (fence : next.fence = s.grant.fence + 1)
      (fits : Fits next afterState) : Permit o s c presented next afterState

inductive Step (ao : LlmAccountCommit.Owner) (wo : LlmWalActivation.Owner)
    (co : LlmCheckpointTruncation.Owner) (ho : LlmAppendHandoff.Owner)
    (fo : LlmAdmissionFloor.Owner) (jo : LlmSourceJoin.Owner)
    (semantic : LlmAdmissionFloor.Proposal → LlmAdmissionFloor.Proposal → Prop)
    (po : LlmCustodyPublication.Owner) (o : Owner) (genesis : LlmAccountCommit.Image) : State → State → Prop where
  | metadata (s next) (event : LlmCustodyPublication.Step ao wo co ho fo jo semantic po genesis s.logical next)
      (unchanged : next.journal = s.logical.journal) :
      Step ao wo co ho fo jo semantic po o genesis s {s with logical := next}
  | publish (s next c presented grant) (event : LlmCustodyPublication.Step ao wo co ho fo jo semantic po genesis s.logical next)
      (appended : next.journal.length ≠ s.logical.journal.length)
      (permit : Permit o s c presented grant next)
      (durable : o.envelopeDurable s next grant) :
      Step ao wo co ho fo jo semantic po o genesis s
        {s with logical := next, grant := grant, used := if grant.incarnation ∈ s.used then s.used else s.used ++ [grant.incarnation], capJournal := s.capJournal ++ [grant]}
  | tick (s time) (monotone : s.now ≤ time) :
      Step ao wo co ho fo jo semantic po o genesis s {s with now := time}
  | redeliver (s c presented) (bound : Bound s c presented o) :
      Step ao wo co ho fo jo semantic po o genesis s s

inductive Run (ao : LlmAccountCommit.Owner) (wo : LlmWalActivation.Owner)
    (co : LlmCheckpointTruncation.Owner) (ho : LlmAppendHandoff.Owner)
    (fo : LlmAdmissionFloor.Owner) (jo : LlmSourceJoin.Owner)
    (semantic : LlmAdmissionFloor.Proposal → LlmAdmissionFloor.Proposal → Prop)
    (po : LlmCustodyPublication.Owner) (o : Owner) (genesis : LlmAccountCommit.Image) : State → State → Prop where
  | refl (s) : Run ao wo co ho fo jo semantic po o genesis s s
  | next : Run ao wo co ho fo jo semantic po o genesis a b → Step ao wo co ho fo jo semantic po o genesis b d → Run ao wo co ho fo jo semantic po o genesis a d

theorem projection (event : Step ao wo co ho fo jo semantic po o genesis s t) :
    LlmCustodyPublication.Run ao wo co ho fo jo semantic po genesis s.logical t.logical := by
  cases event with
  | metadata next e h => exact .next (.refl _) e
  | publish next c p g e h permit durable => exact .next (.refl _) e
  | _ => exact .refl _

theorem extend (r : LlmCustodyPublication.Run ao wo co ho fo jo semantic po genesis a b)
    (prior : LlmCustodyPublication.Run ao wo co ho fo jo semantic po genesis x a) :
    LlmCustodyPublication.Run ao wo co ho fo jo semantic po genesis x b := by
  induction r with
  | refl => exact prior
  | next r e ih => exact .next ih e

theorem composition (run : Run ao wo co ho fo jo semantic po o genesis s t)
    (prior : LlmCustodyPublication.Run ao wo co ho fo jo semantic po genesis x s.logical) :
    LlmCustodyPublication.Run ao wo co ho fo jo semantic po genesis x t.logical := by
  induction run with
  | refl => exact prior
  | next r e ih => exact extend (projection e) ih

theorem workload_is_insufficient (wrong : c.incarnation ≠ s.grant.incarnation) : ¬ Bound s c presented o := by
  intro h
  exact wrong h.2.2.2.2.1

theorem old_key_rejected (wrong : c.key ≠ s.grant.key) : ¬ Bound s c presented o := by
  intro h
  exact wrong h.2.2.2.2.2.1

theorem old_capability_rejected (wrong : presented ≠ s.grant) : ¬ Bound s c presented o := by
  intro h
  exact wrong h.2.2.1

theorem expired_rejected (expired : s.grant.expires ≤ s.now) : ¬ Bound s c presented o := by
  intro h
  have time := h.2.2.2.2.2.2.1
  omega

theorem scope_retained (permit : Permit o s c presented grant next) : Scope s.grant grant := by
  cases permit with
  | worker bound same fits => rw [same]; exact ⟨rfl,rfl,rfl,rfl,rfl⟩
  | rotate bound scope serial incarnation changed enrolled reset fits => exact scope
  | handoff authentic role allowed scope serial fresh enrolled fence fits => exact scope

theorem serial_monotone (permit : Permit o s c presented grant next) : s.grant.serial ≤ grant.serial := by
  cases permit with
  | worker bound same fits => rw [same]; exact Nat.le_refl _
  | rotate bound scope serial incarnation changed enrolled reset fits => omega
  | handoff authentic role allowed scope serial fresh enrolled fence fits => omega

theorem incarnation_change_requires_recovery (permit : Permit o s c presented grant next)
    (changed : grant.incarnation ≠ s.grant.incarnation) :
    o.authentic c ∧ c.recovery = true ∧ o.recoveryAllows c s grant ∧ grant.incarnation ∉ s.used := by
  cases permit with
  | worker bound same fits => exact False.elim (changed (congrArg Capability.incarnation same))
  | rotate bound scope serial incarnation key enrolled reset fits => exact False.elim (changed incarnation)
  | handoff authentic role allowed scope serial fresh enrolled fence fits => exact ⟨authentic,role,allowed,fresh⟩

theorem final_append_requires_permit (event : Step ao wo co ho fo jo semantic po o genesis s t)
    (appended : t.logical.journal.length ≠ s.logical.journal.length) :
    ∃ c presented, Permit o s c presented t.grant t.logical ∧
      o.envelopeDurable s t.logical t.grant ∧ t.capJournal = s.capJournal ++ [t.grant] := by
  cases event with
  | publish next c presented grant e h permit durable => exact ⟨c,presented,permit,durable,rfl⟩
  | metadata next e h => exact False.elim (appended (congrArg List.length h))
  | _ => exact False.elim (appended rfl)

theorem no_detached_mint (event : Step ao wo co ho fo jo semantic po o genesis s t)
    (unchanged : t.logical.journal.length = s.logical.journal.length) : t.grant = s.grant := by
  cases event with
  | publish next c presented grant e h permit durable => exact False.elim (h unchanged)
  | _ => rfl

theorem used_incarnations_retained (event : Step ao wo co ho fo jo semantic po o genesis s t)
    (known : inc ∈ s.used) : inc ∈ t.used := by
  cases event <;> simp_all; split <;> simp_all

theorem floor_publication_has_caller_and_join
    (event : Step ao wo co ho fo jo semantic po o genesis s t)
    (changed : t.logical.authority.logical.floorState.committed.length ≠ s.logical.authority.logical.floorState.committed.length) :
    (∃ c presented, Permit o s c presented t.grant t.logical ∧ o.envelopeDurable s t.logical t.grant ∧ t.capJournal = s.capJournal ++ [t.grant]) ∧
    LlmCustodyPublication.Ready s.logical ∧
    ∃ p holder fence, s.logical.authority.attempt = some p ∧
      LlmSourceCustody.Current s.logical.authority holder fence ∧
      LlmSourceJoin.Joined s.logical.authority.logical p ∧
      jo.sourceAllows p s.logical.authority.logical ∧ t.logical.authority.outcome = some ⟨p⟩ := by
  cases event with
  | metadata next e unchanged =>
    have eq := LlmCustodyPublication.staging_has_no_authoritative_effect e unchanged
    exact False.elim (changed (congrArg (fun a => a.logical.floorState.committed.length) eq))
  | publish next c presented grant e appended permit durable =>
    obtain ⟨ready,staged,armed,unknown,p,holder,fence,attempt,current,joined,source,outcome,journal⟩ := LlmCustodyPublication.floor_outcome_atomic e changed
    exact ⟨⟨c,presented,permit,durable,rfl⟩,ready,p,holder,fence,attempt,current,joined,source,outcome⟩
  | _ => exact False.elim (changed rfl)

theorem scope_step (event : Step ao wo co ho fo jo semantic po o genesis s t) : Scope s.grant t.grant := by
  cases event with
  | publish next c presented grant e h permit durable => exact scope_retained permit
  | _ => exact ⟨rfl,rfl,rfl,rfl,rfl⟩

theorem scope_run (run : Run ao wo co ho fo jo semantic po o genesis s t) : Scope s.grant t.grant := by
  induction run with
  | refl => exact ⟨rfl,rfl,rfl,rfl,rfl⟩
  | next r e ih =>
    obtain ⟨a,b,c,d,f⟩ := ih
    obtain ⟨g,h,i,j,k⟩ := scope_step e
    exact ⟨g.trans a,h.trans b,i.trans c,j.trans d,k.trans f⟩

theorem serial_run (run : Run ao wo co ho fo jo semantic po o genesis s t) : s.grant.serial ≤ t.grant.serial := by
  induction run with
  | refl => exact Nat.le_refl _
  | next r e ih =>
    cases e with
    | publish next c presented grant ev h permit durable => exact Nat.le_trans ih (serial_monotone permit)
    | _ => exact ih

theorem time_run (run : Run ao wo co ho fo jo semantic po o genesis s t) : s.now ≤ t.now := by
  induction run with
  | refl => exact Nat.le_refl _
  | next r e ih =>
    cases e with
    | tick time monotone => exact Nat.le_trans ih monotone
    | _ => exact ih

theorem used_run (run : Run ao wo co ho fo jo semantic po o genesis s t) (known : inc ∈ s.used) : inc ∈ t.used := by
  induction run with
  | refl => exact known
  | next r e ih => exact used_incarnations_retained e ih

theorem fits_run (run : Run ao wo co ho fo jo semantic po o genesis s t) (initialFit : Fits s.grant s.logical) : Fits t.grant t.logical := by
  induction run with
  | refl => exact initialFit
  | next r e ih =>
    cases e with
    | metadata next ev unchanged =>
      have eq := LlmCustodyPublication.staging_has_no_authoritative_effect ev unchanged
      simpa [Fits,eq] using ih
    | publish next c presented grant ev h permit durable =>
      cases permit <;> assumption
    | _ => exact ih

theorem custody_floor_fence (event : LlmSourceCustody.Step ao wo co ho fo jo owner genesis s t)
    (changed : t.logical.floorState.committed.length ≠ s.logical.floorState.committed.length) : t.fence = s.fence := by
  cases event with
  | commit next p holder fence armed attempt current unknown actual changed exact durable => rfl
  | advance next notArmed actual same => exact False.elim (changed (congrArg List.length same))
  | _ => exact False.elim (changed rfl)

theorem floor_preserves_fence (event : LlmCustodyPublication.Step ao wo co ho fo jo semantic po genesis s t)
    (changed : t.authority.logical.floorState.committed.length ≠ s.authority.logical.floorState.committed.length) : t.authority.fence = s.authority.fence := by
  cases event with
  | publish c slot deliver staged ready parent actual durable =>
    exact custody_floor_fence actual changed
  | _ => exact False.elim (changed rfl)

theorem final_floor_requires_worker_proof (event : Step ao wo co ho fo jo semantic po o genesis s t)
    (initialFit : Fits s.grant s.logical)
    (changed : t.logical.authority.logical.floorState.committed.length ≠ s.logical.authority.logical.floorState.committed.length) :
    ∃ c presented, Bound s c presented o := by
  cases event with
  | metadata next ev unchanged =>
    have eq := LlmCustodyPublication.staging_has_no_authoritative_effect ev unchanged
    exact False.elim (changed (congrArg (fun a => a.logical.floorState.committed.length) eq))
  | publish next c presented grant ev h permit durable =>
    cases permit with
    | worker bound same fits => exact ⟨c,presented,bound⟩
    | rotate bound scope serial incarnation key enrolled reset fits => exact ⟨c,presented,bound⟩
    | handoff authentic role allowed scope serial fresh enrolled fence fits =>
      have unchanged := floor_preserves_fence ev changed
      have beforeFence := initialFit.2.1
      have afterFence := fits.2.1
      omega
  | _ => exact False.elim (changed rfl)

theorem original_result_unique (run : Run ao wo co ho fo jo semantic po o genesis start s)
    (priorPublication : LlmCustodyPublication.Run ao wo co ho fo jo semantic po genesis (LlmCustodyPublication.initial custodyStart) start.logical)
    (priorCustody : LlmSourceCustody.Run ao wo co ho fo jo (LlmCustodyPublication.logicalOwner semantic) genesis (LlmSourceCustody.initial (LlmSourceJoin.initial (LlmAdmissionFloor.initial h))) custodyStart) :
    ∀ r ∈ s.logical.authority.logical.floorState.committed, ∀ other ∈ s.logical.authority.logical.floorState.committed, r.proposal.id = other.proposal.id → r = other :=
  LlmCustodyPublication.original_result_unique (composition run priorPublication) priorCustody

theorem original_reservation_once (safe : LlmAppendHandoff.Safe ho h)
    (run : Run ao wo co ho fo jo semantic po o genesis start s)
    (priorPublication : LlmCustodyPublication.Run ao wo co ho fo jo semantic po genesis (LlmCustodyPublication.initial custodyStart) start.logical)
    (priorCustody : LlmSourceCustody.Run ao wo co ho fo jo (LlmCustodyPublication.logicalOwner semantic) genesis (LlmSourceCustody.initial (LlmSourceJoin.initial (LlmAdmissionFloor.initial h))) custodyStart)
    (priorAccount : LlmCheckpointTruncation.Run ao wo co genesis (LlmCheckpointTruncation.initial ao balances) h.logical) (key) :
    (LlmSourceJoin.account s.logical.authority.logical).authority.writes key ≤ 1 :=
  LlmCustodyPublication.original_reservation_once safe (composition run priorPublication) priorCustody priorAccount key

theorem unknown_original_hold_retained (safe : LlmAppendHandoff.Safe ho h)
    (run : Run ao wo co ho fo jo semantic po o genesis start s)
    (priorPublication : LlmCustodyPublication.Run ao wo co ho fo jo semantic po genesis (LlmCustodyPublication.initial custodyStart) start.logical)
    (priorCustody : LlmSourceCustody.Run ao wo co ho fo jo (LlmCustodyPublication.logicalOwner semantic) genesis (LlmSourceCustody.initial (LlmSourceJoin.initial (LlmAdmissionFloor.initial h))) custodyStart)
    (priorAccount : LlmCheckpointTruncation.Run ao wo co genesis (LlmCheckpointTruncation.initial ao balances) h.logical)
    (source : LlmExecutionReconciliation.State S) (unknownUsage : source.metered = false)
    (binding : ∀ tx state, tx.reservation = originalKey → ao.sourceReady tx state → LlmAccountCommit.OriginalReady originalKey attempt source tx) :
    (LlmSourceJoin.account s.logical.authority.logical).authority.reservations originalKey = none ∧
    (LlmSourceJoin.account s.logical.authority.logical).authority.holds originalKey = ao.bound originalKey :=
  LlmCustodyPublication.unknown_original_hold_retained safe (composition run priorPublication) priorCustody priorAccount source unknownUsage binding

#print axioms projection
#print axioms composition
#print axioms workload_is_insufficient
#print axioms old_key_rejected
#print axioms old_capability_rejected
#print axioms expired_rejected
#print axioms scope_retained
#print axioms serial_monotone
#print axioms incarnation_change_requires_recovery
#print axioms final_append_requires_permit
#print axioms no_detached_mint
#print axioms used_incarnations_retained
#print axioms floor_publication_has_caller_and_join
#print axioms scope_run
#print axioms serial_run
#print axioms time_run
#print axioms used_run
#print axioms fits_run
#print axioms final_floor_requires_worker_proof
#print axioms original_result_unique
#print axioms original_reservation_once
#print axioms unknown_original_hold_retained
end Weaver.LlmCallerCustody
