-- SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
--
-- SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

import KeyBoundaryQueue
namespace Weaver.DeviceIsolationRecovery
open Weaver.LogicalMessageAuthority (update)
inductive Kind where | fd | dma | callback deriving DecidableEq
structure Alias where
  kind : Kind
  epoch : Nat
  device : Nat
  driver : Nat
  generation : Nat
  deriving DecidableEq
structure Cut where
  serial : Nat
  device : Nat
  driver : Nat
  profile : Nat
  oldFloor : Nat
  oldService : Nat
  members : List (Nat × Alias)
  deriving DecidableEq
structure Submission where
  ticket : Weaver.KeyBoundaryQueue.Ticket
  device : Nat
  driver : Nat
  profile : Nat
  dmaId : Nat
  dma : Alias
  callbackId : Nat
  callback : Alias
  deriving DecidableEq
structure View where
  floor : Nat
  service : Nat
  head : Nat
  intent : Option Cut
  deriving DecidableEq
structure DriverOwner where
  aliasValid : Nat → Nat → Alias → Prop
  blockValid : Nat → Cut → Nat → Prop
  certificateValid : Nat → Cut → Prop
  readValid : Nat → List Cut → View → Prop
  activeValid : Nat → Cut → Nat → Nat → Nat → Prop
  callbackValid : Nat → Submission → Prop
  outputSealed : Nat → Submission → Prop
structure State where
  base : Weaver.KeyBoundaryQueue.State := Weaver.KeyBoundaryQueue.initial
  device : Nat := 0
  driver : Nat := 0
  profile : Nat := 0
  serial : Nat := 0
  aliases : Nat → Option Alias := fun _ => none
  blocked : Nat → Bool := fun _ => false
  captured : Option Cut := none
  certified : Option Cut := none
  journal : List Cut := []
  pendingFloor : Option Cut := none
  view : Option View := none
  submissions : Nat → Option Submission := fun _ => none
  validated : Nat → Option Submission := fun _ => none
  archived : List Submission := []
def initial : State := {}
def CurrentView (s : State) : Prop := s.view = some ⟨s.base.epoch,s.base.base.epoch,s.journal.length,s.pendingFloor⟩
def RosterExact (s : State) (c : Cut) : Prop :=
  (c.members.map Prod.fst).Nodup ∧ ∀ id a, (id,a) ∈ c.members ↔ s.aliases id = some a ∧ a.epoch ≤ c.oldFloor
def Context (s : State) (c : Cut) : Prop :=
  c.serial = s.serial ∧ c.device = s.device ∧ c.driver = s.driver ∧ c.profile = s.profile ∧ RosterExact s c
def Before (s : State) (c : Cut) : Prop := c.oldFloor = s.base.epoch ∧ c.oldService = s.base.base.epoch
def After (s : State) (c : Cut) : Prop := c.oldFloor + 1 = s.base.epoch ∧ c.oldService + 1 = s.base.base.epoch
def AllBlocked (s : State) (c : Cut) : Prop := ∀ id a, (id,a) ∈ c.members → s.blocked id = true
def HardwareReady (s : State) : Prop := ∃ c, s.certified = some c ∧ Context s c ∧ After s c ∧ AllBlocked s c ∧ CurrentView s
def CurrentSubmission (s : State) (q : Submission) : Prop :=
  q.device = s.device ∧ q.driver = s.driver ∧ q.profile = s.profile ∧ q.ticket.epoch = s.base.epoch ∧
  s.aliases q.dmaId = some q.dma ∧ q.dma.kind = .dma ∧ q.dma.device = s.device ∧ q.dma.driver = s.driver ∧ q.dma.epoch = s.base.epoch ∧
  s.aliases q.callbackId = some q.callback ∧ q.callback.kind = .callback ∧ q.callback.device = s.device ∧ q.callback.driver = s.driver ∧ q.callback.epoch = s.base.epoch
