// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

// Protocol projection preservation is not equivalence of generated LLM answers.
module LlmSemanticContract {
  type Semantic = {input:int,roles:List[int],tools:Set[int],schema:int,choice:int,parallel:bool,candidates:int}
  type Contract = {payload:Semantic,history:int,budget:int,document:bool}
  type Wire = {root:int,attempt:int,target:int,manifest:int,body:int,projection:Semantic,history:int,budget:int,document:bool,names:bool}
  type Output = {root:int,attempt:int,ordinal:int,kind:int,complete:bool,valid:bool}
  type Proposal = {root:int,attempt:int,call:int,tool:int,args:List[int],finished:bool,schema:bool}
  type Protocol = {contract:Contract,epoch:int,view:int,sealed:bool,wire:Wire,consumed:bool,retired:bool,
    outputs:List[Output],buffers:int->List[int],parts:int->int,calls:Set[int],proposals:Set[Proposal],ended:bool,toolEffects:int}
  var s:Protocol
  pure val semantic = {input:10,roles:List(1,2,3),tools:Set(7,8),schema:4,choice:7,parallel:false,candidates:1}
  pure val contract={payload:semantic,history:9,budget:5,document:false}
  pure val ids=0.to(2)
  pure val wire={root:0,attempt:1,target:6,manifest:106,body:106,projection:semantic,history:9,budget:5,document:false,names:true}
  pure val initial={contract:contract,epoch:0,view:0,sealed:false,wire:wire,consumed:false,retired:false,
    outputs:List(),buffers:ids.mapBy(i=>List()),parts:ids.mapBy(i=>0),calls:Set(),proposals:Set(),ended:false,toolEffects:0}
  def validWire(w)=w.root==0 and w.attempt==1 and w.target==6 and w.manifest==106 and w.body==106 and w.projection==s.contract.payload and w.history==s.contract.history and w.budget==s.contract.budget and w.document==s.contract.document and w.names
  def validOutput(e)=e.root==0 and e.attempt==1 and e.kind>=0 and e.kind<=2 and e.valid and (e.kind!=2 or e.complete) and (not(s.contract.document) or e.kind==2)
  def validProposal(p)=p.root==0 and p.attempt==1 and s.contract.payload.tools.contains(p.tool) and p.args.length()<=4 and p.finished and p.schema
  action init=s'=initial
  action initDocument=s'=initial.with("contract",contract.with("document",true))
  action freezeWire(w)=all {not(s.sealed),not(s.consumed),validWire(w),s'=s.with("sealed",true).with("wire",w)}
  action admit(worker,view,policy)=all {s.sealed,not(s.consumed),not(s.retired),worker==s.epoch,view==s.view,policy,validWire(s.wire),s'=s.with("consumed",true)}
  action release(e,worker,view,winner,policy)=all {s.consumed,worker==s.epoch,view==s.view,winner,policy,not(s.ended),
    validOutput(e),e.ordinal==s.outputs.length(),s'=s.with("outputs",s.outputs.append(e))}
  action appendArguments(root,attempt,call,seq,bytes,source)=all {s.consumed,not(s.ended),root==0,attempt==1,source,ids.contains(call),
    seq==s.parts.get(call),not(s.proposals.exists(p=>p.call==call)),s.calls.contains(call) or s.calls.size()<2,
    s.buffers.get(call).concat(bytes).length()<=4,
    s'=s.with("buffers",s.buffers.set(call,s.buffers.get(call).concat(bytes))).with("parts",s.parts.set(call,seq+1)).with("calls",s.calls.union(Set(call)))}
  action propose(p)=all {s.consumed,s.calls.contains(p.call),p.args==s.buffers.get(p.call),
    not(s.proposals.exists(old=>old.call==p.call)),validProposal(p),s'=s.with("proposals",s.proposals.union(Set(p)))}
  action endStream=s'=s.with("ended",true)
  action updatePolicyOrHistory=s'=s.with("view",s.view+1)
  action restart=s'=s.with("epoch",s.epoch+1).with("retired",true)
  action lostReplyOrTimeout=s'=s
  def output(kind,complete)={root:0,attempt:1,ordinal:s.outputs.length(),kind:kind,complete:complete,valid:true}
  def proposal(call,finished,schema)={root:0,attempt:1,call:call,tool:7,args:s.buffers.get(call),finished:finished,schema:schema}
  val wireBound=not(s.sealed) or validWire(s.wire)
  val outputsBound=s.outputs.indices().forall(i=>validOutput(s.outputs.nth(i))) and s.outputs.indices().forall(i=>s.outputs.nth(i).ordinal==i)
  val proposalsBound=s.proposals.forall(p=>validProposal(p)) and s.proposals.size()==s.proposals.map(p=>p.call).size()
  val buffersBound=ids.forall(i=>s.buffers.get(i).length()<=4) and s.calls.size()<=2
  val noImplicitExecution=s.toolEffects==0
  val safety=wireBound and outputsBound and proposalsBound and buffersBound and noImplicitExecution
  action step={
    nondet i=ids.oneOf()
    nondet kind=0.to(2).oneOf()
    nondet b=Set(List(1),List(2,3),List()).oneOf()
    any {freezeWire(wire),admit(s.epoch,s.view,true),release(output(kind,true),s.epoch,s.view,true,true),
      appendArguments(0,1,i,s.parts.get(i),b,true),propose(proposal(i,true,true)),endStream,updatePolicyOrHistory,restart,lostReplyOrTimeout}
  }
  action sealedDocument=initDocument.then(freezeWire(wire.with("document",true)))
  action admittedDocument=sealedDocument.then(admit(0,0,true))
  action sealed=init.then(freezeWire(wire))
  action admitted=sealed.then(admit(0,0,true))
  action buffered=admitted.then(appendArguments(0,1,0,0,List(1,2),true))
  action proposed=buffered.then(propose(proposal(0,true,true)))
  action released=admitted.then(release(output(0,false),0,0,true,true))
  run exactProjectionAcceptedTest=admitted.expect(safety and s.wire.projection==semantic)
  run roleOrderCannotChangeTest=init.then(freezeWire(wire.with("projection",semantic.with("roles",List(3,2,1)))).fail())
  run toolSetCannotExpandTest=init.then(freezeWire(wire.with("projection",semantic.with("tools",Set(7,8,9)))).fail())
  run toolChoiceCannotBeDroppedTest=init.then(freezeWire(wire.with("projection",semantic.with("choice",0))).fail())
  run parallelConstraintCannotWeakenTest=init.then(freezeWire(wire.with("projection",semantic.with("parallel",true))).fail())
  run candidateFanoutCannotExpandTest=init.then(freezeWire(wire.with("projection",semantic.with("candidates",2))).fail())
  run schemaCannotBeDowngradedTest=init.then(freezeWire(wire.with("projection",semantic.with("schema",0))).fail())
  run historyDomainCannotChangeTest=init.then(freezeWire(wire.with("history",99)).fail())
  run budgetDomainCannotChangeTest=init.then(freezeWire(wire.with("budget",99)).fail())
  run actualTargetCannotChangeTest=init.then(freezeWire(wire.with("target",0)).fail())
  run mutableBodyCannotReplaceSealTest=sealed.then(freezeWire(wire.with("body",999)).fail())
  run aliasCollisionCannotPassTest=init.then(freezeWire(wire.with("names",false)).fail())
  run consumedAttemptCannotReplayTest=admitted.then(lostReplyOrTimeout).then(admit(0,0,true).fail())
  run restartCannotReinvokeOldChildTest=sealed.then(restart).then(admit(1,0,true).fail())
  run responseModeCannotBeDowngradedTest=initDocument.then(freezeWire(wire).fail())
  run currentSendPolicyRequiredTest=sealed.then(admit(0,0,false).fail())
  run currentViewRequiredTest=sealed.then(updatePolicyOrHistory).then(admit(0,0,true).fail())
  run losingAttemptCannotReleaseTest=admitted.then(release(output(0,false),0,0,false,true).fail())
  run otherAttemptCannotReleaseTest=admitted.then(release(output(0,false).with("attempt",2),0,0,true,true).fail())
  run currentDisclosurePolicyRequiredTest=released.then(updatePolicyOrHistory).then(release(output(0,false),0,0,true,false).fail())
  run duplicateEventOrdinalRejectedTest=released.then(release(output(0,false).with("ordinal",0),0,0,true,true).fail())
  run completeDocumentCannotBePartialTest=admitted.then(release(output(2,false),0,0,true,true).fail())
  run documentProfileCannotDowngradeTest=admittedDocument.then(release(output(0,false),0,0,true,true).fail())
  run documentProfileCompleteTest=admittedDocument.then(release(output(2,true),0,0,true,true)).expect(safety)
  run structuredDocumentValidatedTest=admitted.then(release(output(2,true),0,0,true,true)).expect(safety)
  run partialTextRemainsDataTest=released.expect(safety and s.toolEffects==0)
  run fragmentIdentityMustMatchTest=admitted.then(appendArguments(0,2,0,0,List(1),true).fail())
  run fragmentSequenceMustMatchTest=buffered.then(appendArguments(0,1,0,0,List(3),true).fail())
  run fragmentSourceMustBeQualifiedTest=admitted.then(appendArguments(0,1,0,0,List(1),false).fail())
  run argumentBufferBoundedTest=buffered.then(appendArguments(0,1,0,1,List(1,2,3),true).fail())
  run totalCallCountBoundedTest=buffered.then(appendArguments(0,1,1,0,List(1),true)).then(appendArguments(0,1,2,0,List(1),true).fail())
  run unfinishedArgumentsCannotProposeTest=buffered.then(propose(proposal(0,false,true)).fail())
  run invalidSchemaCannotProposeTest=buffered.then(propose(proposal(0,true,false)).fail())
  run actualArgumentsCannotBeRewrittenTest=buffered.then(propose(proposal(0,true,true).with("args",List(9))).fail())
  run qualifiedProposalIsStillDataTest=proposed.expect(safety and s.toolEffects==0)
  run duplicateProposalRejectedTest=proposed.then(propose(proposal(0,true,true)).fail())
  run completedArgumentsCannotMutateTest=proposed.then(appendArguments(0,1,0,1,List(3),true).fail())
  run truncatedStreamDoesNotCompleteToolTest=buffered.then(endStream).then(propose(proposal(0,false,true)).fail())
  run lateQualifiedCompletionAfterRestartTest=buffered.then(restart).then(endStream).then(propose(proposal(0,true,true))).expect(safety and s.toolEffects==0)
  run oldWorkerCannotReleaseTest=released.then(restart).then(release(output(0,false),0,0,true,true).fail())
  run endedStreamCannotResumeOutputTest=released.then(endStream).then(release(output(0,false),0,0,true,true).fail())
  action unsafeRoleDrop=s'=s.with("wire",s.wire.with("projection",semantic.with("roles",List(3))))
  action unsafeTargetSwap=s'=s.with("wire",s.wire.with("target",0))
  action unsafeMixedWinner=s'=s.with("outputs",s.outputs.append(output(0,false).with("attempt",2)))
  action unsafePartialTool=s'=s.with("proposals",Set(proposal(0,false,true)))
  action unsafePartialSchema=s'=s.with("outputs",s.outputs.append(output(2,false)))
  action unsafeBufferOverflow=s'=s.with("buffers",s.buffers.set(0,List(1,2,3,4,5)))
  run roleDropSemanticCounterexampleTest=sealed.then(unsafeRoleDrop).expect(not(wireBound))
  run targetSwapSemanticCounterexampleTest=sealed.then(unsafeTargetSwap).expect(not(wireBound))
  run mixedWinnerSemanticCounterexampleTest=admitted.then(unsafeMixedWinner).expect(not(outputsBound))
  run partialToolSemanticCounterexampleTest=buffered.then(unsafePartialTool).expect(not(proposalsBound))
  run partialSchemaSemanticCounterexampleTest=admitted.then(unsafePartialSchema).expect(not(outputsBound))
  run bufferOverflowSemanticCounterexampleTest=buffered.then(unsafeBufferOverflow).expect(not(buffersBound))
}
