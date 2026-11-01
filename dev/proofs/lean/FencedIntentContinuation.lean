import FloorIntentDecision
namespace Weaver.FencedIntentContinuation
abbrev Intent := Weaver.FloorIntentDecision.Intent
abbrev Cut := Weaver.DeviceIsolationRecovery.Cut
abbrev Legacy := Weaver.FloorIntentDecision.State
abbrev Device := Weaver.DeviceIsolationRecovery.State
abbrev Key := Weaver.KeyBoundaryQueue.State
structure Link where
  id : Nat
  root : Intent
  cut : Cut
  worker : Nat
  fence : Nat
  parent : Option Nat
  deriving DecidableEq
structure ContinuationOwner where
  admitValid : Intent → Cut → Nat → Nat → Prop
  linkReadValid : List Link → Nat → Link → Prop
  commitValid : Link → Prop
  readValid : List Link → Nat → Link → Prop
structure State where
  legacy : Legacy := Weaver.FloorIntentDecision.initial
  links : List Link := []
  retired : List Nat := []
  commits : List Link := []
  active : Option Link := none
  observed : Option (Nat × Link) := none
  phase : Nat := 14

def initial : State := {}
def Resumed (s : State) (i : Intent) : Prop := ∃ l ∈ s.commits, l.root = i
def Done (s : State) (i : Intent) : Prop := Weaver.FloorIntentDecision.Committed s.legacy i ∨ Resumed s i
def Conserved (s : State) : Prop := ∀ i ∈ s.legacy.accepted, Done s i ∨ s.legacy.slot = some i
def UniqueRoot (s : State) : Prop := ∀ a ∈ s.commits, ∀ b ∈ s.commits, a.root = b.root → a = b
def Disjoint (s : State) : Prop := ∀ i, Weaver.FloorIntentDecision.Committed s.legacy i → ¬ Resumed s i

def Extends (i : Intent) (cut : Cut) : Prop := cut.oldFloor = i.cut.oldFloor ∧ cut.oldService = i.cut.oldService ∧
  cut.profile = i.cut.profile ∧ ∀ a ∈ i.cut.members, a ∈ cut.members

def makeLink (s : State) (i : Intent) (cut : Cut) : Link :=
  ⟨s.links.length,i,cut,s.legacy.worker,s.legacy.fence,s.active.bind fun l => if l.root = i then some l.id else none⟩

def KProjection (ks : Key → Key → Prop) (s t : Device) : Prop := t.base = s.base ∨ ks s.base t.base

def Milestone (native : Weaver.DeviceIsolationRecovery.DriverOwner) (root : Nat) (s : State) (next : Device) (target : Nat) : Prop :=
  match target with
  | 10 => ∃ l, s.active = some l ∧ Weaver.DeviceIsolationRecovery.AllBlocked next l.cut
  | 9 => ∃ l, s.active = some l ∧ next.certified = some l.cut ∧ native.certificateValid root l.cut
  | 8 => next.base.barrierKnown = true
  | 4 => Weaver.DeviceIsolationRecovery.CurrentView next
  | 3 => next.base.floorKnown = true
  | 2 => next.base.base.fresh = true
  | 1 => next.base.base.qualified = true
  | 0 => next.base.enabled = true ∧ Weaver.DeviceIsolationRecovery.HardwareReady next
  | _ => False