def Quiet (s t : Weaver.KeyBoundaryQueue.State) : Prop := t.epoch = s.epoch ∧ t.exports = s.exports
def Frame (s t : Weaver.KeyBoundaryQueue.State) : Prop := Quiet s t ∧ t.enabled = s.enabled ∧ t.isolation = s.isolation ∧ t.barrierKnown = s.barrierKnown ∧
  t.floorKnown = s.floorKnown ∧ t.queued = s.queued ∧ t.running = s.running ∧ t.completed = s.completed ∧ t.usedTickets = s.usedTickets
variable {c : Weaver.FiniteDomainMigration.Config} {m : Weaver.FiniteStreamManifest.Manifest c}
  {p : Weaver.WriterSettlementClosure.Profile c m} {lineage root namespaceId : Nat}
  {owner : Weaver.GateConsumptionPersistence.EvidenceOwner} {projectionStore : Weaver.AnchorBrokerCommit.RootOwner}
  {family : Weaver.AnchorReconfiguration.Family} {store : Weaver.AnchorReconfiguration.Store} {signerOwner : Weaver.ProtectedSignerRelease.SignerOwner}
  {keyOwner : Weaver.KeyBoundaryQueue.KeyOwner} {driverOwner : DriverOwner} {eligible : Weaver.AnchorReconfiguration.Scope → Nat → Prop}
