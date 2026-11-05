-- SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
--
-- SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

import LlmAttemptLedger
namespace Weaver.LlmSemanticContract

-- Equality here concerns a declared protocol projection, not LLM behavior.
structure Payload where
  input : Nat
  orderedRoles : List Nat
  tools : List Nat
  schema : Nat
  toolChoice : Nat
  parallel : Bool
  candidates : Nat
  deriving DecidableEq
structure Semantics extends Payload where
  validatedDocument : Bool
  historyDomain : Nat
  budgetDomain : Nat
  deriving DecidableEq
structure Scope where
  root : Nat
  attempt : Nat
  target : Nat
  manifest : Nat
  semantics : Semantics
  maxArguments : Nat
  maxCalls : Nat
structure Wire where
  root : Nat
  attempt : Nat
  target : Nat
  manifest : Nat
  body : List Nat
  historyDomain : Nat
  budgetDomain : Nat
  validatedDocument : Bool
  deriving DecidableEq
structure Output where
  root : Nat
  attempt : Nat
  ordinal : Nat
  kind : Nat
  complete : Bool
  deriving DecidableEq
structure Fragment where
  root : Nat
  attempt : Nat
  call : Nat
  sequence : Nat
  bytes : List Nat
structure Proposal where
  root : Nat
  attempt : Nat
  call : Nat
  tool : Nat
  arguments : List Nat
  deriving DecidableEq
structure Owner where
  decode : List Nat → Option Payload
  digest : List Nat → Nat
  nameMapValid : Wire → Prop
  sendValid : Wire → Nat → Nat → Prop
  winnerCurrent : Nat → Nat → Prop
  releaseValid : Output → Nat → Nat → Prop
  outputValid : Semantics → Output → Prop
  fragmentValid : Fragment → Prop
  finishValid : Proposal → Prop
  argumentsValid : Semantics → Proposal → Prop

def WireValid (c : Scope) (o : Owner) (w : Wire) : Prop :=
  w.root = c.root ∧ w.attempt = c.attempt ∧ w.target = c.target ∧ w.manifest = c.manifest ∧
  o.digest w.body = w.manifest ∧ o.decode w.body = some c.semantics.toPayload ∧ o.nameMapValid w ∧ c.semantics.candidates = 1 ∧
  w.historyDomain = c.semantics.historyDomain ∧ w.budgetDomain = c.semantics.budgetDomain ∧
  w.validatedDocument = c.semantics.validatedDocument

def OutputBound (c : Scope) (e : Output) : Prop := e.root = c.root ∧ e.attempt = c.attempt

def ProposalBound (c : Scope) (o : Owner) (p : Proposal) : Prop :=
  p.root = c.root ∧ p.attempt = c.attempt ∧ p.tool ∈ c.semantics.tools ∧
  p.arguments.length ≤ c.maxArguments ∧ o.finishValid p ∧ o.argumentsValid c.semantics p

structure State where
  epoch : Nat := 0
  view : Nat := 0
  sealed : Option Wire := none
  consumed : Bool := false
  retired : Bool := false
  outputs : List Output := []
  buffers : Nat → List Nat := fun _ => []
  parts : Nat → Nat := fun _ => 0
  calls : List Nat := []
  proposals : List Proposal := []
  ended : Bool := false
  toolEffects : Nat := 0

def initial : State := {}
def Audit (c : Scope) (o : Owner) (s : State) : Prop :=
  (∀ w, s.sealed = some w → WireValid c o w) ∧
  (∀ e ∈ s.outputs, OutputBound c e ∧ o.outputValid c.semantics e) ∧
  (∀ p ∈ s.proposals, ProposalBound c o p) ∧
  (∀ i, (s.buffers i).length ≤ c.maxArguments) ∧ s.toolEffects = 0

inductive Step (c : Scope) (o : Owner) : State → State → Prop where
  | freezeWire (s w) (fresh : s.sealed = none) (valid : WireValid c o w) (unused : s.consumed = false) :
      Step c o s {s with sealed := some w}
  | admit (s w worker) (sealed : s.sealed = some w) (unused : s.consumed = false)
      (current : worker = s.epoch) (live : s.retired = false) (valid : WireValid c o w) (policy : o.sendValid w s.epoch s.view) :
      Step c o s {s with consumed := true}
  | release (s e worker) (used : s.consumed = true) (current : worker = s.epoch)
      (winner : o.winnerCurrent c.root c.attempt) (bound : OutputBound c e)
      (next : e.ordinal = s.outputs.length) (kind : e.kind ≤ 2)
      (schema : e.kind = 2 → e.complete = true)
      (mode : c.semantics.validatedDocument = true → e.kind = 2) (valid : o.outputValid c.semantics e)
      (policy : o.releaseValid e s.epoch s.view) (openStream : s.ended = false) :
      Step c o s {s with outputs := s.outputs ++ [e]}
  | appendArguments (s f) (used : s.consumed = true) (openStream : s.ended = false)
      (root : f.root = c.root) (attempt : f.attempt = c.attempt) (source : o.fragmentValid f)
      (ordered : f.sequence = s.parts f.call) (notFinished : ∀ p ∈ s.proposals, p.call ≠ f.call)
      (capacity : f.call ∈ s.calls ∨ s.calls.length < c.maxCalls)
      (bounded : (s.buffers f.call ++ f.bytes).length ≤ c.maxArguments) :
      Step c o s {s with
        buffers := fun i => if i = f.call then s.buffers f.call ++ f.bytes else s.buffers i,
        parts := fun i => if i = f.call then s.parts f.call+1 else s.parts i,
        calls := if f.call ∈ s.calls then s.calls else s.calls ++ [f.call]}
  | propose (s p) (used : s.consumed = true) (registered : p.call ∈ s.calls)
      (exact : p.arguments = s.buffers p.call) (fresh : ∀ old ∈ s.proposals, old.call ≠ p.call)
      (valid : ProposalBound c o p) : Step c o s {s with proposals := s.proposals ++ [p]}
  | endStream (s) : Step c o s {s with ended := true}
  | updatePolicyOrHistory (s) : Step c o s {s with view := s.view+1}
  | restart (s) : Step c o s {s with epoch := s.epoch+1, retired := true}
  | lostReplyOrTimeout (s) : Step c o s s

