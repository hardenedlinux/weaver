import DynamicImportBoundary
namespace Weaver.DynamicImageCustody

-- Reference IDs denote successful load acquisitions, not module names.
-- Several references can belong to one OS image; entry identity stays separate.
structure State where
  opened : List Nat := []
  closed : List Nat := []
  unloaded : List Nat := []
  stopping : Bool := false

def Safe (owner : Nat → Nat) (s : State) : Prop :=
  ∀ image ∈ s.unloaded, ∀ ref ∈ s.opened, owner ref = image → ref ∈ s.closed

inductive Step (owner : Nat → Nat) : State → State → Prop where
  | acquire (s ref) (running : s.stopping = false) (fresh : ref ∉ s.opened)
      (mapped : owner ref ∉ s.unloaded) :
      Step owner s {s with opened := ref :: s.opened}
  | stop (s) : Step owner s {s with stopping := true}
  | close (s ref) (owned : ref ∈ s.opened) (fresh : ref ∉ s.closed) :
      Step owner s {s with closed := ref :: s.closed}
  | unload (s image) (stopped : s.stopping = true)
      (allClosed : ∀ ref ∈ s.opened, owner ref = image → ref ∈ s.closed) :
      Step owner s {s with unloaded := image :: s.unloaded}

inductive Run (owner : Nat → Nat) : State → State → Prop where
  | refl (s) : Run owner s s
  | next : Run owner a b → Step owner b d → Run owner a d

theorem shared_image_step_preserves_custody (safe : Safe owner s)
    (step : Step owner s t) : Safe owner t := by
  cases step with
  | acquire ref running fresh mapped =>
    intro image removed token acquired same
    simp only [List.mem_cons] at acquired
    rcases acquired with rfl | prior
    · exact False.elim (mapped (same.symm ▸ removed))
    · exact safe image removed token prior same
  | stop => exact safe
  | close ref owned fresh =>
    intro image removed token acquired same
    exact List.mem_cons_of_mem ref (safe image removed token acquired same)
  | unload image stopped allClosed =>
    intro target removed token acquired same
    simp only [List.mem_cons] at removed
    rcases removed with rfl | prior
    · exact allClosed token acquired same
    · exact safe target prior token acquired same

theorem initialized_shared_image_custody (run : Run owner {} s) : Safe owner s := by
  induction run with
  | refl => simp [Safe]
  | next prior step ih => exact shared_image_step_preserves_custody ih step

theorem live_alias_blocks_image_release (safe : Safe owner s)
    (acquired : ref ∈ s.opened) (pending : ref ∉ s.closed) : owner ref ∉ s.unloaded := by
  intro released
  exact pending (safe (owner ref) released ref acquired rfl)

theorem all_aliases_closed_after_image_release (safe : Safe owner s)
    (released : image ∈ s.unloaded) (acquired : ref ∈ s.opened)
    (same : owner ref = image) : ref ∈ s.closed := safe image released ref acquired same

theorem stopping_blocks_new_acquisition (s : State) (stopped : s.stopping = true)
    (running : s.stopping = false) : False := by
  simp [stopped] at running

theorem repeated_close_is_not_fresh (s : State) (closed : ref ∈ s.closed) : ¬ ref ∉ s.closed := by
  exact fun missing => missing closed

def MayInitialize (owner : Nat → Nat) (s : State) (ref : Nat) : Prop :=
  s.stopping = false ∧ ref ∈ s.opened ∧ ref ∉ s.closed ∧ owner ref ∉ s.unloaded

theorem shutdown_blocks_late_initialization (stopped : s.stopping = true) :
    ¬ MayInitialize owner s ref := by
  intro allowed
  have running := allowed.1
  simp [stopped] at running

theorem released_image_blocks_late_initialization (released : owner ref ∈ s.unloaded) :
    ¬ MayInitialize owner s ref := by
  intro allowed
  exact allowed.2.2.2 released

theorem image_packing_does_not_grant_policy
    (_safe : Safe imageOwner images)
    (native : GerbilExitQualification.Qualified clock receipt)
    (event : LlmRouting.Step router owner before after)
    (changed : after.dispatches ≠ before.dispatches) :
    ∃ p, owner.wireValid p ∧ owner.finalPolicyValid p (LlmRouting.view before) :=
  DynamicImportBoundary.dynamic_pass_still_requires_final_policy native event changed

#print axioms shared_image_step_preserves_custody
#print axioms initialized_shared_image_custody
#print axioms live_alias_blocks_image_release
#print axioms all_aliases_closed_after_image_release
#print axioms stopping_blocks_new_acquisition
#print axioms repeated_close_is_not_fresh
#print axioms shutdown_blocks_late_initialization
#print axioms released_image_blocks_late_initialization
#print axioms image_packing_does_not_grant_policy
end Weaver.DynamicImageCustody