inductive Step (c : Weaver.FiniteDomainMigration.Config) (m : Weaver.FiniteStreamManifest.Manifest c)
    (p : Weaver.WriterSettlementClosure.Profile c m) (lineage root namespaceId : Nat)
    (owner : Weaver.GateConsumptionPersistence.EvidenceOwner) (projectionStore : Weaver.AnchorBrokerCommit.RootOwner)
    (family : Weaver.AnchorReconfiguration.Family) (store : Weaver.AnchorReconfiguration.Store) (signerOwner : Weaver.ProtectedSignerRelease.SignerOwner)
    (keyOwner : Weaver.KeyBoundaryQueue.KeyOwner) (driverOwner : DriverOwner) (eligible : Weaver.AnchorReconfiguration.Scope → Nat → Prop) : State → State → Prop where
  | delegate (s next) (source : Weaver.KeyBoundaryQueue.Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner eligible s.base next)
      (frame : Frame s.base next) : Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner driverOwner eligible s {s with base := next}
  | register (s id a) (unused : s.aliases id = none) (bound : a.epoch = s.base.epoch ∧ a.device = s.device ∧ a.driver = s.driver)
      (admission : s.captured = none ∨ s.base.enabled = true)
      (authentic : driverOwner.aliasValid root id a) :
      Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner driverOwner eligible s {s with aliases := update s.aliases id (some a)}
  | seal (s cut) (closed : s.base.enabled = false) (view : CurrentView s) (noPending : s.pendingFloor = none)
      (serial : cut.serial = s.serial + 1) (hardware : cut.device = s.device ∧ cut.driver = s.driver ∧ cut.profile = s.profile)
      (before : Before s cut) (roster : RosterExact s cut) :
      Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner driverOwner eligible s {s with serial := cut.serial, captured := some cut, certified := none}
  | block (s cut id a) (held : s.captured = some cut) (current : Context s cut) (before : Before s cut)
      (member : (id,a) ∈ cut.members) (authentic : driverOwner.blockValid root cut id) :
      Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner driverOwner eligible s {s with blocked := update s.blocked id true}
  | certify (s next cut) (source : Weaver.KeyBoundaryQueue.Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner eligible s.base next)
      (quiet : Quiet s.base next) (held : s.captured = some cut) (current : Context s cut) (before : Before s cut)
      (coverage : AllBlocked s cut) (authentic : driverOwner.certificateValid root cut)
      (effect : next.isolation = some (cut.oldFloor + 1) ∧ next.enabled = false ∧ next.barrierKnown = false ∧ next.floorKnown = false) :
      Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner driverOwner eligible s {s with base := next, certified := some cut}
  | barrier (s next cut) (source : Weaver.KeyBoundaryQueue.Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner eligible s.base next)
      (quiet : Quiet s.base next) (proof : s.certified = some cut) (current : Context s cut) (before : Before s cut)
      (coverage : AllBlocked s cut) (effect : next.barrierKnown = true) :
      Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner driverOwner eligible s {s with base := next}
  | prepareFloor (s cut) (closed : s.base.enabled = false) (proof : s.certified = some cut)
      (current : Context s cut) (before : Before s cut) (coverage : AllBlocked s cut)
      (known : s.base.barrierKnown = true) (unused : s.pendingFloor = none) (authentic : driverOwner.certificateValid root cut) :
      Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner driverOwner eligible s {s with pendingFloor := some cut, view := none}
  | advance (s next cut) (source : Weaver.KeyBoundaryQueue.Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner eligible s.base next)
      (proof : s.certified = some cut) (current : Context s cut) (before : Before s cut) (coverage : AllBlocked s cut)
      (intent : s.pendingFloor = some cut)
      (effect : next.epoch = s.base.epoch + 1 ∧ next.exports = s.base.exports) :
      Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner driverOwner eligible s {s with base := next, journal := s.journal ++ [cut], pendingFloor := none, view := none}
  | readFloor (s history v) (authentic : driverOwner.readValid root history v)
      (exact : history = s.journal ∧ v = ⟨s.base.epoch,s.base.base.epoch,s.journal.length,s.pendingFloor⟩) :
      Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner driverOwner eligible s {s with view := some v}
  | liveFloor (s next cut) (source : Weaver.KeyBoundaryQueue.Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner eligible s.base next)
      (quiet : Quiet s.base next) (proof : s.certified = some cut) (current : Context s cut) (afterCut : After s cut)
      (coverage : AllBlocked s cut) (view : CurrentView s) (effect : next.floorKnown = true) :
      Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner driverOwner eligible s {s with base := next}
  | activate (s next cut) (source : Weaver.KeyBoundaryQueue.Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner eligible s.base next)
      (quiet : Quiet s.base next) (proof : s.certified = some cut) (current : Context s cut) (afterCut : After s cut)
      (coverage : AllBlocked s cut) (view : CurrentView s) (effect : next.enabled = true)
      (authentic : driverOwner.activeValid root cut s.device s.driver s.profile) :
      Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner driverOwner eligible s {s with base := next}
  | enqueue (s next job q) (source : Weaver.KeyBoundaryQueue.Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner eligible s.base next)
      (quiet : Quiet s.base next) (hardware : HardwareReady s) (current : CurrentSubmission s q)
      (unused : s.submissions job = none) (effect : next.queued job = some q.ticket) :
      Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner driverOwner eligible s {s with base := next, submissions := update s.submissions job (some q)}
  | start (s next job q) (source : Weaver.KeyBoundaryQueue.Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner eligible s.base next)
      (quiet : Quiet s.base next) (hardware : HardwareReady s) (held : s.submissions job = some q)
      (current : CurrentSubmission s q) (effect : next.running job = some q.ticket) :
      Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner driverOwner eligible s {s with base := next}
  | complete (s next job receipt) (source : Weaver.KeyBoundaryQueue.Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner eligible s.base next)
      (quiet : Quiet s.base next) (held : s.submissions job = some receipt) (current : CurrentSubmission s receipt)
      (authentic : driverOwner.callbackValid root receipt) (effect : next.completed job = some receipt.ticket) :
      Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner driverOwner eligible s {s with base := next, validated := update s.validated job (some receipt)}
  | emit (s next job q cut) (source : Weaver.KeyBoundaryQueue.Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner eligible s.base next)
      (sameFloor : next.epoch = s.base.epoch) (held : s.submissions job = some q) (validated : s.validated job = some q)
      (current : CurrentSubmission s q) (proof : s.certified = some cut) (context : Context s cut) (afterCut : After s cut)
      (coverage : AllBlocked s cut) (view : CurrentView s) (sealedOutput : driverOwner.outputSealed root q)
      (live : driverOwner.activeValid root cut s.device s.driver s.profile) (effect : next.exports = s.base.exports ++ [q.ticket]) :
      Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner driverOwner eligible s {s with base := next}
  | close (s) :
      Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner driverOwner eligible s {s with
        base := {s.base with enabled := false, isolation := none, barrierKnown := false, floorKnown := false}
        serial := s.serial + 1
        captured := none
        certified := none
        view := none}
  | loseBuffer (s job) :
      Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner driverOwner eligible s {s with
        base := {s.base with queued := update s.base.queued job none, running := update s.base.running job none, completed := update s.base.completed job none}}
  | resetDevice (s profile) :
      Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner driverOwner eligible s {s with
        base := {s.base with enabled := false, isolation := none, barrierKnown := false, floorKnown := false}
        device := s.device + 1
        driver := s.driver + 1
        profile := profile
        serial := s.serial + 1
        blocked := fun _ => false
        captured := none
        certified := none
        view := none}
  | restartDriver (s) :
      Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner driverOwner eligible s {s with
        base := {s.base with enabled := false, isolation := none, barrierKnown := false, floorKnown := false}
        driver := s.driver + 1
        serial := s.serial + 1
        blocked := fun _ => false
        captured := none
        certified := none
        view := none}
  | archiveCallback (s job receipt) (original : s.submissions job = some receipt) (authentic : driverOwner.callbackValid root receipt) :
      Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner driverOwner eligible s {s with archived := s.archived ++ [receipt]}
  | loseResponse (s) : Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner driverOwner eligible s s
