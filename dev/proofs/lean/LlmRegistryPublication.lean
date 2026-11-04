-- SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
--
-- SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

import LlmAuthoritativeScope
namespace Weaver.LlmRegistryPublication

structure Blob where
  tenant : Nat
  commitment : Nat
  sourceVector : Nat
  profile : Weaver.LlmAuthoritativeScope.Contract
  deriving DecidableEq
structure Binding where
  operation : Nat
  tenant : Nat
  record : Weaver.LlmAuthoritativeScope.Record
  blob : Blob
  deriving DecidableEq
structure Image where
  binding : Binding
  position : Nat
  fence : Nat
  executionRevision : Nat
  deriving DecidableEq
structure Permit where
  id : Nat
  image : Image
  worker : Nat
  deriving DecidableEq
structure State where
  execution : Weaver.LlmAuthoritativeScope.State := Weaver.LlmAuthoritativeScope.initial
  revision : Nat := 0
  fence : Nat := 0
  blobs : List Blob := []
  readable : List Blob := []
  intent : Option Binding := none
  journal : List Binding := []
  journalVisible : Nat := 0
  certified : Bool := false
  acknowledged : Bool := false
  online : Bool := true
  projection : Option Image := none
  active : Bool := false
  permits : List Permit := []

def initial : State := {}
structure Owner where
  blobDurable : Blob → Prop
  publishValid : Binding → Nat → Prop
  blobRead : Blob → Prop
  rootCommit : Binding → Nat → Prop
  currentRead : Image → Prop
  sessionValid : Nat → Prop

def Valid (registry : Weaver.LlmAuthoritativeScope.Registry) (key tenant vector : Nat) (b : Binding) : Prop :=
  b.tenant = tenant ∧ b.blob.tenant = tenant ∧ b.blob.sourceVector = vector ∧
  b.record.key = key ∧ b.record.commitment = registry.commitment key ∧
  b.blob.commitment = b.record.commitment ∧ registry.resolve b.blob.commitment = some b.blob.profile

def image (s : State) (b : Binding) : Image := ⟨b,s.journal.length,s.fence,s.revision⟩
def Ready (s : State) (b : Binding) : Prop :=
  s.intent = some b ∧ s.journal = [b] ∧ s.certified = true ∧
  s.journalVisible = s.journal.length ∧ b.blob ∈ s.readable ∧ s.online = true ∧
  s.execution.record = some b.record ∧ s.execution.recovered = true

def Gate (s : State) (p : Permit) : Prop :=
  p ∈ s.permits ∧ s.active = true ∧ Ready s p.image.binding ∧
  s.projection = some (image s p.image.binding) ∧ p.image = image s p.image.binding ∧ p.worker = s.fence

def Safe (registry : Weaver.LlmAuthoritativeScope.Registry) (key tenant vector : Nat) (s : State) : Prop :=
  (∀ b, s.intent = some b → Valid registry key tenant vector b) ∧
  (∀ b ∈ s.journal, s.intent = some b) ∧ s.journal.length ≤ 1 ∧
  (s.certified = true → ∃ b, s.intent = some b ∧ s.journal = [b]) ∧
  (s.active = true → ∃ b, Ready s b ∧ s.projection = some (image s b))

def restarted (e : Weaver.LlmAuthoritativeScope.State) : Weaver.LlmAuthoritativeScope.State :=
  {e with
    boot := e.boot+1, recovered := false,
    children := {e.children with epoch := e.children.epoch+1, retired := fun _ => true},
    semantic := fun i => {e.semantic i with epoch := (e.semantic i).epoch+1, retired := true}}