inductive Step (ks : Key → Key → Prop) (ds : Device → Device → Prop)
    (decisionOwner : Weaver.FloorIntentDecision.DecisionOwner) (continuationOwner : ContinuationOwner)
    (native : Weaver.DeviceIsolationRecovery.DriverOwner) (root : Nat) : State → State → Prop where
  | normal (s next) (source : Weaver.FloorIntentDecision.Step ds decisionOwner s.legacy next)
      (projection : KProjection ks s.legacy.base next.base) (phase : s.phase = 14 ∨ s.phase = 0)
      (stableReady : s.phase = 0 → next.base.base.enabled = true ∨ s.legacy.worker < next.worker)
      (disjoint : ∀ i, Weaver.FloorIntentDecision.Committed next i → ¬ Resumed s i) :
      Step ks ds decisionOwner continuationOwner native root s {s with legacy := next, phase := if next.base.base.enabled then 0 else 14}
  | enter (s i) (phase : s.phase = 14) (held : s.legacy.slot = some i)
      (fenced : ⟨i,.fenced⟩ ∈ s.legacy.decisions) (unsettled : ¬ Done s i) :
      Step ks ds decisionOwner continuationOwner native root s {s with phase := 13}
  | recut (s i cut) (phase : s.phase = 13) (held : s.legacy.slot = some i)
      (pending : s.legacy.base.pendingFloor = some i.cut) (unsettled : ¬ Done s i)
      (fenced : ⟨i,.fenced⟩ ∈ s.legacy.decisions) (closed : s.legacy.base.base.enabled = false)
      (view : Weaver.DeviceIsolationRecovery.CurrentView s.legacy.base)
      (fresh : cut.serial = s.legacy.base.serial + 1)
      (hardware : cut.device = s.legacy.base.device ∧ cut.driver = s.legacy.base.driver ∧ cut.profile = s.legacy.base.profile)
      (before : Weaver.DeviceIsolationRecovery.Before s.legacy.base cut)
      (roster : Weaver.DeviceIsolationRecovery.RosterExact s.legacy.base cut) (preserves : Extends i cut)
      (previous : ∀ l, s.active = some l → l.root = i → l.id ∈ s.retired)
      (authentic : continuationOwner.admitValid i cut s.legacy.worker s.legacy.fence) :
      Step ks ds decisionOwner continuationOwner native root s {s with
        legacy := {s.legacy with base := {s.legacy.base with serial := cut.serial, captured := some cut, certified := none}}
        links := s.links ++ [makeLink s i cut]
        active := some (makeLink s i cut)
        observed := none
        phase := 12}
  | linkRead (s l worker image) (active : s.active = some l) (held : s.legacy.slot = some l.root)
      (phase : s.phase = 12) (current : l.worker = s.legacy.worker ∧ l.fence = s.legacy.fence)
      (session : worker = s.legacy.worker) (fullImage : image = s.links) (live : l.id ∉ s.retired)
      (authentic : continuationOwner.linkReadValid image worker l) :
      Step ks ds decisionOwner continuationOwner native root s {s with phase := 11}
  | milestone (s next target) (source : ds s.legacy.base next) (projection : KProjection ks s.legacy.base next)
      (phase : s.phase = target + 1) (meaning : Milestone native root s next target) :
      Step ks ds decisionOwner continuationOwner native root s {s with legacy := {s.legacy with base := next}, phase := target}
  | commit (s next l) (source : ks s.legacy.base.base next) (phase : s.phase = 8)
      (held : s.legacy.slot = some l.root) (active : s.active = some l) (registered : l ∈ s.links)
      (current : l.worker = s.legacy.worker ∧ l.fence = s.legacy.fence) (live : l.id ∉ s.retired)
      (unsettled : ¬ Done s l.root) (preserves : Extends l.root l.cut)
      (pending : s.legacy.base.pendingFloor = some l.root.cut) (certified : s.legacy.base.certified = some l.cut)
      (context : Weaver.DeviceIsolationRecovery.Context s.legacy.base l.cut)
      (before : Weaver.DeviceIsolationRecovery.Before s.legacy.base l.cut)
      (blocked : Weaver.DeviceIsolationRecovery.AllBlocked s.legacy.base l.cut)
      (effect : next.epoch = s.legacy.base.base.epoch + 1 ∧ next.exports = s.legacy.base.base.exports ∧ next.enabled = false)
      (authentic : continuationOwner.commitValid l) :
      Step ks ds decisionOwner continuationOwner native root s {s with
        legacy := {s.legacy with base := {s.legacy.base with
          base := next, journal := s.legacy.base.journal ++ [l.root.cut], pendingFloor := none, view := none}}
        commits := s.commits ++ [l]
        observed := none
        phase := 7}
  | observe (s l worker image) (member : l ∈ s.commits) (held : s.legacy.slot = some l.root)
      (phase : s.phase = 7 ∨ s.phase = 14) (session : worker = s.legacy.worker) (fullImage : image = s.commits)
      (authentic : continuationOwner.readValid image worker l) :
      Step ks ds decisionOwner continuationOwner native root s {s with observed := some (worker,l), phase := if s.phase = 7 then 6 else 14}
  | acknowledge (s l) (held : s.legacy.slot = some l.root) (member : l ∈ s.commits)
      (phase : s.phase = 6 ∨ s.phase = 14) (seen : s.observed = some (s.legacy.worker,l)) :
      Step ks ds decisionOwner continuationOwner native root s {s with
        legacy := {s.legacy with slot := none, observed := none}
        observed := none
        phase := if s.phase = 6 then 5 else 14}
  | reset (s next l) (source : ds s.legacy.base next) (projection : KProjection ks s.legacy.base next)
      (active : s.active = some l)
      (effect : next.base.enabled = false ∧ next.certified = none ∧ next.captured = none ∧
        next.journal = s.legacy.base.journal ∧ next.pendingFloor = s.legacy.base.pendingFloor ∧ next.serial = s.legacy.base.serial + 1) :
      Step ks ds decisionOwner continuationOwner native root s {s with
        legacy := {s.legacy with base := next, worker := s.legacy.worker + 1, fence := s.legacy.fence + 1, observed := none}
        retired := s.retired ++ [l.id]
        observed := none
        phase := 14}
  | loseResponse (s) : Step ks ds decisionOwner continuationOwner native root s s

