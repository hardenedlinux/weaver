-- SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
--
-- SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

import Std

namespace Weaver.ProviderEgressWindow

/- One model instance per canonical origin and attempt. The host must join
   every mutable Cedar input, original claim and fence into the current image,
   acquire an exclusive effect incarnation and mediate the actual transfer.
   History is a ghost of externally offered spans, not a volatile replay log. -/
structure Span where
  start : Nat
  width : Nat

def Span.stop (span : Span) : Nat := span.start + span.width

structure Window where
  owner : Nat
  burnOwner : Nat
  burned : Bool
  acknowledged : Bool
  requestBound : Bool
  sealed : Bool
  held : Nat
  bound : Nat
  cursor : Nat
  offered : List Span

structure Authority where
  durable : Nat
  projected : Nat
  pending : Bool

def Ready (authority : Authority) : Prop :=
  authority.pending = false ∧ authority.projected = authority.durable

def Custody (window : Window) : Prop :=
  window.burned = true ∧ window.acknowledged = true ∧
    window.sealed = false ∧ window.burnOwner = window.owner ∧ window.requestBound = true

/-- The arguments are live Cedar, exact frame binding and original-claim checks
    from the deciding owner. The volatile turn contains the transport offer. -/
def Eligible (window : Window) (authority : Authority) (span : Span)
    (cedar exact claim : Prop) : Prop :=
  Custody window ∧ Ready authority ∧ cedar ∧ exact ∧ claim ∧
    span.start = window.cursor ∧ 0 < span.width ∧ span.stop ≤ window.bound

def Prefix (window : Window) : Prop :=
  ∀ earlier ∈ window.offered, earlier.stop ≤ window.cursor ∧ 0 < earlier.width

def recordOffer (window : Window) (span : Span) : Window :=
  {window with cursor := span.stop, offered := span :: window.offered}

def retire (window : Window) : Window :=
  {window with acknowledged := false, requestBound := false, sealed := true}

def recover (window : Window) : Window :=
  {retire window with owner := window.owner + 1, cursor := 0}

theorem burn_without_confirmed_request_cannot_offer (window : Window) (authority : Authority)
    (span : Span) (cedar exact claim : Prop) (unknownRequest : window.requestBound = false) :
    ¬ Eligible window authority span cedar exact claim := by
  intro admission
  exact Bool.noConfusion (unknownRequest.symm.trans admission.1.2.2.2.2)

theorem pending_publication_blocks_offer (window : Window) (authority : Authority)
    (span : Span) (cedar exact claim : Prop) (pending : authority.pending = true) :
    ¬ Eligible window authority span cedar exact claim := by
  intro admission
  exact Bool.noConfusion (pending.symm.trans admission.2.1.1)

theorem stale_projection_blocks_offer (window : Window) (authority : Authority)
    (span : Span) (cedar exact claim : Prop) (stale : authority.projected ≠ authority.durable) :
    ¬ Eligible window authority span cedar exact claim :=
  fun admission => stale admission.2.1.2

theorem live_offer_rejoins_cedar_bytes_and_claim (window : Window) (authority : Authority)
    (span : Span) (cedar exact claim : Prop)
    (admission : Eligible window authority span cedar exact claim) :
    cedar ∧ exact ∧ claim :=
  ⟨admission.2.2.1, admission.2.2.2.1, admission.2.2.2.2.1⟩

theorem next_span_does_not_overlap_prefix (window : Window) (span : Span)
    (valid : Prefix window) (next : span.start = window.cursor) :
    ∀ earlier ∈ window.offered, earlier.stop ≤ span.start :=
  fun earlier member => next.symm ▸ (valid earlier member).1

theorem record_offer_preserves_prefix (window : Window) (span : Span)
    (valid : Prefix window) (next : span.start = window.cursor) (width : 0 < span.width) :
    Prefix (recordOffer window span) := by
  intro earlier member
  change earlier ∈ span :: window.offered at member
  change earlier.stop ≤ span.stop ∧ 0 < earlier.width
  cases List.mem_cons.mp member with
  | inl same => subst earlier; exact ⟨Nat.le_refl _, width⟩
  | inr old =>
    have ⟨ending, positive⟩ := valid earlier old
    exact ⟨Nat.le_trans ending (next ▸ Nat.le_add_right span.start span.width), positive⟩

theorem offered_span_cannot_be_offered_again (window : Window) (span : Span)
    (valid : Prefix window) (old : span ∈ window.offered) (width : 0 < span.width) :
    span.start ≠ window.cursor := by
  intro same
  have ending := (valid span old).1
  unfold Span.stop at ending
  omega

theorem loss_and_restart_never_refund (window : Window) :
    (retire window).held = window.held ∧ (recover window).held = window.held :=
  ⟨rfl, rfl⟩

theorem loss_and_restart_close_old_window (window : Window) :
    ¬ Custody (retire window) ∧ ¬ Custody (recover window) :=
  ⟨fun custody => Bool.noConfusion custody.2.1,
   fun custody => Bool.noConfusion custody.2.1⟩

theorem old_incarnation_cannot_rejoin (window : Window)
    (burn : window.burnOwner = window.owner) :
    window.burnOwner ≠ (recover window).owner := by
  intro joined
  change window.burnOwner = window.owner + 1 at joined
  omega