inductive Run (c : Scope) (o : Owner) : State → State → Prop where
  | refl (s) : Run c o s s
  | next : Run c o a b → Step c o b d → Run c o a d

theorem audit_step (h : Audit c o s) (e : Step c o s t) : Audit c o t := by
  rcases h with ⟨wire,outputs,proposals,buffers,effects⟩
  cases e with
  | freezeWire w fresh valid unused =>
    refine ⟨?_,outputs,proposals,buffers,effects⟩
    intro other eq; have same := Option.some.inj eq; simpa [← same] using valid
  | release event worker used current winner bound next kind schema mode valid policy openStream =>
    refine ⟨wire,?_,proposals,buffers,effects⟩
    intro e he; rcases List.mem_append.mp he with old | new
    · exact outputs e old
    · have same : e = event := by simpa using new
      subst e; exact ⟨bound,valid⟩
  | appendArguments f used openStream root attempt source ordered notFinished capacity bounded =>
    refine ⟨wire,outputs,proposals,?_,effects⟩
    intro i; dsimp; split <;> simp_all
  | propose proposal used registered exact fresh valid =>
    refine ⟨wire,outputs,?_,buffers,effects⟩
    intro p hp; rcases List.mem_append.mp hp with old | new
    · exact proposals p old
    · have same : p = proposal := by simpa using new
      subst p; exact valid
  | _ => exact ⟨wire,outputs,proposals,buffers,effects⟩

theorem initialized_audit (run : Run c o initial s) : Audit c o s := by
  induction run with
  | refl => simp [Audit,initial]
  | next prior event ih => exact audit_step ih event

theorem sealed_wire_preserves_projection (run : Run c o initial s) (sealed : s.sealed = some w) :
    o.decode w.body = some c.semantics.toPayload := ((initialized_audit run).1 w sealed).2.2.2.2.2.1

theorem sealed_internal_context_is_bound (run : Run c o initial s) (sealed : s.sealed = some w) :
    w.historyDomain = c.semantics.historyDomain ∧ w.budgetDomain = c.semantics.budgetDomain ∧
      w.validatedDocument = c.semantics.validatedDocument := by
  rcases (initialized_audit run).1 w sealed with ⟨root,attempt,target,manifest,digest,decoded,names,candidates,history,budget,mode⟩
  exact ⟨history,budget,mode⟩

theorem sealed_wire_cannot_be_replaced (event : Step c o s t) (sealed : s.sealed = some w) : t.sealed = some w := by
  cases event with
  | freezeWire other fresh valid unused => simp_all
  | _ => exact sealed

theorem consumed_child_cannot_reopen (event : Step c o s t) (consumed : s.consumed = true) : t.consumed = true := by
  cases event <;> simp_all

theorem semantic_outputs_keep_original_source (run : Run c o initial s) (member : e ∈ s.outputs) : OutputBound c e :=
  ((initialized_audit run).2.1 e member).1

theorem tool_proposal_requires_finished_valid_arguments (run : Run c o initial s) (member : p ∈ s.proposals) :
    o.finishValid p ∧ o.argumentsValid c.semantics p := ((initialized_audit run).2.2.1 p member).2.2.2.2

theorem tool_fragments_do_not_execute (run : Run c o initial s) : s.toolEffects = 0 :=
  (initialized_audit run).2.2.2.2

theorem argument_buffers_are_bounded (run : Run c o initial s) (call) : (s.buffers call).length ≤ c.maxArguments :=
  (initialized_audit run).2.2.2.1 call

theorem release_requires_current_winner_and_policy (event : Step c o s t) (changed : t.outputs ≠ s.outputs) :
    ∃ e worker, worker = s.epoch ∧ o.winnerCurrent c.root c.attempt ∧ OutputBound c e ∧
      o.releaseValid e s.epoch s.view ∧ s.ended = false := by
  cases event with
  | release e worker used current winner bound next kind schema mode valid policy openStream => exact ⟨e,_,current,winner,bound,policy,openStream⟩
  | _ => exact False.elim (changed rfl)

