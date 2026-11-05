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

namespace Weaver.ProviderEgressWindow.Promotion

/-- A field is a semantic input, not a table name. Time remains live at offer. -/
inductive Input where
  | policy | oauth | claim | budget | history | domain | profile | fence
  deriving DecidableEq

/-- Covers all host writers, including a witness append outside Turso.
    This premise has to be established by the host; it is not inferred
    from a successful proof of the state machine. -/
def Covered {Writer : Type} (affects : Writer → Input → Prop)
    (mediated : Writer → Prop) : Prop :=
  ∀ writer input, affects writer input → mediated writer

structure Cut where
  serial : Nat
  durable : Nat
  witness : Nat
  /-- Globally unique close tickets; never recycled client operation labels. -/
  pending : List Nat
  uncertain : List Nat
  activated : Bool

structure Image where
  serial : Nat
  durable : Nat
  witness : Nat
  deriving DecidableEq

def image (cut : Cut) : Image := ⟨cut.serial, cut.durable, cut.witness⟩

def Qualified (cut : Cut) (observed : Image) : Prop :=
  cut.pending = [] ∧ cut.uncertain = [] ∧ observed = image cut

def close (cut : Cut) (operation : Nat) : Cut :=
  {cut with serial := cut.serial + 1, pending := operation :: cut.pending, activated := false}

/-- Outcomes are joined individually. A native rollback cannot assert absence
    of a durable witness append. An unknown operation remains outstanding. -/
def decide (cut : Cut) (operation : Nat) (db witness : Nat) : Cut :=
  {cut with durable := db, witness := witness, pending := cut.pending.erase operation, activated := false}

def activate (cut : Cut) (observed : Image) (_proof : Qualified cut observed) : Cut :=
  {cut with activated := true}

def Open (cut : Cut) : Prop :=
  cut.activated = true ∧ cut.pending = [] ∧ cut.uncertain = []

theorem every_effect_writer_needs_mediation {Writer : Type}
    (affects : Writer → Input → Prop) (mediated : Writer → Prop)
    (coverage : Covered affects mediated) (writer : Writer) (input : Input)
    (effect : affects writer input) : mediated writer := coverage writer input effect

theorem close_prevents_offer (cut : Cut) (operation : Nat) : ¬ Open (close cut operation) := by
  intro ready
  exact Bool.noConfusion ready.1

theorem pending_writer_blocks_activation (cut : Cut) (observed : Image) (operation : Nat)
    (outstanding : operation ∈ cut.pending) : ¬ Qualified cut observed := by
  intro qualified
  rw [qualified.1] at outstanding
  exact List.not_mem_nil outstanding

theorem completing_one_writer_keeps_distinct_pending (cut : Cut) (first second db witness : Nat)
    (outstanding : second ∈ cut.pending) (different : second ≠ first) :
    second ∈ (decide cut first db witness).pending := by
  exact (List.mem_erase_of_ne different).mpr outstanding

theorem other_writer_blocks_activation (cut : Cut) (observed : Image)
    (first second db witness : Nat) (outstanding : second ∈ cut.pending)
    (different : second ≠ first) : ¬ Qualified (decide cut first db witness) observed :=
  pending_writer_blocks_activation _ observed second
    (completing_one_writer_keeps_distinct_pending cut first second db witness outstanding different)

theorem uncertain_effect_blocks_activation (cut : Cut) (observed : Image) (operation : Nat)
    (unknown : operation ∈ cut.uncertain) : ¬ Qualified cut observed := by
  intro qualified
  rw [qualified.2.1] at unknown
  exact List.not_mem_nil unknown

theorem unchanged_database_does_not_revalidate_old_read (cut : Cut) (operation : Nat) :
    image cut ≠ image (close cut operation) := by
  intro same
  have serial := congrArg Image.serial same
  simp only [image, close] at serial
  omega

theorem witness_ahead_blocks_old_image (cut : Cut) (observed : Image)
    (ahead : observed.witness ≠ cut.witness) : ¬ Qualified cut observed := by
  intro qualified
  exact ahead (congrArg Image.witness qualified.2.2)

theorem activated_image_has_no_unresolved_writer (cut : Cut) (observed : Image)
    (qualified : Qualified cut observed) : Open (activate cut observed qualified) :=
  ⟨rfl, qualified.1, qualified.2.1⟩

/-- A transport offer is inside the same serialized owner turn as the live
    checks. Enqueue is deliberately absent from this definition. -/
structure Custody where
  incarnation : Nat
  retired : Bool
  cursor : Nat

structure Frame where
  incarnation : Nat
  cut : Image
  start : Nat
  width : Nat

def CanDeliver (cut : Cut) (owner : Custody) (frame : Frame)
    (freshCedar exactClaim liveClock exactBytes : Prop) : Prop :=
  Open cut ∧ frame.cut = image cut ∧ owner.retired = false ∧
    frame.incarnation = owner.incarnation ∧ frame.start = owner.cursor ∧
    0 < frame.width ∧ freshCedar ∧ exactClaim ∧ liveClock ∧ exactBytes

