// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

module CommittedSemanticProfile {
  import LlmRouting as R from "./LlmRouting"
  import RoutineRoutingConfig as C from "./RoutineRoutingConfig"
  import SemanticGatewaySlice as S from "./SemanticGatewaySlice"
  type Node={id:int,required:Set[int],context:int,region:int}
  type Profile={id:int,response:int,nodes:Set[Node]}
  type Binding={profile:int,node:int,payload:int,history:int,budget:int}
  type Registry={profiles:Set[Profile],bound:bool,binding:Binding,epoch:int,recovered:bool,observed:bool,readEpoch:int}
  var p:Registry
  pure val node:Node={id:7,required:Set(1),context:8,region:0}
  pure val profile:Profile={id:11,response:1,nodes:Set(node)}
  pure val other:Profile=profile.with("id",12)
  pure val binding:Binding={profile:11,node:7,payload:10,history:3,budget:4}
  pure val initial:Registry={profiles:Set(),bound:false,binding:binding,epoch:0,recovered:true,observed:false,readEpoch:-1}
  // The finite commitment oracle stands for authenticated content/identity admission.
  pure def admitted(x:Profile):bool=x==profile or x==other
  pure def uniqueNodes(x:Profile):bool=x.nodes.forall(n=>x.nodes.filter(m=>m.id==n.id).size()==1)
  def known(x:Profile):bool=p.profiles.contains(x)
  val safety:bool=S::safety and p.profiles.forall(admitted) and
    p.profiles.forall(x=>p.profiles.filter(y=>y.id==x.id).size()==1 and uniqueNodes(x)) and
    (p.bound implies p.binding==binding and known(profile))
  action idle:bool=all {R::r'=R::r,C::cfg'=C::cfg,S::e'=S::e}
  action boot:bool=all {S::boot,p'=initial}
  action publish(x:Profile):bool=all {p.recovered,admitted(x),uniqueNodes(x),p.profiles.forall(y=>y.id!=x.id),idle,p'=p.with("profiles",p.profiles.union(Set(x)))}
  // No caller-supplied binding: construct from original admission assignment.
  action bindOriginal:bool=all {p.recovered,not(p.bound),known(profile),profile.nodes.exists(n=>n.id==binding.node),idle,p'=p.with("bound",true).with("binding",binding)}
  action configure:bool=all {p.bound,known(profile),C::configure(0,C::normal,true,true,true),S::e'=S::e,p'=p}
  action pin:bool=all {C::pin,S::e'=S::e,p'=p}
  action plan:bool=all {C::planRoute(0,100),S::e'=S::e,p'=p}
  action observe:bool=all {p.recovered,p.bound,known(profile),idle,p'=p.with("observed",true).with("readEpoch",p.epoch)}
  action enqueue:bool=all {p.recovered,p.bound,p.observed,p.readEpoch==p.epoch,p.binding==binding,known(profile),S::enqueue(S::currentTicket),p'=p}
  action execute:bool=all {p.recovered,p.bound,p.observed,p.readEpoch==p.epoch,p.binding==binding,known(profile),S::execute(S::e.ticket,true,true),p'=p}
  action restart:bool=all {S::restart,p'=p.with("epoch",p.epoch+1).with("recovered",false)}
  action recover:bool=all {not(p.recovered),S::recover,p'=p.with("recovered",true)}
  action rejoin:bool=all {p.recovered,p.observed,p.readEpoch==p.epoch,p.binding==binding,known(profile),S::rejoin,p'=p}
  action timeout:bool=all {S::timeout,p'=p}
  action ready:bool=boot.then(publish(profile)).then(bindOriginal).then(configure).then(pin).then(plan).then(observe)
  action queued:bool=ready.then(enqueue)
  action sent:bool=queued.then(execute)
  action step:bool=any {publish(profile),publish(other),bindOriginal,configure,pin,plan,observe,enqueue,execute,restart,recover,rejoin,timeout}
  run completeProfileReachesActualDispatchTest=sent.expect(safety and S::e.calls==1 and R::r.dispatches.size()==1)
  run missingPublicationCannotBindTest=boot.then(bindOriginal.fail())
  run forgedCommitmentContentRejectedTest=boot.then(publish(profile.with("response",2)).fail())
  run droppedCapabilityRejectedTest=boot.then(publish(profile.with("nodes",Set(node.with("required",Set())))).fail())
  run changedContextRejectedTest=boot.then(publish(profile.with("nodes",Set(node.with("context",1)))).fail())
  run changedRegionRejectedTest=boot.then(publish(profile.with("nodes",Set(node.with("region",1)))).fail())
  run changedNodeRejectedTest=boot.then(publish(profile.with("nodes",Set(node.with("id",8)))).fail())
  run duplicateNodeIdentityRejectedTest=boot.then(publish(profile.with("nodes",Set(node,node.with("context",16)))).fail())
  run otherPublishedProfileDoesNotAuthorizeOriginalTest=boot.then(publish(other)).then(bindOriginal.fail())
  run duplicatePublicationDoesNotOverwriteTest=ready.then(publish(profile).fail())
  run duplicateBindingDoesNotRecreateClaimTest=ready.then(bindOriginal.fail())
  run lostPublicationReplyRecoversSameRecordTest=boot.then(publish(profile)).then(timeout).then(bindOriginal).expect(safety and p.binding==binding)
  run lostBindingReplyRetainsOriginalTest=ready.then(timeout).expect(safety and p.bound and S::e.held and S::e.calls==0)
  run unrelatedPublicationDoesNotRepinOriginalTest=queued.then(publish(other)).then(execute).expect(safety and p.binding.profile==11 and S::e.calls==1)
  run restartPreservesProfileAndBindingTest=queued.then(restart).expect(safety and known(profile) and p.bound)
  run oldReadCannotEnqueueAfterRestartTest=ready.then(restart).then(recover).then(enqueue.fail())
  run oldReadCannotConsumeAfterRestartTest=queued.then(restart).then(recover).then(execute.fail())
  run recoveredReadAndRejoinProgressTest=queued.then(restart).then(recover).then(observe).then(rejoin).then(execute).expect(safety and S::e.calls==1)
  run postConsumptionRestartCannotRetryTest=sent.then(restart).then(recover).then(observe).then(execute.fail())
  run unknownSendRetainsBudgetTest=sent.then(timeout).expect(safety and S::e.held and not(S::e.usageKnown))
  action unsafeReplaceProfile:bool=all {idle,p'=p.with("profiles",Set(profile.with("response",2)))}
  action unsafeReplaceBinding:bool=all {idle,p'=p.with("binding",binding.with("node",8))}
  action unsafeDropProfile:bool=all {idle,p'=p.with("profiles",Set())}
  action unsafeForgetConsumption:bool=all {R::r'=R::r,C::cfg'=C::cfg,S::e'=S::e.with("consumed",false).with("calls",0),p'=p}
  run replacementProfileCounterexampleTest=queued.then(unsafeReplaceProfile).expect(not(safety))
  run replacementBindingCounterexampleTest=queued.then(unsafeReplaceBinding).expect(not(safety))
  run rollbackPublicationCounterexampleTest=queued.then(unsafeDropProfile).expect(not(safety))
  run forgottenConsumptionCounterexampleTest=sent.then(restart).then(unsafeForgetConsumption).expect(not(safety))
}
