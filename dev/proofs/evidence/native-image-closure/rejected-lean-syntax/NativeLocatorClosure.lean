import DynamicPairedEvidence
namespace Weaver.NativeLocatorClosure

structure Locator where
  image : Nat
  entry : Nat
  deriving DecidableEq
structure Manifest where
  modules : List Nat
  locate : Nat → Locator
  originalEntry : Nat → Nat
  producerComplete : Bool
  pureBodies : Bool

def EntryPreserved (m : Manifest) : Prop :=
  ∀ mid ∈ m.modules, (m.locate mid).entry = m.originalEntry mid

def CollisionFree (m : Manifest) : Prop :=
  ∀ a ∈ m.modules, ∀ b ∈ m.modules,
    (m.locate a).image = (m.locate b).image → m.originalEntry a = m.originalEntry b → a = b

def Admitted (m : Manifest) : Prop :=
  m.producerComplete = true ∧ m.pureBodies = true ∧ EntryPreserved m ∧ CollisionFree m

def Resolves (m : Manifest) (whereAt : Locator) (mid : Nat) : Prop :=
  mid ∈ m.modules ∧ m.locate mid = whereAt

theorem qualified_lookup_is_unique (valid : Admitted m)
    (first : Resolves m whereAt a) (second : Resolves m whereAt b) : a = b := by
  have same : m.locate a = m.locate b := first.2.trans second.2.symm
  apply valid.2.2.2 a first.1 b second.1
  · exact congrArg Locator.image same
  · exact (valid.2.2.1 a first.1).symm.trans ((congrArg Locator.entry same).trans (valid.2.2.1 b second.1))

theorem colliding_names_require_different_images (valid : Admitted m)
    (first : a ∈ m.modules) (second : b ∈ m.modules)
    (different : a ≠ b) (sameEntry : m.originalEntry a = m.originalEntry b) :
    (m.locate a).image ≠ (m.locate b).image := by
  intro sameImage
  exact different (valid.2.2.2 a first b second sameImage sameEntry)

theorem wrong_image_cannot_resolve (m : Manifest) (whereAt : Locator) (mid : Nat) (wrong : (m.locate mid).image ≠ whereAt.image) :
    ¬ Resolves m whereAt mid := by
  intro resolved; exact wrong (congrArg Locator.image resolved.2)

theorem incomplete_producer_cannot_publish (m : Manifest) (missing : m.producerComplete = false) : ¬ Admitted m := by
  intro valid; have done := valid.1; simp [missing] whereAt done

theorem foreign_initializer_cannot_publish (m : Manifest) (foreignBody : m.pureBodies = false) : ¬ Admitted m := by
  intro valid; have pureBody := valid.2.1; simp [foreignBody] whereAt pureBody

theorem native_entries_preserve_original_owner (valid : Admitted m)
    (resolved : Resolves m whereAt mid) : whereAt.entry = m.originalEntry mid := by
  exact (congrArg Locator.entry resolved.2).symm.trans (valid.2.2.1 mid resolved.1)

-- All exported C definitions are checked by the native publisher. The abstract
-- entry condition below is necessary, not a proof of Mach-O linking correctness.
theorem identical_locator_cannot_name_distinct_modules (valid : Admitted m)
    (aMember : a ∈ m.modules) (bMember : b ∈ m.modules)
    (same : m.locate a = m.locate b) : a = b :=
  qualified_lookup_is_unique valid ⟨aMember,rfl⟩ ⟨bMember,same.symm⟩

theorem shared_image_preserves_all_owned_refs
    (run : DynamicImageCustody.Run owner {} images) : DynamicImageCustody.Safe owner images :=
  DynamicImageCustody.initialized_shared_image_custody run

theorem late_exit_rejects_even_with_valid_partition (_valid : Admitted m)
    (late : clock.budget < receipt.elapsed) : ¬ NativeExitQualification.Qualified clock receipt :=
  NativeExitQualification.late_natural_exit_still_fails late

theorem shared_native_profile_never_grants_dispatch (_valid : Admitted m)
    (pass : NativeExitQualification.Qualified clock receipt)
    (step : LlmRouting.Step router owner before after)
    (changed : after.dispatches ≠ before.dispatches) :
    ∃ p, owner.wireValid p ∧ owner.finalPolicyValid p (LlmRouting.view before) :=
  NativeExitQualification.natural_pass_still_needs_gateway_policy pass step changed

#print axioms qualified_lookup_is_unique
#print axioms colliding_names_require_different_images
#print axioms wrong_image_cannot_resolve
#print axioms incomplete_producer_cannot_publish
#print axioms foreign_initializer_cannot_publish
#print axioms native_entries_preserve_original_owner
#print axioms identical_locator_cannot_name_distinct_modules
#print axioms shared_image_preserves_all_owned_refs
#print axioms late_exit_rejects_even_with_valid_partition
#print axioms shared_native_profile_never_grants_dispatch
end Weaver.NativeLocatorClosure