inductive Run : State → State → Prop where
  | refl (s) : Run s s
  | next : Run s t → Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner driverOwner eligible t u → Run s u

theorem parent_step_or_stutter (event : Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner driverOwner eligible s t) :
    s.base = t.base ∨ Weaver.KeyBoundaryQueue.Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner eligible s.base t.base := by
  cases event with
  | delegate _ source => exact .inr source
  | certify _ _ source => exact .inr source
  | barrier _ _ source => exact .inr source
  | advance _ _ source => exact .inr source
  | liveFloor _ _ source => exact .inr source
  | activate _ _ source => exact .inr source
  | enqueue _ _ _ source => exact .inr source
  | start _ _ _ source => exact .inr source
  | complete _ _ _ source => exact .inr source
  | emit _ _ _ _ source => exact .inr source
  | close => exact .inr (.close _)
  | loseBuffer job => exact .inr (.loseBuffer _ job)
  | resetDevice => exact .inr (.close _)
  | restartDriver => exact .inr (.close _)
  | _ => exact .inl rfl

theorem protected_floor_never_rolls_back (event : Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner driverOwner eligible s t) : s.base.epoch ≤ t.base.epoch := by
  rcases parent_step_or_stutter event with eq | source
  · rw [eq]; exact Nat.le_refl _
  · exact Weaver.KeyBoundaryQueue.protected_key_epoch_never_rolls_back source

theorem committed_floor_log_never_shrinks (event : Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner driverOwner eligible s t) : s.journal <+: t.journal := by
  cases event with
  | advance => exact List.prefix_append _ _
  | _ => exact List.prefix_refl _

theorem registered_alias_never_relabels {id : Nat} (event : Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner driverOwner eligible s t)
    (old : s.aliases id = some a) : t.aliases id = some a := by
  cases event with
  | register other alias unused =>
    by_cases same : id = other
    · subst id; rw [old] at unused; contradiction
    · simpa [update, same] using old
  | _ => exact old

theorem every_floor_append_keeps_exact_isolation_cut
    (event : Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner driverOwner eligible s t)
    (changed : t.journal ≠ s.journal) : ∃ cut, t.journal = s.journal ++ [cut] ∧ s.certified = some cut ∧
      Context s cut ∧ Before s cut ∧ AllBlocked s cut := by
  cases event with
  | advance next cut source proof current before coverage => exact ⟨cut,rfl,proof,current,before,coverage⟩
  | _ => exact False.elim (changed rfl)

def JournalAligned (s : State) : Prop := s.journal.length = s.base.epoch