theorem complete_document_release_is_not_partial (event : Step c o s t)
    (new : e ∈ t.outputs) (fresh : e ∉ s.outputs) (structured : e.kind = 2) : e.complete = true := by
  cases event with
  | release event worker used current winner bound next kind schema mode valid policy openStream =>
    have same : e = event := by simpa [fresh] using new
    subst e; exact schema structured
  | _ => exact False.elim (fresh new)

theorem document_profile_cannot_downgrade (event : Step c o s t)
    (new : e ∈ t.outputs) (fresh : e ∉ s.outputs) (document : c.semantics.validatedDocument = true) :
    e.kind = 2 ∧ e.complete = true := by
  cases event with
  | release output worker used current winner bound next kind schema mode valid policy openStream =>
    have same : e = output := by simpa [fresh] using new
    subst e; exact ⟨mode document,schema (mode document)⟩
  | _ => exact False.elim (fresh new)

theorem finite_call_count (run : Run c o initial s) : s.calls.length ≤ c.maxCalls := by
  induction run with
  | refl => simp [initial]
  | next prior event ih =>
    cases event with
    | appendArguments f used openStream root attempt source ordered notFinished capacity bounded =>
      dsimp; split
      · exact ih
      · simp_all; omega
    | _ => exact ih

theorem restart_cannot_reinvoke_old_attempt (event : Step c o s t) (retired : s.retired = true) :
    t.consumed = s.consumed := by
  cases event with
  | admit w worker sealed unused current live valid policy => simp_all
  | _ => rfl

-- This witness carries an actual existing child invocation, not a new send API.
structure ChildCall (c : Weaver.LlmRouting.Config) (profile : Weaver.LlmAttemptLedger.Profile)
    (owner : Weaver.LlmAttemptLedger.Owner) where
  before : Weaver.LlmAttemptLedger.State
  record : Weaver.LlmAttemptLedger.Attempt
  worker : Nat
  prior : Weaver.LlmAttemptLedger.Run c profile owner Weaver.LlmAttemptLedger.initial before
  registered : record ∈ before.attempts
  epoch : record.epoch = before.epoch
  workerCurrent : worker = before.epoch
  live : before.retired record.id = false
  fresh : before.calls record.id = 0
  openRoot : before.closed = false
  winner : before.winner = none ∨ before.winner = some record.id
  current : record.plan.view = Weaver.LlmRouting.view before.routes
  eligible : Weaver.LlmRouting.Eligible c before.routes record.plan.target
  wire : owner.router.wireValid record.plan
  policy : owner.childValid record (Weaver.LlmRouting.view before.routes)

def ChildCall.after (call : ChildCall c profile owner) : Weaver.LlmAttemptLedger.State :=
  {call.before with calls := fun i => if i = call.record.id then 1 else call.before.calls i}

theorem refines_actual_child_invocation (call : ChildCall c profile owner) :
    Weaver.LlmAttemptLedger.Step c profile owner call.before call.after :=
  .invoke call.before call.record call.worker call.registered call.epoch call.workerCurrent call.live call.fresh
    call.openRoot call.winner call.current call.eligible call.wire call.policy

structure EncodingBridge (scope : Scope) (codec : Owner) (call : ChildCall c profile owner) (wire : Wire) where
  valid : WireValid scope codec wire
  root : wire.root = call.record.plan.root
  attempt : wire.attempt = call.record.id
  target : wire.target = call.record.plan.target
  manifest : wire.manifest = call.record.plan.manifest
  payload : scope.semantics.input = call.record.plan.payload

theorem qualified_child_retains_budget (call : ChildCall c profile owner) (_bridge : EncodingBridge scope codec call wire) :
    Weaver.LlmAttemptLedger.Safe c call.after :=
  Weaver.LlmAttemptLedger.initialized_safe (.next call.prior (refines_actual_child_invocation call))

theorem qualified_child_uses_actual_target (bridge : EncodingBridge scope codec call wire) :
    wire.target = call.record.plan.target ∧ codec.decode wire.body = some scope.semantics.toPayload :=
  ⟨bridge.target,bridge.valid.2.2.2.2.2.1⟩

#print axioms sealed_internal_context_is_bound
#print axioms document_profile_cannot_downgrade
#print axioms finite_call_count
#print axioms restart_cannot_reinvoke_old_attempt
#print axioms initialized_audit
#print axioms sealed_wire_preserves_projection
#print axioms sealed_wire_cannot_be_replaced
#print axioms consumed_child_cannot_reopen
#print axioms semantic_outputs_keep_original_source
#print axioms tool_proposal_requires_finished_valid_arguments
#print axioms tool_fragments_do_not_execute
#print axioms argument_buffers_are_bounded
#print axioms release_requires_current_winner_and_policy
#print axioms complete_document_release_is_not_partial
#print axioms refines_actual_child_invocation
#print axioms qualified_child_retains_budget
#print axioms qualified_child_uses_actual_target
end Weaver.LlmSemanticContract