inductive Run (ks : Key → Key → Prop) (ds : Device → Device → Prop)
    (decisionOwner : Weaver.FloorIntentDecision.DecisionOwner) (continuationOwner : ContinuationOwner)
    (native : Weaver.DeviceIsolationRecovery.DriverOwner) (root : Nat) : State → State → Prop where
  | refl (s) : Run ks ds decisionOwner continuationOwner native root s s
  | next : Run ks ds decisionOwner continuationOwner native root a b → Step ks ds decisionOwner continuationOwner native root b c → Run ks ds decisionOwner continuationOwner native root a c

variable {ks : Key → Key → Prop} {ds : Device → Device → Prop}
  {decisionOwner : Weaver.FloorIntentDecision.DecisionOwner} {continuationOwner : ContinuationOwner}
  {native : Weaver.DeviceIsolationRecovery.DriverOwner} {root : Nat}

local notation "Event" => Step ks ds decisionOwner continuationOwner native root
local notation "History" => Run ks ds decisionOwner continuationOwner native root

theorem commits_never_roll_back (event : Event s t) : s.commits <+: t.commits := by
  cases event with
  | commit => exact List.prefix_append _ _
  | _ => exact List.prefix_refl _

theorem old_attempt_decisions_never_change (event : Event s t) : s.legacy.decisions <+: t.legacy.decisions := by
  cases event with
  | normal next source => exact Weaver.FloorIntentDecision.decisions_never_roll_back source
  | _ => exact List.prefix_refl _

theorem recut_preserves_original_obligation (event : Event s t) (changed : t.links ≠ s.links) :
    ∃ i cut, s.legacy.slot = some i ∧ t.legacy.slot = some i ∧ t.legacy.accepted = s.legacy.accepted ∧
      t.legacy.base.pendingFloor = s.legacy.base.pendingFloor ∧ Extends i cut ∧ ¬ Done s i := by
  cases event with
  | recut i cut phase held pending unsettled fenced closed view fresh hardware before roster preserves =>
    exact ⟨i,cut,held,held,rfl,rfl,preserves,unsettled⟩
  | _ => exact False.elim (changed rfl)