theorem journal_tracks_every_floor_commit (inv : JournalAligned s)
    (event : Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner driverOwner eligible s t) : JournalAligned t := by
  cases event with
  | delegate next source frame => simpa [JournalAligned,frame.1.1] using inv
  | certify next cut source quiet => simpa [JournalAligned,quiet.1] using inv
  | barrier next cut source quiet => simpa [JournalAligned,quiet.1] using inv
  | liveFloor next cut source quiet => simpa [JournalAligned,quiet.1] using inv
  | activate next cut source quiet => simpa [JournalAligned,quiet.1] using inv
  | enqueue next job q source quiet => simpa [JournalAligned,quiet.1] using inv
  | start next job q source quiet => simpa [JournalAligned,quiet.1] using inv
  | complete next job q source quiet => simpa [JournalAligned,quiet.1] using inv
  | emit next job q cut source sameFloor => simpa [JournalAligned,sameFloor] using inv
  | advance next cut source proof current before coverage intent effect =>
    simpa [JournalAligned, List.length_append, effect.1] using inv
  | _ => exact inv

theorem every_new_export_requires_current_hardware (event : Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner driverOwner eligible s t)
    (changed : t.base.exports ≠ s.base.exports) : ∃ job q cut, s.submissions job = some q ∧ s.validated job = some q ∧
      CurrentSubmission s q ∧ s.certified = some cut ∧ Context s cut ∧ After s cut ∧ AllBlocked s cut ∧ CurrentView s := by
  cases event with
  | emit next job q cut source sameFloor held validated current proof context afterCut coverage view => exact ⟨job,q,cut,held,validated,current,proof,context,afterCut,coverage,view⟩
  | delegate next source frame => exact False.elim (changed frame.1.2)
  | certify next cut source quiet => exact False.elim (changed quiet.2)
  | barrier next cut source quiet => exact False.elim (changed quiet.2)
  | liveFloor next cut source quiet => exact False.elim (changed quiet.2)
  | activate next cut source quiet => exact False.elim (changed quiet.2)
  | enqueue next job q source quiet => exact False.elim (changed quiet.2)
  | start next job q source quiet => exact False.elim (changed quiet.2)
  | complete next job q source quiet => exact False.elim (changed quiet.2)
  | advance next cut source proof current before coverage intent effect => exact False.elim (changed effect.2)
  | _ => exact False.elim (changed rfl)

theorem validated_callback_has_original_current_envelope (event : Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner driverOwner eligible s t)
    (changed : t.validated ≠ s.validated) : ∃ job q, s.submissions job = some q ∧ CurrentSubmission s q ∧ driverOwner.callbackValid root q := by
  cases event with
  | complete next job receipt source quiet held current authentic => exact ⟨job,receipt,held,current,authentic⟩
  | _ => exact False.elim (changed rfl)

theorem newly_accepted_isolation_has_complete_scope
    (event : Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner driverOwner eligible s t)
    (accepted : t.certified = some cut) (new : s.certified ≠ some cut) :
    Context s cut ∧ Before s cut ∧ AllBlocked s cut ∧ driverOwner.certificateValid root cut := by
  cases event with
  | certify next actual source quiet held current before coverage authentic =>
    have same : actual = cut := Option.some.inj accepted
    subst cut; exact ⟨current,before,coverage,authentic⟩
  | «seal» => simp at accepted
  | close => simp at accepted
  | resetDevice => simp at accepted
  | restartDriver => simp at accepted
  | _ => exact False.elim (new accepted)

theorem unresolved_floor_intent_survives_until_original_commit
    (event : Step c m p lineage root namespaceId owner projectionStore family store signerOwner keyOwner driverOwner eligible s t)
    (held : s.pendingFloor = some cut) : t.pendingFloor = some cut ∨ (s.certified = some cut ∧ t.journal = s.journal ++ [cut]) := by
  cases event with
  | prepareFloor actual closed proof current before coverage known unused =>
    rw [held] at unused; contradiction
  | advance next actual source proof current before coverage intent effect =>
    have same : actual = cut := Option.some.inj (intent.symm.trans held)
    subst cut; exact .inr ⟨proof,rfl⟩
  | _ => exact .inl held