inductive Step (source : Weaver.GatewayHeadCAS.Config) (registry : Weaver.LlmAuthoritativeScope.Registry) (routing : Weaver.LlmRouting.Config) (profile : Weaver.LlmAttemptLedger.Profile)
    (rootOwner : Weaver.GatewayHeadCAS.Owner) (childOwner : Weaver.LlmAttemptLedger.Owner) (codec : Weaver.LlmSemanticContract.Owner) (scopeOwner : Weaver.LlmAuthoritativeScope.Owner)
    (owner : Owner) (tenant vector : Nat) : State → State → Prop where
  | storeBlob (s b) (durable : owner.blobDurable b)
      (compatible : ∀ old ∈ s.blobs, old.tenant = b.tenant → old.commitment = b.commitment → old = b) :
      Step source registry routing profile rootOwner childOwner codec scopeOwner owner tenant vector s
        {s with blobs := s.blobs ++ [b], readable := s.readable ++ [b]}
  | reserveIntent (s b h worker) (fresh : s.intent = none)
      (origin : Weaver.LlmAuthoritativeScope.Origin source registry routing.root s.execution b.record h)
      (valid : Valid registry routing.root tenant vector b) (stored : b.blob ∈ s.blobs)
      (workerCurrent : worker = s.fence) (session : owner.sessionValid worker) (online : s.online = true)
      (sourceOnline : s.execution.roots.authorityOnline = true) (sourceRecovered : s.execution.recovered = true)
      (authentic : rootOwner.headReadValid (Weaver.GatewayHeadCAS.view s.execution.roots h))
      (publish : owner.publishValid b worker) :
      Step source registry routing profile rootOwner childOwner codec scopeOwner owner tenant vector s {s with intent := some b}
  | commitRoot (s b worker) (intent : s.intent = some b) (fresh : s.journal = [])
      (workerCurrent : worker = s.fence) (session : owner.sessionValid worker) (online : s.online = true)
      (durable : owner.rootCommit b 1) :
      Step source registry routing profile rootOwner childOwner codec scopeOwner owner tenant vector s
        {s with journal := [b], journalVisible := 1}
  | certify (s b worker) (intent : s.intent = some b) (journal : s.journal = [b])
      (visible : s.journalVisible = 1) (workerCurrent : worker = s.fence)
      (session : owner.sessionValid worker) (online : s.online = true) (durable : owner.rootCommit b 1) :
      Step source registry routing profile rootOwner childOwner codec scopeOwner owner tenant vector s {s with certified := true}
  | queryCertified (s b) (intent : s.intent = some b) (certified : s.certified = true) :
      Step source registry routing profile rootOwner childOwner codec scopeOwner owner tenant vector s {s with acknowledged := true}
  | loseReply (s) : Step source registry routing profile rootOwner childOwner codec scopeOwner owner tenant vector s {s with acknowledged := false}
  | restoreJournal (s b) (intent : s.intent = some b) (journal : s.journal = [b])
      (durable : owner.rootCommit b 1) :
      Step source registry routing profile rootOwner childOwner codec scopeOwner owner tenant vector s {s with journalVisible := 1}
  | restoreBlob (s b) (stored : b ∈ s.blobs) (authentic : owner.blobRead b) :
      Step source registry routing profile rootOwner childOwner codec scopeOwner owner tenant vector s {s with readable := s.readable ++ [b]}
  | loseJournalProjection (s) :
      Step source registry routing profile rootOwner childOwner codec scopeOwner owner tenant vector s {s with journalVisible := 0, active := false}
  | loseBlobProjection (s) :
      Step source registry routing profile rootOwner childOwner codec scopeOwner owner tenant vector s {s with readable := [], active := false}
  | offline (s) : Step source registry routing profile rootOwner childOwner codec scopeOwner owner tenant vector s {s with online := false, active := false}
  | reconnect (s) : Step source registry routing profile rootOwner childOwner codec scopeOwner owner tenant vector s {s with online := true}
  | installSnapshot (s snapshot) (inactive : s.active = false) :
      Step source registry routing profile rootOwner childOwner codec scopeOwner owner tenant vector s {s with projection := some snapshot}
  | activate (s b worker) (ready : Ready s b) (projection : s.projection = some (image s b))
      (workerCurrent : worker = s.fence) (session : owner.sessionValid worker) (read : owner.currentRead (image s b)) :
      Step source registry routing profile rootOwner childOwner codec scopeOwner owner tenant vector s {s with active := true}
  | issuePermit (s b worker) (ready : Ready s b) (active : s.active = true)
      (projection : s.projection = some (image s b)) (workerCurrent : worker = s.fence) (session : owner.sessionValid worker) :
      Step source registry routing profile rootOwner childOwner codec scopeOwner owner tenant vector s
        {s with permits := s.permits ++ [⟨s.permits.length,image s b,worker⟩]}
  | dataAdvance (s next) (event : Weaver.LlmAuthoritativeScope.Step source registry routing profile rootOwner childOwner codec scopeOwner s.execution next)
      (noUse : next.uses = s.execution.uses) (noCall : next.children.calls = s.execution.children.calls)
      (noOffer : (next.roots.base.messages routing.root).sends = (s.execution.roots.base.messages routing.root).sends)
      (noSettlement : (next.roots.base.messages routing.root).charged = (s.execution.roots.base.messages routing.root).charged)
      (sameBoot : next.boot = s.execution.boot) :
      Step source registry routing profile rootOwner childOwner codec scopeOwner owner tenant vector s
        {s with execution := next, revision := s.revision+1, active := false, projection := none}
  | advance (s p next) (gate : Gate s p)
      (event : Weaver.LlmAuthoritativeScope.Step source registry routing profile rootOwner childOwner codec scopeOwner s.execution next)
      (sameBoot : next.boot = s.execution.boot) :
      Step source registry routing profile rootOwner childOwner codec scopeOwner owner tenant vector s
        {s with execution := next, revision := s.revision+1, active := false, projection := none}
  | restart (s) : Step source registry routing profile rootOwner childOwner codec scopeOwner owner tenant vector s
      {s with fence := s.fence+1, execution := restarted s.execution, revision := s.revision+1, active := false, projection := none, acknowledged := false}