theorem only_current_unsettled_root_can_commit (event : Event s t) (changed : t.commits ≠ s.commits) :
    ∃ l, s.active = some l ∧ s.legacy.slot = some l.root ∧ l.worker = s.legacy.worker ∧ l.fence = s.legacy.fence ∧
      l.id ∉ s.retired ∧ ¬ Done s l.root ∧ Extends l.root l.cut ∧ t.commits = s.commits ++ [l] := by
  cases event with
  | commit next l source phase held active registered current live unsettled preserves =>
    exact ⟨l,active,held,current.1,current.2,live,unsettled,preserves,rfl⟩
  | _ => exact False.elim (changed rfl)

theorem unique_step (h : UniqueRoot s) (event : Event s t) : UniqueRoot t := by
  cases event with
  | commit next l source phase held active registered current live unsettled preserves =>
    intro a ha b hb same
    have fresh : ∀ r ∈ s.commits, r.root ≠ l.root := by
      intro r hr eq
      exact unsettled (.inr ⟨r,hr,eq⟩)
    rcases List.mem_append.mp ha with ha | ha
    · rcases List.mem_append.mp hb with hb | hb
      · exact h a ha b hb same
      · have eq : b = l := by simpa using hb
        subst b; exact False.elim (fresh a ha same)
    · have eq : a = l := by simpa using ha
      subst a
      rcases List.mem_append.mp hb with hb | hb
      · exact False.elim (fresh b hb same.symm)
      · have eq : b = l := by simpa using hb
        exact eq.symm
  | _ => exact h

theorem conservation_step (h : Conserved s) (event : Event s t) : Conserved t := by
  cases event with
  | normal next source projection phase stableReady disjoint =>
    have persists : ∀ {i}, Done s i → Done {s with legacy := next} i := by
      intro i done
      rcases done with old | resumed
      · exact .inl (Weaver.FloorIntentDecision.commitment_survives source old)
      · exact .inr resumed
    cases source with
    | accept actual i original free identity fresh undecided effect =>
      intro j member
      rcases List.mem_append.mp member with old | new
      · rcases h j old with done | pending
        · exact .inl (persists done)
        · rw [free] at pending; contradiction
      · have eq : j = i := by simpa using new
        subst j; exact .inr rfl
    | acknowledge i held seen durable =>
      intro j member
      rcases h j member with done | pending
      · exact .inl (persists done)
      · have eq : j = i := Option.some.inj (pending.symm.trans held)
        subst j; exact .inl (.inl durable)
    | commit actual i original held current undecided effect =>
      intro j member
      rcases h j member with done | pending
      · exact .inl (persists done)
      · exact .inr pending
    | fencePending actual i original held undecided effect =>
      intro j member
      rcases h j member with done | pending
      · exact .inl (persists done)
      · exact .inr pending
    | _ => exact h
  | commit next l source phase held active registered current live unsettled preserves =>
    intro i member
    rcases h i member with done | pending
    · rcases done with old | resumed
      · exact .inl (.inl old)
      · rcases resumed with ⟨q,hq,eq⟩
        exact .inl (.inr ⟨q,List.mem_append_left _ hq,eq⟩)
    · exact .inr pending
  | acknowledge l held member phase seen =>
    intro i hi
    rcases h i hi with done | pending
    · exact .inl done
    · have eq : i = l.root := Option.some.inj (pending.symm.trans held)
      exact .inl (.inr ⟨l,member,eq.symm⟩)
  | _ => exact h

theorem disjoint_step (h : Disjoint s) (event : Event s t) : Disjoint t := by
  cases event with
  | normal next source projection phase stableReady disjoint => exact disjoint
  | commit next l source phase held active registered current live unsettled preserves =>
    intro i original resumed
    rcases resumed with ⟨q,member,eq⟩
    rcases List.mem_append.mp member with old | new
    · exact h i original ⟨q,old,eq⟩
    · have same : q = l := by simpa using new
      subst q
      have old : Weaver.FloorIntentDecision.Committed s.legacy l.root := by simpa [Weaver.FloorIntentDecision.Committed,eq] using original
      exact unsettled (.inl old)
  | _ => exact h