def delivered (owner : Custody) (frame : Frame) : Custody :=
  {owner with cursor := owner.cursor + frame.width}

def replace (owner : Custody) : Custody :=
  ⟨owner.incarnation + 1, false, 0⟩

theorem only_current_owner_can_deliver (cut : Cut) (owner : Custody) (frame : Frame)
    (cedar claim clock bytes : Prop) (old : frame.incarnation ≠ owner.incarnation) :
    ¬ CanDeliver cut owner frame cedar claim clock bytes := fun live => old live.2.2.2.1

theorem old_queued_frame_cannot_follow_replacement (cut : Cut) (owner : Custody) (frame : Frame)
    (cedar claim clock bytes : Prop) (issued : frame.incarnation = owner.incarnation) :
    ¬ CanDeliver cut (replace owner) frame cedar claim clock bytes := by
  apply only_current_owner_can_deliver
  simp only [replace]
  omega

theorem delivered_frame_cannot_be_delivered_twice (cut : Cut) (owner : Custody) (frame : Frame)
    (cedar claim clock bytes : Prop) (live : CanDeliver cut owner frame cedar claim clock bytes) :
    ¬ CanDeliver cut (delivered owner frame) frame cedar claim clock bytes := by
  intro again
  have start := live.2.2.2.2.1
  have positive := live.2.2.2.2.2.1
  have next := again.2.2.2.2.1
  simp only [delivered] at next
  omega

theorem queue_is_not_delivery_evidence (cut : Cut) (owner : Custody) (frame : Frame)
    (cedar claim clock bytes : Prop) (operation : Nat) :
    ¬ CanDeliver (close cut operation) owner frame cedar claim clock bytes :=
  fun admission => close_prevents_offer cut operation admission.1

/-- Erase the fully joined image to the scalar authority used by the interval
    model only after the receiver-side promotion predicate has been checked. -/
def asAuthority (cut : Cut) : Authority := ⟨cut.durable, cut.durable, !cut.activated⟩

theorem receiver_promotion_refines_interval_admission
    (cut : Cut) (owner : Custody) (frame : Frame) (window : Window)
    (cedar claim clock bytes : Prop)
    (admission : CanDeliver cut owner frame cedar claim clock bytes)
    (burn : Weaver.ProviderEgressWindow.Custody window)
    (sequence : frame.start = window.cursor) (bound : frame.start + frame.width ≤ window.bound) :
    Eligible window (asAuthority cut) ⟨frame.start, frame.width⟩ cedar bytes claim := by
  have active := admission.1.1
  have ready : Ready (asAuthority cut) := by simp [Ready, asAuthority, active]
  exact ⟨burn, ready, admission.2.2.2.2.2.2.1,
    admission.2.2.2.2.2.2.2.2.2, admission.2.2.2.2.2.2.2.1,
    sequence, admission.2.2.2.2.2.1, bound⟩

/-- A durable client ID can be retried, but a mutation-completion ticket also
    binds its close serial and command. A previous ticket cannot resolve a
    fresh close even when the client chose the same operation label. -/
structure MutationReceipt where
  closeSerial : Nat
  command : Nat
  outcome : Nat
  deriving DecidableEq

def ExactReceipt (expected actual : MutationReceipt) : Prop := expected = actual

theorem old_close_receipt_cannot_resolve_new_intent (expected actual : MutationReceipt)
    (old : expected.closeSerial ≠ actual.closeSerial) : ¬ ExactReceipt expected actual := by
  intro same
  exact old (congrArg MutationReceipt.closeSerial same)

theorem expired_clock_blocks_receiver (cut : Cut) (owner : Custody) (frame : Frame)
    (cedar claim clock bytes : Prop) (expired : ¬ clock) :
    ¬ CanDeliver cut owner frame cedar claim clock bytes :=
  fun admission => expired admission.2.2.2.2.2.2.2.2.1

#print axioms old_close_receipt_cannot_resolve_new_intent
#print axioms expired_clock_blocks_receiver

#print axioms receiver_promotion_refines_interval_admission

#print axioms every_effect_writer_needs_mediation
#print axioms close_prevents_offer
#print axioms pending_writer_blocks_activation
#print axioms completing_one_writer_keeps_distinct_pending
#print axioms other_writer_blocks_activation
#print axioms uncertain_effect_blocks_activation
#print axioms unchanged_database_does_not_revalidate_old_read
#print axioms witness_ahead_blocks_old_image
#print axioms activated_image_has_no_unresolved_writer
#print axioms only_current_owner_can_deliver
#print axioms old_queued_frame_cannot_follow_replacement
#print axioms delivered_frame_cannot_be_delivered_twice
#print axioms queue_is_not_delivery_evidence