inductive Run (source : Weaver.GatewayHeadCAS.Config) (registry : Weaver.LlmAuthoritativeScope.Registry) (routing : Weaver.LlmRouting.Config) (profile : Weaver.LlmAttemptLedger.Profile)
    (rootOwner : Weaver.GatewayHeadCAS.Owner) (childOwner : Weaver.LlmAttemptLedger.Owner) (codec : Weaver.LlmSemanticContract.Owner) (scopeOwner : Weaver.LlmAuthoritativeScope.Owner)
    (owner : Owner) (tenant vector : Nat) : State → State → Prop where
  | refl (s) : Run source registry routing profile rootOwner childOwner codec scopeOwner owner tenant vector s s
  | next : Run source registry routing profile rootOwner childOwner codec scopeOwner owner tenant vector a b →
      Step source registry routing profile rootOwner childOwner codec scopeOwner owner tenant vector b d →
      Run source registry routing profile rootOwner childOwner codec scopeOwner owner tenant vector a d

theorem safe_step (safe : Safe registry routing.root tenant vector s)
    (event : Step source registry routing profile rootOwner childOwner codec scopeOwner owner tenant vector s t) :
    Safe registry routing.root tenant vector t := by
  rcases safe with ⟨intentBound,journalBound,count,certified,active⟩
  cases event with
  | reserveIntent b h worker fresh origin valid stored workerCurrent session online sourceOnline sourceRecovered authentic publish =>
    refine ⟨?_,?_,count,?_,?_⟩
    · intro other eq; have same := Option.some.inj eq; simpa [← same] using valid
    · intro row member; have prior := journalBound row member; simp_all
    · intro cert; rcases certified cert with ⟨row,prior,rows⟩; simp_all
    · intro live; rcases active live with ⟨row,ready,projection⟩; simp [Ready,fresh] at ready
  | commitRoot b worker intent fresh workerCurrent session online durable =>
    refine ⟨intentBound,?_,by simp,?_,?_⟩
    · intro row member
      have same : row = b := by simpa using member
      simpa [same] using intent
    · intro cert; rcases certified cert with ⟨row,prior,rows⟩; simp_all
    · intro live; rcases active live with ⟨row,ready,projection⟩; simp [Ready,fresh] at ready
  | certify b worker intent journal visible workerCurrent session online durable =>
    refine ⟨intentBound,journalBound,count,by intro _; exact ⟨b,intent,journal⟩,?_⟩
    intro live; rcases active live with ⟨row,ready,projection⟩
    exact ⟨row,⟨ready.1,ready.2.1,rfl,ready.2.2.2⟩,projection⟩
  | storeBlob b durable compatible =>
    refine ⟨intentBound,journalBound,count,certified,?_⟩
    intro live; rcases active live with ⟨row,ready,projection⟩
    exact ⟨row,⟨ready.1,ready.2.1,ready.2.2.1,ready.2.2.2.1,List.mem_append.mpr (Or.inl ready.2.2.2.2.1),ready.2.2.2.2.2⟩,projection⟩
  | restoreBlob b stored authentic =>
    refine ⟨intentBound,journalBound,count,certified,?_⟩
    intro live; rcases active live with ⟨row,ready,projection⟩
    exact ⟨row,⟨ready.1,ready.2.1,ready.2.2.1,ready.2.2.2.1,List.mem_append.mpr (Or.inl ready.2.2.2.2.1),ready.2.2.2.2.2⟩,projection⟩
  | restoreJournal b intent journal durable =>
    refine ⟨intentBound,journalBound,count,certified,?_⟩
    intro live; rcases active live with ⟨row,ready,projection⟩
    have len : s.journal.length = 1 := by simp [journal]
    exact ⟨row,⟨ready.1,ready.2.1,ready.2.2.1,len.symm,ready.2.2.2.2⟩,projection⟩
  | activate b worker ready projection workerCurrent session read =>
    exact ⟨intentBound,journalBound,count,certified,by intro _; exact ⟨b,ready,projection⟩⟩
  | loseJournalProjection | loseBlobProjection | offline | dataAdvance | advance | restart =>
    exact ⟨intentBound,journalBound,count,certified,by intro bad; simp at bad⟩
  | reconnect =>
    refine ⟨intentBound,journalBound,count,certified,?_⟩
    intro live; rcases active live with ⟨row,ready,projection⟩
    exact ⟨row,⟨ready.1,ready.2.1,ready.2.2.1,ready.2.2.2.1,ready.2.2.2.2.1,rfl,ready.2.2.2.2.2.2⟩,projection⟩
  | installSnapshot snapshot inactive => exact ⟨intentBound,journalBound,count,certified,by intro bad; simp_all⟩
  | _ => exact ⟨intentBound,journalBound,count,certified,active⟩