theorem initialized_original_and_continuation_cannot_both_commit (events : History initial s) : Disjoint s := by
  induction events with
  | refl => simp [Disjoint,initial,Weaver.FloorIntentDecision.initial,Weaver.FloorIntentDecision.Committed]
  | next prior event ih => exact disjoint_step ih event

theorem original_attempt_outcomes_remain_unique_step (h : Weaver.FloorIntentDecision.Unique s.legacy) (event : Event s t) :
    Weaver.FloorIntentDecision.Unique t.legacy := by
  cases event with
  | normal next source => exact Weaver.FloorIntentDecision.unique_step h source
  | _ => exact h

theorem initialized_original_attempt_outcomes_unique (events : History initial s) : Weaver.FloorIntentDecision.Unique s.legacy := by
  induction events with
  | refl => simp [Weaver.FloorIntentDecision.Unique,initial,Weaver.FloorIntentDecision.initial]
  | next prior event ih => exact original_attempt_outcomes_remain_unique_step ih event

theorem initialized_conservation (events : History initial s) : Conserved s := by
  induction events with
  | refl => simp [Conserved,initial,Weaver.FloorIntentDecision.initial]
  | next prior event ih => exact conservation_step ih event

theorem initialized_unique_root (events : History initial s) : UniqueRoot s := by
  induction events with
  | refl => simp [UniqueRoot,initial]
  | next prior event ih => exact unique_step ih event

theorem continuation_acknowledges_original_root (event : Event s t) (old : s.legacy.slot = some i)
    (free : t.legacy.slot = none) : Done s i := by
  cases event with
  | normal next source => exact .inl (Weaver.FloorIntentDecision.only_original_commit_unlocks source old free).2
  | acknowledge l held member =>
    have eq : i = l.root := Option.some.inj (old.symm.trans held)
    exact .inr ⟨l,member,eq.symm⟩
  | _ => rw [old] at free; contradiction

theorem key_step_or_stutter (event : Event s t) : t.legacy.base.base = s.legacy.base.base ∨ ks s.legacy.base.base t.legacy.base.base := by
  cases event with
  | normal next source projection => exact projection
  | milestone next target source projection => exact projection
  | reset next l source projection => exact projection
  | commit next l source => exact .inr source
  | _ => exact .inl rfl

-- Stable recovery excludes new worker/context fences; every real milestone reduces rank.
theorem stable_rank_nonincreasing (event : Event s t) (worker : t.legacy.worker = s.legacy.worker)
    (within : s.phase ≤ 13) : t.phase ≤ s.phase := by
  cases event with
  | normal next source projection phase stableReady disjoint =>
    change next.worker = s.legacy.worker at worker
    rcases phase with impossible | zero
    · omega
    · rcases stableReady zero with enabled | changed
      · simp [enabled,zero]
      · omega
  | enter => omega
  | recut => simp_all
  | linkRead => simp_all
  | milestone => simp_all
  | commit => simp_all
  | observe l w image member held phase session fullImage authentic => rcases phase with h | h <;> simp [h]
  | acknowledge l held member phase seen => rcases phase with h | h <;> simp [h]
  | reset => simp at worker
  | loseResponse => exact Nat.le_refl _