end Weaver.ProviderEgressWindow.Promotion

namespace Weaver.ProviderEgressWindow.DeliveryJoin

/-- The existing Turso range guard supplies the complete same-view check.
    A staged frame has no authority until that scope's acknowledgment; the
    receiver compares its validation revision inside the final owner turn. -/
structure Receipt where
  validatedRevision : Nat
  acknowledged : Bool
  consumed : Bool
  incarnation : Nat

def Current (receipt : Receipt) (revision incarnation pending orphaned : Nat)
    (failed : Bool) : Prop :=
  receipt.acknowledged = true ∧ receipt.consumed = false ∧ failed = false ∧
    receipt.validatedRevision = revision ∧ receipt.incarnation = incarnation ∧
    pending = 0 ∧ orphaned = 0

theorem staged_frame_is_not_permission (receipt : Receipt) (revision incarnation pending orphaned : Nat)
    (failed : Bool) (unconfirmed : receipt.acknowledged = false) :
    ¬ Current receipt revision incarnation pending orphaned failed := by
  intro current
  exact Bool.noConfusion (unconfirmed.symm.trans current.1)

theorem changed_view_requires_requalification (receipt : Receipt) (revision incarnation pending orphaned : Nat)
    (failed : Bool) (changed : receipt.validatedRevision ≠ revision) :
    ¬ Current receipt revision incarnation pending orphaned failed := fun current => changed current.2.2.2.1

theorem orphaned_witness_cannot_activate (receipt : Receipt) (revision incarnation pending orphaned : Nat)
    (failed : Bool) (unknown : orphaned ≠ 0) :
    ¬ Current receipt revision incarnation pending orphaned failed := fun current => unknown current.2.2.2.2.2.2

theorem consumed_receipt_cannot_be_requalified (receipt : Receipt)
    (revision incarnation pending orphaned : Nat) (failed : Bool) :
    ¬ Current {receipt with consumed := true} revision incarnation pending orphaned failed := by
  intro current
  exact Bool.noConfusion current.2.1

#print axioms staged_frame_is_not_permission
#print axioms changed_view_requires_requalification
#print axioms orphaned_witness_cannot_activate
#print axioms consumed_receipt_cannot_be_requalified

/-- Aborting a known empty exclusive transaction preserves the certificate only
when the driver has definitively joined rollback and cannot later commit.
An unchanged idle read or an independent witness effect supplies no such premise. -/
theorem known_absent_transaction_preserves_certificate (receipt : Receipt)
    (before after incarnation : Nat) (same : after = before)
    (current : Current receipt before incarnation 0 0 false) :
    Current receipt after incarnation 0 0 false := by
  simpa only [same] using current

/-- The final turn also checks a clock and cancellation deadline that may change
without a storage write. Currentness alone does not authorize an expired offer. -/
def TimelyOffer (current clock deadline : Prop) : Prop := current ∧ clock ∧ deadline

theorem elapsed_deadline_blocks_current_receipt (current clock deadline : Prop)
    (expired : ¬ deadline) : ¬ TimelyOffer current clock deadline :=
  fun offer => expired offer.2.2

theorem replacement_owner_cannot_use_receipt (receipt : Receipt)
    (revision incarnation pending orphaned : Nat) (failed : Bool)
    (replaced : receipt.incarnation ≠ incarnation) :
    ¬ Current receipt revision incarnation pending orphaned failed :=
  fun current => replaced current.2.2.2.2.1

#print axioms known_absent_transaction_preserves_certificate
#print axioms elapsed_deadline_blocks_current_receipt
#print axioms replacement_owner_cannot_use_receipt

/-- Logical Rust roles retain the lease; inherited custody-file descriptors do
not mint an execution role. Reference accounting and engine-drain ordering are
Host premises exercised by the real descriptor and subprocess controls. -/
structure OwnerLease where
  roles : Nat
  descriptorCopies : Nat
  held : Bool

def retireLease (lease : OwnerLease) : OwnerLease :=
  if lease.roles = 0 then {lease with held := false} else lease

theorem retained_role_blocks_custody_retirement (lease : OwnerLease)
    (retained : lease.roles ≠ 0) : retireLease lease = lease := by
  simp [retireLease, retained]

theorem retired_roles_release_lease_despite_descriptor_copies (lease : OwnerLease)
    (retired : lease.roles = 0) : (retireLease lease).held = false := by
  simp [retireLease, retired]

theorem descriptor_copy_cannot_change_role_count (lease : OwnerLease) (copies : Nat) :
    (retireLease {lease with descriptorCopies := copies}).roles = lease.roles := by
  simp [retireLease]
  split <;> rfl

#print axioms retained_role_blocks_custody_retirement
#print axioms retired_roles_release_lease_despite_descriptor_copies
#print axioms descriptor_copy_cannot_change_role_count

end Weaver.ProviderEgressWindow.DeliveryJoin
