// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

// One admitted original task; native source setup and transitions are composed in Lean.
module LlmPolicyPublication {
  type Subject={claim:int,commitment:int,budget:int,history:int}
  type Change={id:int,domain:int,vector:int,subject:Subject,parentGeneration:int,parentTip:int,content:int,allowed:bool}
  type Publication={change:Change,generation:int,worker:int,acceptedFence:int}
  type Permit={id:int,subject:Subject,generation:int,fence:int,revision:int}
  type Use={permit:Permit,actualGeneration:int,actualFence:int,actualRevision:int,allowed:bool}
  type State={staged:Set[Change],stageVisible:Set[Change],log:List[Publication],visible:int,acks:Set[Publication],ackVisible:Set[Publication],
    generation:int,allowed:bool,fence:int,revision:int,online:bool,permits:Set[Permit],uses:List[Use],spent:bool,calls:int,hold:int,usage:int,charged:bool}
  var s:State
  pure val original={claim:11,commitment:20,budget:5,history:9}
  pure val deny0={id:10,domain:9,vector:30,subject:original,parentGeneration:0,parentTip:0,content:100,allowed:false}
  pure val allow0=deny0.with("allowed",true).with("content",101)
  pure val deny1=deny0.with("id",11).with("parentGeneration",1).with("parentTip",10).with("content",102)
  pure val denyRecord={change:deny0,generation:1,worker:0,acceptedFence:0}
  pure val allowRecord={change:allow0,generation:1,worker:0,acceptedFence:0}
  pure val permit0={id:0,subject:original,generation:0,fence:0,revision:0}
  pure val permit1={id:1,subject:original,generation:1,fence:0,revision:0}
  pure val initial={staged:Set(),stageVisible:Set(),log:List(),visible:0,acks:Set(),ackVisible:Set(),generation:0,allowed:true,fence:0,revision:0,
    online:true,permits:Set(permit0),uses:List(),spent:false,calls:0,hold:6,usage:-1,charged:false}
  def tip=if(s.log.length()==0)0 else s.log.nth(s.log.length()-1).change.id
  def effective=if(s.log.length()==0)true else s.log.nth(s.log.length()-1).change.allowed
  def committed(r)=s.log.indices().exists(i=>s.log.nth(i)==r)
  def permit=s.permits.fold(permit0,(a,b)=>if(b.id>a.id)b else a)
  action init=s'=initial
  action stage(c,qualified)=all {qualified,c.domain==9,c.vector==30,c.subject==original,s.staged.forall(old=>old.id!=c.id),
    s'=s.with("staged",s.staged.union(Set(c))).with("stageVisible",s.stageVisible.union(Set(c)))}
  action publish(c,worker,durable,policy)=all {s.staged.contains(c),s.stageVisible.contains(c),s.log.indices().forall(i=>s.log.nth(i).change.id!=c.id),
    c.parentGeneration==s.generation,c.parentTip==tip,worker==s.fence,s.online,durable,policy,
    s'=s.with("generation",s.generation+1).with("allowed",c.allowed).with("visible",s.log.length()+1)
      .with("log",s.log.append({change:c,generation:s.generation+1,worker:worker,acceptedFence:s.fence}))}
  action query(r,qualified)=all {committed(r),qualified,s'=s.with("visible",s.log.length())}
  action acknowledge(r,durable)=all {committed(r),s.stageVisible.contains(r.change),s.visible==s.log.length(),s.online,durable,
    s'=s.with("acks",s.acks.union(Set(r))).with("ackVisible",s.ackVisible.union(Set(r)))}
  action loseReplies=s'=s.with("visible",0).with("ackVisible",Set())
  action loseProducer=s'=s.with("stageVisible",Set()).with("ackVisible",Set())
  action restoreStage(c,qualified)=all {s.staged.contains(c),qualified,s'=s.with("stageVisible",s.stageVisible.union(Set(c)))}
  action restoreAck(r,qualified)=all {s.acks.contains(r),qualified,s'=s.with("ackVisible",s.ackVisible.union(Set(r)))}
  action restart=s'=s.with("online",false).with("fence",s.fence+1).with("revision",s.revision+1).with("visible",0).with("ackVisible",Set())
  action recover(qualified)=all {qualified,s'=s.with("online",true).with("visible",s.log.length())}
  action issue=s'=s.with("permits",s.permits.union(Set({id:s.permits.size(),subject:original,generation:s.generation,fence:s.fence,revision:s.revision})))
  action consume(p)=all {s.online,s.allowed,s.permits.contains(p),p.subject==original,p.generation==s.generation,p.fence==s.fence,p.revision==s.revision,not(s.spent),
    s'=s.with("spent",true).with("calls",s.calls+1).with("revision",s.revision+1)
      .with("uses",s.uses.append({permit:p,actualGeneration:s.log.length(),actualFence:s.fence,actualRevision:s.revision,allowed:effective}))}
  action finalUsage(amount,qualified)=all {s.spent,s.usage == -1,amount>=0,amount<=6,qualified,s'=s.with("usage",amount).with("revision",s.revision+1)}
  val aligned=s.generation==s.log.length() and s.allowed==effective
  val parents=s.log.indices().forall(i=>{val r=s.log.nth(i)
    r.generation==i+1 and r.change.parentGeneration==i and r.change.parentTip==(if(i==0)0 else s.log.nth(i-1).change.id) and r.worker==r.acceptedFence})
  val unique=s.log.indices().forall(i=>s.log.indices().forall(j=>i==j or s.log.nth(i).change.id!=s.log.nth(j).change.id))
  val provenance=s.log.indices().forall(i=>s.staged.contains(s.log.nth(i).change)) and s.acks.forall(r=>committed(r))
  val usesBound=s.uses.indices().forall(i=>{val u=s.uses.nth(i)
    u.allowed and u.permit.generation==u.actualGeneration and u.permit.fence==u.actualFence and u.permit.revision==u.actualRevision and u.permit.subject==original})
  val accounting=s.calls<=1 and (s.usage == -1 implies s.hold==6 and not(s.charged))
  val safety=aligned and parents and unique and provenance and usesBound and accounting
  action step={
    nondet id=10.to(12).oneOf()
    nondet allowed=Set(true,false).oneOf()
    nondet amount=0.to(6).oneOf()
    val c={id:id,domain:9,vector:30,subject:original,parentGeneration:s.generation,parentTip:tip,content:90+id,allowed:allowed}
    any {stage(c,true),publish(c,s.fence,true,true),query(denyRecord,true),acknowledge(denyRecord,true),loseReplies,loseProducer,
      restoreStage(deny0,true),restoreAck(denyRecord,true),restart,recover(true),issue,consume(permit),finalUsage(amount,true)}
  }
  action pending=init.then(stage(deny0,true))
  action published=pending.then(publish(deny0,0,true,true))
  action acknowledged=published.then(acknowledge(denyRecord,true))
  action newer=init.then(stage(allow0,true)).then(publish(allow0,0,true,true)).then(issue).then(stage(deny1,true)).then(publish(deny1,0,true,true))
  action restarted=pending.then(restart)
  action unknown=init.then(consume(permit0)).then(stage(deny0,true)).then(publish(deny0,0,true,true))
  run pendingIsNotEffectiveTest=pending.expect(safety and s.generation==0 and s.allowed and s.acks.size()==0)
  run pendingCannotAcknowledgeTest=pending.then(acknowledge(denyRecord,true).fail())
  run stagedChangeRequiresApprovalTest=init.then(stage(deny0,false).fail())
  run foreignDomainCannotStageTest=init.then(stage(deny0.with("domain",99),true).fail())
  run foreignSourceCannotStageTest=init.then(stage(deny0.with("vector",31),true).fail())
  run foreignClaimCannotStageTest=init.then(stage(deny0.with("subject",original.with("claim",12)),true).fail())
  run profileReplacementCannotStageTest=init.then(stage(deny0.with("subject",original.with("commitment",21)),true).fail())
  run changeIdentityCannotRebindTest=pending.then(stage(allow0,true).fail())
  run unstagedChangeCannotPublishTest=init.then(publish(deny0,0,true,true).fail())
  run publicationRequiresCurrentPolicyTest=pending.then(publish(deny0,0,true,false).fail())
  run publicationRequiresDurabilityTest=pending.then(publish(deny0,0,false,true).fail())
  run publicationImmediatelyInvalidatesPermitTest=published.then(consume(permit0).fail())
  run noAckIsNeededForDenialTest=published.expect(safety and not(s.allowed) and s.acks.size()==0)
  run lostPublishReplyDoesNotReapplyTest=published.then(loseReplies).then(publish(deny0,0,true,true).fail())
  run exactQueryRecoversLostReplyTest=published.then(loseReplies).then(query(denyRecord,true)).then(acknowledge(denyRecord,true)).expect(safety)
  run unknownQueryCannotConfirmTest=pending.then(query(denyRecord,true).fail())
  run queryRequiresSourceEvidenceTest=published.then(query(denyRecord,false).fail())
  run ackRequiresDurabilityTest=published.then(acknowledge(denyRecord,false).fail())
  run lostAckReplyCannotChangeAuthorityTest=acknowledged.then(loseReplies).then(restoreAck(denyRecord,true)).expect(safety and s.generation==1 and not(s.allowed))
  run repeatedAckIsOnlyDataTest=acknowledged.then(acknowledge(denyRecord,true)).expect(safety and s.log.length()==1)
  run lateAckCannotRestoreOldAllowTest=newer.then(acknowledge(allowRecord,true)).expect(safety and s.generation==2 and not(s.allowed))
  run lateAckCannotReviveOldPermitTest=newer.then(acknowledge(allowRecord,true)).then(consume(permit1).fail())
  run staleParentCannotPublishTest=pending.then(stage(allow0.with("id",11),true)).then(publish(deny0,0,true,true)).then(publish(allow0.with("id",11),0,true,true).fail())
  run wrongPrefixCannotPublishTest=init.then(stage(deny0.with("parentTip",99),true)).then(publish(deny0.with("parentTip",99),0,true,true).fail())
  run oldPublisherCannotResumeTest=restarted.then(recover(true)).then(publish(deny0,0,true,true).fail())
  run currentPublisherAdoptsOriginalIntentTest=restarted.then(recover(true)).then(publish(deny0,1,true,true)).expect(safety)
  run offlineOwnerCannotPublishTest=restarted.then(publish(deny0,1,true,true).fail())
  run recoveryRequiresEvidenceTest=restarted.then(recover(false).fail())
  run producerSnapshotCannotResetOwnerTest=published.then(loseProducer).expect(safety and s.generation==1 and not(s.allowed))
  run missingStageProjectionCannotPublishTest=pending.then(loseProducer).then(publish(deny0,0,true,true).fail())
  run exactStageProjectionCanRecoverTest=pending.then(loseProducer).then(restoreStage(deny0,true)).then(publish(deny0,0,true,true)).expect(safety)
  run foreignStageCannotRecoverTest=pending.then(loseProducer).then(restoreStage(allow0,true).fail())
  run mixedSnapshotsDoNotRevivePermitTest=acknowledged.then(loseProducer).then(loseReplies).then(restoreAck(denyRecord,true)).then(consume(permit0).fail())
  run originalUnknownHoldSurvivesPublicationTest=unknown.then(acknowledge(denyRecord,true)).expect(safety and s.spent and s.hold==6 and s.usage == -1)
  run lateUsageStillNeedsSourceEvidenceTest=unknown.then(finalUsage(4,false).fail())
  run qualifiedLateUsageKeepsOriginalSlotTest=unknown.then(finalUsage(4,true)).expect(safety and s.calls==1 and s.hold==6)
  run restoredAllowDoesNotReviveGenerationTest=published.then(stage(deny1.with("allowed",true),true)).then(publish(deny1.with("allowed",true),0,true,true)).then(consume(permit0).fail())
  action unsafeAck(r)=s'=s.with("acks",s.acks.union(Set(r)))
  action unsafePublish(c,worker)=s'=s.with("generation",s.generation+1).with("allowed",c.allowed)
    .with("log",s.log.append({change:c,generation:s.generation+1,worker:worker,acceptedFence:s.fence}))
  action unsafeAckRollback(r)=s'=s.with("generation",r.generation).with("allowed",r.change.allowed)
  action unsafeCachedConsume(p)=s'=s.with("spent",true).with("calls",s.calls+1)
    .with("uses",s.uses.append({permit:p,actualGeneration:s.log.length(),actualFence:s.fence,actualRevision:s.revision,allowed:effective}))
  action unsafeRefund=s'=s.with("hold",0).with("charged",true)
  run prematureAckPolicyCounterexampleTest=pending.then(unsafeAck(denyRecord)).expect(not(provenance))
  run lostReplyReplayPolicyCounterexampleTest=published.then(loseReplies).then(unsafePublish(deny0,0)).expect(not(unique))
  run staleParentPolicyCounterexampleTest=pending.then(stage(allow0.with("id",11),true)).then(publish(deny0,0,true,true))
    .then(unsafePublish(allow0.with("id",11),0)).expect(not(parents))
  run lateAckRollbackPolicyCounterexampleTest=newer.then(acknowledge(allowRecord,true)).then(unsafeAckRollback(allowRecord)).then(consume(permit1)).expect(not(usesBound))
  run oldPublisherPolicyCounterexampleTest=restarted.then(recover(true)).then(unsafePublish(deny0,0)).expect(not(parents))
  run tornRecoveryPolicyCounterexampleTest=acknowledged.then(loseProducer).then(loseReplies).then(unsafeCachedConsume(permit0)).expect(not(usesBound))
  run idAliasPolicyCounterexampleTest=pending.then(unsafePublish(allow0,0)).expect(not(provenance))
  run unknownRefundPolicyCounterexampleTest=unknown.then(acknowledge(denyRecord,true)).then(unsafeRefund).expect(not(accounting))
}