theorem initialized_product_refines_key_boundary (events : Run (c := c) (m := m) (p := p) (lineage := lineage) (root := root) (namespaceId := namespaceId)
    (owner := owner) (projectionStore := projectionStore) (family := family) (store := store) (signerOwner := signerOwner) (keyOwner := keyOwner) (driverOwner := driverOwner) (eligible := eligible) initial s) :
    Weaver.KeyBoundaryQueue.Run (c := c) (m := m) (p := p) (lineage := lineage) (root := root) (namespaceId := namespaceId)
      (owner := owner) (projectionStore := projectionStore) (family := family) (store := store) (signerOwner := signerOwner) (keyOwner := keyOwner) (eligible := eligible) Weaver.KeyBoundaryQueue.initial s.base := by
  induction events with
  | refl => exact .refl _
  | next _ event ih =>
    rcases parent_step_or_stutter event with eq | source
    · simpa [← eq] using ih
    · exact .next ih source

theorem initialized_floor_log_is_complete (events : Run (c := c) (m := m) (p := p) (lineage := lineage) (root := root) (namespaceId := namespaceId)
    (owner := owner) (projectionStore := projectionStore) (family := family) (store := store) (signerOwner := signerOwner) (keyOwner := keyOwner) (driverOwner := driverOwner) (eligible := eligible) initial s) : JournalAligned s := by
  induction events with
  | refl => rfl
  | next _ event ih => exact journal_tracks_every_floor_commit ih event
theorem original_consumption_and_settlement_remain_unique (events : Run (c := c) (m := m) (p := p) (lineage := lineage) (root := root)
    (namespaceId := namespaceId) (owner := owner) (projectionStore := projectionStore) (family := family) (store := store) (signerOwner := signerOwner) (keyOwner := keyOwner) (driverOwner := driverOwner) (eligible := eligible) initial s) (k) :
    s.base.base.base.base.base.base.burnCount k ≤ 1 ∧ s.base.base.base.base.base.dispatchCount k ≤ 1 ∧ s.base.base.base.base.base.base.base.authority.writes k ≤ 1 :=
  Weaver.KeyBoundaryQueue.original_consumption_and_settlement_remain_unique (initialized_product_refines_key_boundary events) k

theorem original_budget_remains_conserved (events : Run (c := c) (m := m) (p := p) (lineage := lineage) (root := root)
    (namespaceId := namespaceId) (owner := owner) (projectionStore := projectionStore) (family := family) (store := store) (signerOwner := signerOwner) (keyOwner := keyOwner) (driverOwner := driverOwner) (eligible := eligible) initial s) (b) :
    Weaver.SettlementAnchorRecovery.accountMaterialized c s.base.base.base.base.base.base.base b ≤ Weaver.FiniteDomainMigration.booked c s.base.base.base.base.base.base.base.authority.source.base.base.control.journal.head.payload b ∧
    Weaver.SettlementAnchorRecovery.accountMaterialized c s.base.base.base.base.base.base.base b ≤ c.capacity b :=
  Weaver.KeyBoundaryQueue.original_budget_remains_conserved (initialized_product_refines_key_boundary events) b

theorem unknown_original_reservation_stays_held (events : Run (c := c) (m := m) (p := p) (lineage := lineage) (root := root)
    (namespaceId := namespaceId) (owner := owner) (projectionStore := projectionStore) (family := family) (store := store) (signerOwner := signerOwner) (keyOwner := keyOwner) (driverOwner := driverOwner) (eligible := eligible) initial s)
    (sealed : s.base.base.base.base.base.base.seals k = some a) :
    (s.base.base.base.base.base.base.base.authority.source.base.base.control.journal.head.payload.messages k).reserved = true :=
  Weaver.KeyBoundaryQueue.unknown_original_reservation_stays_held (initialized_product_refines_key_boundary events) sealed

#print axioms unresolved_floor_intent_survives_until_original_commit
#print axioms newly_accepted_isolation_has_complete_scope
#print axioms registered_alias_never_relabels
#print axioms every_floor_append_keeps_exact_isolation_cut
#print axioms protected_floor_never_rolls_back
#print axioms committed_floor_log_never_shrinks
#print axioms journal_tracks_every_floor_commit
#print axioms every_new_export_requires_current_hardware
#print axioms validated_callback_has_original_current_envelope
#print axioms initialized_product_refines_key_boundary
#print axioms initialized_floor_log_is_complete
#print axioms original_consumption_and_settlement_remain_unique
#print axioms original_budget_remains_conserved
#print axioms unknown_original_reservation_stays_held
end Weaver.DeviceIsolationRecovery