-- This theorem separates fairness from safety. It assumes progress actions are eventually scheduled.
theorem fair_monotone_rank_eventually_zero (rank : Nat → Nat)
    (monotone : ∀ n, rank (n+1) ≤ rank n)
    (fair : ∀ n, 0 < rank n → ∃ m, n ≤ m ∧ rank (m+1) < rank m) : ∀ n, ∃ m, n ≤ m ∧ rank m = 0 := by
  have across : ∀ n k, n ≤ k → rank k ≤ rank n := by
    intro n k bound
    induction bound with
    | refl => exact Nat.le_refl _
    | @step k bound ih => exact Nat.le_trans (monotone k) ih
  have close : ∀ r n, rank n = r → ∃ m, n ≤ m ∧ rank m = 0 := by
    intro r
    induction r using Nat.strongRecOn with
    | ind r ih =>
      intro n eq
      by_cases zero : r = 0
      · exact ⟨n,Nat.le_refl _,eq.trans zero⟩
      · obtain ⟨k,bound,drop⟩ := fair n (by omega)
        have lower : rank (k+1) < r := Nat.lt_of_lt_of_le drop (by simpa [eq] using across n k bound)
        obtain ⟨m,later,done⟩ := ih (rank (k+1)) lower (k+1) rfl
        exact ⟨m,by omega,done⟩
  intro n; exact close (rank n) n rfl

theorem stable_fair_recovery_finishes (trace : Nat → State)
    (events : ∀ n, Event (trace n) (trace (n+1)))
    (stable : ∀ n, (trace (n+1)).legacy.worker = (trace n).legacy.worker)
    (within : ∀ n, (trace n).phase ≤ 13)
    (fair : ∀ n, 0 < (trace n).phase → ∃ m, n ≤ m ∧ (trace (m+1)).phase < (trace m).phase) :
    ∃ m, (trace m).phase = 0 := by
  obtain ⟨m,_,done⟩ := fair_monotone_rank_eventually_zero (fun n => (trace n).phase)
    (fun n => stable_rank_nonincreasing (events n) (stable n) (within n)) fair 0
  exact ⟨m,done⟩

theorem zero_phase_means_enabled_step (inv : s.phase = 0 → s.legacy.base.base.enabled = true) (event : Event s t) :
    t.phase = 0 → t.legacy.base.base.enabled = true := by
  intro zero
  cases event with
  | normal next source projection phase stableReady disjoint =>
    by_cases enabled : next.base.base.enabled = true
    · exact enabled
    · simp [enabled] at zero
  | milestone next target source projection phase meaning =>
    change target = 0 at zero
    subst target
    exact meaning.1
  | observe l w image member held phase session fullImage authentic =>
    rcases phase with h | h <;> simp [h] at zero
  | acknowledge l held member phase seen =>
    rcases phase with h | h <;> simp [h] at zero
  | loseResponse => exact inv zero
  | _ => simp at zero

theorem initialized_zero_phase_means_enabled (events : History initial s) : s.phase = 0 → s.legacy.base.base.enabled = true := by
  induction events with
  | refl => simp [initial]
  | next prior event ih => exact zero_phase_means_enabled_step ih event

theorem stable_fair_recovery_becomes_enabled (trace : Nat → State)
    (reachable : ∀ n, History initial (trace n))
    (events : ∀ n, Event (trace n) (trace (n+1)))
    (stable : ∀ n, (trace (n+1)).legacy.worker = (trace n).legacy.worker)
    (within : ∀ n, (trace n).phase ≤ 13)
    (fair : ∀ n, 0 < (trace n).phase → ∃ m, n ≤ m ∧ (trace (m+1)).phase < (trace m).phase) :
    ∃ m, (trace m).phase = 0 ∧ (trace m).legacy.base.base.enabled = true := by
  obtain ⟨m,done⟩ := stable_fair_recovery_finishes trace events stable within fair
  exact ⟨m,done,initialized_zero_phase_means_enabled (reachable m) done⟩

def NextMilestoneEnabled (trace : Nat → State) (n : Nat) : Prop :=
  ∃ next, Event (trace n) next ∧ next.phase < (trace n).phase