theorem initialized_safe (run : Run source registry routing profile rootOwner childOwner codec scopeOwner owner tenant vector initial s) :
    Safe registry routing.root tenant vector s := by
  induction run with
  | refl => simp [Safe,initial]
  | next prior event ih => exact safe_step ih event

theorem execution_projection (run : Run source registry routing profile rootOwner childOwner codec scopeOwner owner tenant vector initial s) :
    Weaver.LlmAuthoritativeScope.Run source registry routing profile rootOwner childOwner codec scopeOwner Weaver.LlmAuthoritativeScope.initial s.execution := by
  induction run with
  | refl => exact .refl _
  | next prior event ih =>
    cases event with
    | dataAdvance next sourceEvent noUse noCall noOffer noSettlement sameBoot => exact .next ih sourceEvent
    | advance p next gate sourceEvent sameBoot => exact .next ih sourceEvent
    | restart => exact .next ih (.restart _)
    | _ => exact ih

theorem intent_is_never_replaced (event : Step source registry routing profile rootOwner childOwner codec scopeOwner owner tenant vector s t)
    (bound : s.intent = some b) : t.intent = some b := by
  cases event with
  | reserveIntent other h worker fresh origin valid stored workerCurrent session online => simp_all
  | _ => exact bound

theorem certified_requires_exact_journal (run : Run source registry routing profile rootOwner childOwner codec scopeOwner owner tenant vector initial s)
    (certified : s.certified = true) : ∃ b, s.intent = some b ∧ s.journal = [b] :=
  (initialized_safe run).2.2.2.1 certified

theorem one_original_publication (run : Run source registry routing profile rootOwner childOwner codec scopeOwner owner tenant vector initial s) :
    s.journal.length ≤ 1 := (initialized_safe run).2.2.1

theorem active_requires_current_join (run : Run source registry routing profile rootOwner childOwner codec scopeOwner owner tenant vector initial s)
    (active : s.active = true) : ∃ b, Ready s b ∧ s.projection = some (image s b) :=
  (initialized_safe run).2.2.2.2 active

theorem stale_worker_cannot_use (gate : Gate s p) (old : p.worker ≠ s.fence) : False := old gate.2.2.2.2.2

theorem stale_execution_snapshot_cannot_use (gate : Gate s p) (old : p.image.executionRevision ≠ s.revision) : False := by
  have exact := congrArg Image.executionRevision gate.2.2.2.2.1
  exact old exact

theorem lost_reply_preserves_binding (s : State) :
    ({s with acknowledged := false} : State).intent = s.intent ∧
    ({s with acknowledged := false} : State).journal = s.journal := ⟨rfl,rfl⟩

theorem snapshot_install_never_restores_execution (s : State) (snapshot) :
    ({s with projection := some snapshot} : State).execution = s.execution := rfl

theorem original_claim_remains_unique (run : Run source registry routing profile rootOwner childOwner codec scopeOwner owner tenant vector initial s) :
    (s.execution.roots.base.messages routing.root).claims ≤ 1 ∧
    (s.execution.roots.base.messages routing.root).sends ≤ 1 := Weaver.LlmAuthoritativeScope.original_claim_stays_unique (execution_projection run)