inductive Offers : Window → Window → Prop where
  | empty (window) : Offers window window
  | advance {initial current : Window} (prior : Offers initial current)
      (authority : Authority) (span : Span) (cedar exact claim : Prop)
      (eligible : Eligible current authority span cedar exact claim) :
      Offers initial (recordOffer current span)

theorem any_accepted_trace_keeps_disjoint_prefix {initial final : Window}
    (trace : Offers initial final) (initialValid : Prefix initial) : Prefix final := by
  induction trace with
  | empty => exact initialValid
  | advance _ _ span _ _ _ eligible ih =>
    exact record_offer_preserves_prefix _ span ih eligible.2.2.2.2.2.1 eligible.2.2.2.2.2.2.1

/-- A stale cut cannot activate even when its observed durable generation
    happens to match. Cut IDs also guard the mutation CAS itself. -/
def MayActivate (cut currentCut observed durable : Nat) (settled : Prop) : Prop :=
  cut = currentCut ∧ observed = durable ∧ settled

theorem matching_image_does_not_reopen_old_cut (cut current observed durable : Nat)
    (settled : Prop) (old : cut ≠ current) :
    ¬ MayActivate cut current observed durable settled :=
  fun activation => old activation.1

/-- An edge means that two origins share an exact mutable execution domain.
    Taking the transitive closure prevents a middle origin from participating
    in two independent owners through different roots. -/
inductive Connected {Origin : Type} (overlap : Origin → Origin → Prop) :
    Origin → Origin → Prop where
  | same (origin) : Connected overlap origin origin
  | step {left middle right} (shares : overlap left middle)
      (rest : Connected overlap middle right) : Connected overlap left right

theorem connected_roots_cannot_use_distinct_lanes {Origin Lane : Type}
    {overlap : Origin → Origin → Prop} (lane : Origin → Lane)
    (edge : ∀ left right, overlap left right → lane left = lane right)
    {left right : Origin} (path : Connected overlap left right) :
    lane left = lane right := by
  induction path with
  | same => rfl
  | step shares _ rest => exact (edge _ _ shares).trans rest

structure Settlement where
  terminalDurable : Bool
  transportRetired : Bool
  authenticExactUsage : Bool
  applied : Bool
  held : Nat

def settle (account : Settlement) : Settlement :=
  if account.terminalDurable && account.transportRetired &&
     account.authenticExactUsage && !account.applied then
    {account with held := 0, applied := true}
  else account

theorem missing_terminal_cannot_refund (account : Settlement)
    (unknown : account.terminalDurable = false) : settle account = account := by
  simp [settle, unknown]

theorem replay_cannot_apply_settlement (account : Settlement)
    (used : account.applied = true) : settle account = account := by
  simp [settle, used]

theorem settlement_is_idempotent (account : Settlement) : settle (settle account) = settle account := by
  cases account with
  | mk terminal retired authentic applied held =>
    cases terminal <;> cases retired <;> cases authentic <;> cases applied <;> rfl

/-- Measure elapsed time shared by a waiting ticket and one holder stage
    on the same monotonic clock. Disjoint holder stages can be attributed
    separately. A stream-wide commit total is not such an interval. -/
def waitOverlap (arrival grant stageStart stageEnd : Nat) : Nat :=
  min grant stageEnd - max arrival stageStart

theorem holder_stage_overlap_cannot_exceed_ticket_wait (arrival grant stageStart stageEnd : Nat) :
    waitOverlap arrival grant stageStart stageEnd ≤ grant - arrival := by
  have upper := Nat.min_le_left grant stageEnd
  have lower := Nat.le_max_left arrival stageStart
  unfold waitOverlap
  omega

/-- A deterministic ready-path envelope, conditional on the measured stages
    and bounded predecessor count. This is not a measured P99 result. -/
def readyBound (encode ahead service scheduler handoff : Nat) : Nat :=
  encode + (ahead + 1) * service + scheduler + handoff

theorem admitted_four_turn_envelope (encode ahead service scheduler handoff : Nat)
    (enc : encode ≤ 100) (capacity : ahead ≤ 3) (turn : service ≤ 150)
    (admit : scheduler ≤ 50) (write : handoff ≤ 200) :
    readyBound encode ahead service scheduler handoff ≤ 950 := by
  have queue : (ahead + 1) * service ≤ 600 :=
    Nat.le_trans (Nat.mul_le_mul_right service (by omega : ahead + 1 ≤ 4))
      (Nat.mul_le_mul_left 4 turn)
  unfold readyBound
  omega

#print axioms burn_without_confirmed_request_cannot_offer
#print axioms pending_publication_blocks_offer
#print axioms stale_projection_blocks_offer
#print axioms live_offer_rejoins_cedar_bytes_and_claim
#print axioms next_span_does_not_overlap_prefix
#print axioms record_offer_preserves_prefix
#print axioms offered_span_cannot_be_offered_again
#print axioms loss_and_restart_never_refund
#print axioms loss_and_restart_close_old_window
#print axioms old_incarnation_cannot_rejoin
#print axioms any_accepted_trace_keeps_disjoint_prefix
#print axioms matching_image_does_not_reopen_old_cut
#print axioms connected_roots_cannot_use_distinct_lanes
#print axioms missing_terminal_cannot_refund
#print axioms replay_cannot_apply_settlement
#print axioms settlement_is_idempotent
#print axioms holder_stage_overlap_cannot_exceed_ticket_wait
#print axioms admitted_four_turn_envelope

end Weaver.ProviderEgressWindow