theorem weakly_fair_available_recovery_becomes_enabled (trace : Nat → State)
    (reachable : ∀ n, History initial (trace n))
    (events : ∀ n, Event (trace n) (trace (n+1)))
    (stable : ∀ n, (trace (n+1)).legacy.worker = (trace n).legacy.worker)
    (within : ∀ n, (trace n).phase ≤ 13)
    (available : ∀ n, 0 < (trace n).phase → NextMilestoneEnabled (ks := ks) (ds := ds) (decisionOwner := decisionOwner) (continuationOwner := continuationOwner) (native := native) (root := root) trace n)
    (scheduler : ∀ n, (∀ m, n ≤ m → NextMilestoneEnabled (ks := ks) (ds := ds) (decisionOwner := decisionOwner) (continuationOwner := continuationOwner) (native := native) (root := root) trace m) →
      ∃ m, n ≤ m ∧ (trace (m+1)).phase < (trace m).phase) :
    ∃ m, (trace m).phase = 0 ∧ (trace m).legacy.base.base.enabled = true := by
  classical
  by_cases done : ∃ m, (trace m).phase = 0
  · obtain ⟨m,zero⟩ := done
    exact ⟨m,zero,initialized_zero_phase_means_enabled (reachable m) zero⟩
  · have positive : ∀ n, 0 < (trace n).phase := by
      intro n
      have nonzero : (trace n).phase ≠ 0 := fun zero => done ⟨n,zero⟩
      omega
    have fair : ∀ n, 0 < (trace n).phase → ∃ m, n ≤ m ∧ (trace (m+1)).phase < (trace m).phase := by
      intro n _
      exact scheduler n (fun m _ => available m (positive m))
    exact stable_fair_recovery_becomes_enabled trace reachable events stable within fair

theorem late_active_link_cannot_cross_new_fence (event : Event s t) (active : s.active = some l)
    (old : l.worker < s.legacy.worker) : t.commits = s.commits := by
  by_cases same : t.commits = s.commits
  · exact same
  · obtain ⟨q,actual,held,currentWorker,currentFence,live,unsettled,preserves,effect⟩ := only_current_unsettled_root_can_commit event same
    have eq : q = l := Option.some.inj (actual.symm.trans active)
    subst q
    omega

theorem retired_attempts_never_reactivate (event : Event s t) : s.retired <+: t.retired := by
  cases event with
  | reset => exact List.prefix_append _ _
  | _ => exact List.prefix_refl _

theorem recut_unlock_counterexample (i : Intent) :
    ¬ Conserved {legacy := {accepted := [i], slot := none}} := by
  simp [Conserved,Done,Resumed,Weaver.FloorIntentDecision.Committed]

theorem duplicate_root_commit_counterexample (l : Link) :
    ¬ UniqueRoot {commits := [l,{l with id := l.id + 1}]} := by
  intro unique
  have bad := unique l (by simp) {l with id := l.id + 1} (by simp) rfl
  have ids := congrArg Link.id bad
  simp at ids

theorem unfair_stutter_has_no_recovery :
    ∃ rank : Nat → Nat, (∀ n, rank (n+1) ≤ rank n) ∧ (∀ n, rank n ≠ 0) := by
  exact ⟨fun _ => 12,fun _ => Nat.le_refl _,fun _ => by simp⟩

variable {c : Weaver.FiniteDomainMigration.Config} {m : Weaver.FiniteStreamManifest.Manifest c}
  {p : Weaver.WriterSettlementClosure.Profile c m} {lineage root namespaceId : Nat}
  {owner : Weaver.GateConsumptionPersistence.EvidenceOwner} {projectionStore : Weaver.AnchorBrokerCommit.RootOwner}
  {family : Weaver.AnchorReconfiguration.Family} {store : Weaver.AnchorReconfiguration.Store} {signerOwner : Weaver.ProtectedSignerRelease.SignerOwner}
  {keyOwner : Weaver.KeyBoundaryQueue.KeyOwner} {driverOwner : Weaver.DeviceIsolationRecovery.DriverOwner} {eligible : Weaver.AnchorReconfiguration.Scope → Nat → Prop}