theorem original_allowance_is_preserved (run : Run source registry routing profile rootOwner childOwner codec scopeOwner owner tenant vector initial s) :
    Weaver.LlmAttemptLedger.total s.execution.children.attempts ≤ source.cost routing.root := Weaver.LlmAuthoritativeScope.allocations_fit_source_allowance (execution_projection run)

theorem original_scope_domains_survive_recovery (run : Run source registry routing profile rootOwner childOwner codec scopeOwner owner tenant vector initial s)
    (member : u ∈ s.execution.uses) :
    u.ticket.scope.semantics.budgetDomain = source.budget (source.root routing.root) ∧
    u.ticket.scope.semantics.historyDomain = source.history (source.root routing.root) :=
  Weaver.LlmAuthoritativeScope.all_uses_keep_original_domains (execution_projection run) member

theorem unknown_usage_blocks_settlement (run : Run source registry routing profile rootOwner childOwner codec scopeOwner owner tenant vector initial s)
    (registered : a ∈ s.execution.children.attempts) (unknown : s.execution.children.usage a.id = none)
    (event : Step source registry routing profile rootOwner childOwner codec scopeOwner owner tenant vector s t) :
    (t.execution.roots.base.messages routing.root).charged = (s.execution.roots.base.messages routing.root).charged := by
  cases event with
  | dataAdvance next sourceEvent noUse noCall noOffer noSettlement sameBoot => exact noSettlement
  | advance p next gate sourceEvent sameBoot => exact Weaver.LlmAuthoritativeScope.unknown_usage_blocks_root_settlement (execution_projection run) registered unknown sourceEvent
  | _ => rfl

def resolvePublished (b : Binding) (key : Nat) : Option Weaver.LlmAuthoritativeScope.Contract :=
  if key = b.record.key then some b.blob.profile else none

theorem publication_resolves_original_contract
    (run : Run source registry routing profile rootOwner childOwner codec scopeOwner owner tenant vector initial s)
    (bound : s.intent = some b) :
    resolvePublished b routing.root = registry.resolve (registry.commitment routing.root) := by
  rcases (initialized_safe run).1 b bound with ⟨ns,bns,sourceVector,key,commitment,blobKey,profile⟩
  rw [blobKey,commitment] at profile
  simpa [resolvePublished,key] using profile.symm

theorem journal_cannot_be_replaced (event : Step source registry routing profile rootOwner childOwner codec scopeOwner owner tenant vector s t)
    (bound : s.journal = [b]) : t.journal = [b] := by
  cases event with
  | commitRoot other worker intent fresh workerCurrent session online durable => simp_all
  | _ => exact bound

theorem fence_never_decreases (event : Step source registry routing profile rootOwner childOwner codec scopeOwner owner tenant vector s t) :
    s.fence ≤ t.fence := by cases event <;> simp <;> omega

theorem journal_requires_prior_intent
    (run : Run source registry routing profile rootOwner childOwner codec scopeOwner owner tenant vector initial s)
    (member : b ∈ s.journal) : s.intent = some b := (initialized_safe run).2.1 b member

theorem missing_exact_blob_blocks_use (gate : Gate s p) (missing : p.image.binding.blob ∉ s.readable) : False :=
  missing gate.2.2.1.2.2.2.2.1

theorem original_response_mode_survives_recovery
    (run : Run source registry routing profile rootOwner childOwner codec scopeOwner owner tenant vector initial s)
    (member : u ∈ s.execution.uses) :
    u.ticket.scope.semantics.validatedDocument = (Weaver.LlmAuthoritativeScope.contract source registry routing.root).document :=
  Weaver.LlmAuthoritativeScope.all_uses_keep_response_mode (execution_projection run) member

#print axioms publication_resolves_original_contract
#print axioms journal_cannot_be_replaced
#print axioms fence_never_decreases
#print axioms journal_requires_prior_intent
#print axioms missing_exact_blob_blocks_use
#print axioms original_response_mode_survives_recovery
#print axioms initialized_safe
#print axioms execution_projection
#print axioms intent_is_never_replaced
#print axioms certified_requires_exact_journal
#print axioms one_original_publication
#print axioms active_requires_current_join
#print axioms stale_worker_cannot_use
#print axioms stale_execution_snapshot_cannot_use
#print axioms lost_reply_preserves_binding
#print axioms snapshot_install_never_restores_execution
#print axioms original_claim_remains_unique
#print axioms original_allowance_is_preserved
#print axioms original_scope_domains_survive_recovery
#print axioms unknown_usage_blocks_settlement
end Weaver.LlmRegistryPublication
