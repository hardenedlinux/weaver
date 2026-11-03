-- SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
--
-- SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

import DynamicImageCustody
namespace Weaver.DynamicPairedEvidence

-- A receipt is immutable. Repetition appends another receipt, never rewrites one.
structure Receipt where
  sample : Nat
  elapsed : Nat
  natural : Bool
  cleaned : Bool
  checks : Bool
  buildComplete : Bool
  inputs : Bool
  fixture : Nat
  objects : Nat
  compiler : Nat
  freshInode : Bool
  freshNamespace : Bool
  firstUse : Bool
  hostControlled : Bool

def Eligible (r : Receipt) : Prop :=
  r.elapsed ≤ 15 ∧ r.natural = true ∧ r.cleaned = true ∧
  r.checks = true ∧ r.inputs = true ∧ r.buildComplete = true

def Matched (a b : Receipt) : Prop :=
  a.fixture = b.fixture ∧ a.objects = b.objects ∧ a.compiler = b.compiler

def FirstGeneration (r : Receipt) : Prop :=
  r.freshInode = true ∧ r.freshNamespace = true ∧ r.firstUse = true

-- Inode/path freshness says nothing about OS caches, UUID registration or observers.
def HostColdAdmissible (r : Receipt) : Prop :=
  FirstGeneration r ∧ r.hostControlled = true

inductive Append : List Receipt → List Receipt → Prop where
  | record (prior : List Receipt) (r : Receipt) (fresh : ∀ old ∈ prior, old.sample ≠ r.sample) :
      Append prior (r :: prior)
inductive Run : List Receipt → List Receipt → Prop where
  | refl (s) : Run s s
  | next : Run a b → Append b c → Run a c

theorem retained_receipts (run : Run before after) : ∀ r ∈ before, r ∈ after := by
  induction run with
  | refl => exact fun _ h => h
  | next prior step ih =>
    cases step with
    | record old fresh => exact fun r h => List.mem_cons_of_mem _ (ih r h)

theorem failed_receipt_cannot_be_erased (run : Run before after)
    (present : r ∈ before) (failed : ¬ Eligible r) : ∃ old ∈ after, ¬ Eligible old :=
  ⟨r, retained_receipts run r present, failed⟩

def SeriesEligible (samples : List Receipt) : Prop := ∀ r ∈ samples, Eligible r

theorem one_failure_blocks_series (present : r ∈ samples) (failed : ¬ Eligible r) :
    ¬ SeriesEligible samples := fun allPassed => failed (allPassed r present)

theorem late_natural_exit_fails (r : Receipt) (late : 15 < r.elapsed) : ¬ Eligible r := by
  intro h; have bound := h.1; omega

theorem live_resources_fail (r : Receipt) (live : r.cleaned = false) : ¬ Eligible r := by
  intro h; simp [Eligible, live] at h

theorem fresh_files_do_not_control_host (r : Receipt) (uncontrolled : r.hostControlled = false) :
    ¬ HostColdAdmissible r := by
  intro h; simp [HostColdAdmissible, uncontrolled] at h

theorem partial_producer_cannot_qualify (r : Receipt) (partialBuild : r.buildComplete = false) :
    ¬ Eligible r := by
  intro h; simp [Eligible, partialBuild] at h

theorem object_mismatch_blocks_pair (a b : Receipt) (different : a.objects ≠ b.objects) :
    ¬ Matched a b := by
  intro h; exact different h.2.1

-- API counts are structural evidence. Wall time also contains an unconstrained host term.
theorem fewer_images_need_not_mean_faster :
    ∃ (candidateImages controlImages candidateTime controlTime : Nat),
      candidateImages < controlImages ∧ controlTime < candidateTime :=
  ⟨7, 98, 16, 8, by decide, by decide⟩

theorem whole_process_gate_composes
    (native : GerbilExitQualification.Qualified c s)
    (fixed : c.budget = 15) : s.elapsed ≤ 15 ∧ s.handles = [] := by
  exact ⟨fixed ▸ GerbilExitQualification.qualification_preserves_deadline native, (GerbilExitQualification.qualification_preserves_cleanup native).2⟩

theorem evidence_cannot_mint_dispatch (_receipt : Eligible r)
    (step : LlmRouting.Step router owner before after)
    (changed : after.dispatches ≠ before.dispatches) :
    ∃ p, owner.wireValid p ∧ owner.finalPolicyValid p (LlmRouting.view before) := by
  obtain ⟨p,stored,bound,current,eligible,wire,policy,fresh⟩ :=
    LlmRouting.actual_dispatch_rechecks_target step changed
  exact ⟨p,wire,policy⟩

#print axioms retained_receipts
#print axioms failed_receipt_cannot_be_erased
#print axioms one_failure_blocks_series
#print axioms late_natural_exit_fails
#print axioms live_resources_fail
#print axioms fresh_files_do_not_control_host
#print axioms partial_producer_cannot_qualify
#print axioms object_mismatch_blocks_pair
#print axioms fewer_images_need_not_mean_faster
#print axioms whole_process_gate_composes
#print axioms evidence_cannot_mint_dispatch
end Weaver.DynamicPairedEvidence