local notation "DeviceStep" => Weaver.DeviceIsolationRecovery.Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner driverOwner eligible

local notation "KeyStep" => Weaver.KeyBoundaryQueue.Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner eligible
theorem initialized_product_refines_key (events : Run KeyStep DeviceStep decisionOwner continuationOwner driverOwner root initial s) :
    Weaver.KeyBoundaryQueue.Run (c := c) (m := m) (p := p) (lineage := lineage) (root := root) (namespaceId := namespaceId)
      (owner := owner) (projectionStore := projectionStore) (family := family) (store := store) (signerOwner := signerOwner) (keyOwner := keyOwner) (eligible := eligible) Weaver.KeyBoundaryQueue.initial s.legacy.base.base := by
  induction events with
  | refl => exact .refl _
  | next prior event ih =>
    rcases key_step_or_stutter event with same | source
    · simpa [← same] using ih
    · exact .next ih source

theorem original_consumption_and_settlement_remain_unique (events : Run KeyStep DeviceStep decisionOwner continuationOwner driverOwner root initial s) (k) :
    s.legacy.base.base.base.base.base.base.base.burnCount k ≤ 1 ∧ s.legacy.base.base.base.base.base.base.dispatchCount k ≤ 1 ∧ s.legacy.base.base.base.base.base.base.base.base.authority.writes k ≤ 1 :=
  Weaver.KeyBoundaryQueue.original_consumption_and_settlement_remain_unique (initialized_product_refines_key events) k

theorem original_budget_remains_conserved (events : Run KeyStep DeviceStep decisionOwner continuationOwner driverOwner root initial s) (b) :
    Weaver.SettlementAnchorRecovery.accountMaterialized c s.legacy.base.base.base.base.base.base.base.base b ≤ Weaver.FiniteDomainMigration.booked c s.legacy.base.base.base.base.base.base.base.base.authority.source.base.base.control.journal.head.payload b ∧
    Weaver.SettlementAnchorRecovery.accountMaterialized c s.legacy.base.base.base.base.base.base.base.base b ≤ c.capacity b :=
  Weaver.KeyBoundaryQueue.original_budget_remains_conserved (initialized_product_refines_key events) b

theorem unknown_original_reservation_stays_held (events : Run KeyStep DeviceStep decisionOwner continuationOwner driverOwner root initial s)
    (sealed : s.legacy.base.base.base.base.base.base.base.seals k = some a) :
    (s.legacy.base.base.base.base.base.base.base.base.authority.source.base.base.control.journal.head.payload.messages k).reserved = true :=
  Weaver.KeyBoundaryQueue.unknown_original_reservation_stays_held (initialized_product_refines_key events) sealed

#print axioms weakly_fair_available_recovery_becomes_enabled
#print axioms initialized_original_and_continuation_cannot_both_commit
#print axioms initialized_original_attempt_outcomes_unique
#print axioms initialized_zero_phase_means_enabled
#print axioms stable_fair_recovery_becomes_enabled
#print axioms late_active_link_cannot_cross_new_fence
#print axioms retired_attempts_never_reactivate
#print axioms recut_unlock_counterexample
#print axioms duplicate_root_commit_counterexample
#print axioms unfair_stutter_has_no_recovery
#print axioms commits_never_roll_back
#print axioms old_attempt_decisions_never_change
#print axioms recut_preserves_original_obligation
#print axioms only_current_unsettled_root_can_commit
#print axioms initialized_conservation
#print axioms initialized_unique_root
#print axioms continuation_acknowledges_original_root
#print axioms stable_rank_nonincreasing
#print axioms fair_monotone_rank_eventually_zero
#print axioms stable_fair_recovery_finishes
#print axioms initialized_product_refines_key
#print axioms original_consumption_and_settlement_remain_unique
#print axioms original_budget_remains_conserved
#print axioms unknown_original_reservation_stays_held
end Weaver.FencedIntentContinuation
