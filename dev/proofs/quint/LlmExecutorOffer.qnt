// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

module LlmExecutorOffer {
  type Image={spent:Set[int],exposure:int,version:int,root:int,profile:int,budget:int,history:int}
  type Request={id:int,nonce:int,amount:int,parent:int,epoch:int}
  type Result={request:Request,position:int,before:Image,after:Image}
  type Projection={position:int,body:Image}
  type Application={result:Result,before:Projection,worker:int,epoch:int}
  type Operation={key:int,slot:int,source:int,nonce:int,payload:int,route:int,profile:int,lo:int,hi:int}
  type Permit={operation:Operation,position:int,body:Image,epoch:int,policy:int,queueRevision:int}
  type Admission={permit:Permit,position:int,body:Image,epoch:int,policy:int,revision:int,joined:bool,beforeCalls:int,afterCalls:int}
  type Ticket={view:Permit,rangeEpoch:int,revision:int,activation:int}
  type Offer={ticket:Ticket,actual:Permit,rangeEpoch:int,revision:int,activation:int,worker:int,owner:int,laneOwner:int,allowed:bool}
  type Receipt={call:Ticket,bytes:int,full:bool}
  type State={authority:Image,log:List[Result],pending:Set[Request],sourceStore:Projection,accountStore:Projection,
    epoch:int,qualified:bool,open:bool,observed:Set[int],applications:List[Application],activations:List[bool],queued:Set[int],calls:int,everExposure:int,denied:bool,policyVersion:int,queueRevision:int,permits:Set[Permit],entries:Set[Operation],admissions:List[Admission],offers:Set[int],sourceCalls:int,dequeued:bool,laneOwner:int,rangeEpoch:int,revision:int,fenced:bool,rangeAllowed:bool,activation:int,seen:int,jobs:Set[int],tickets:Set[Ticket],burns:Set[Ticket],submitted:bool,laneCalls:int,unknown:bool,full:bool,executions:List[Offer],receipts:List[Receipt],executionQualified:bool}
  var s:State
  pure val genesis={spent:Set(),exposure:0,version:0,root:10,profile:30,budget:5,history:9}
  pure val zero={position:0,body:genesis}
  pure val r0={id:1,nonce:11,amount:3,parent:0,epoch:0}
  pure val r1={id:2,nonce:12,amount:2,parent:1,epoch:0}
  pure val i1=genesis.with("spent",Set(11)).with("exposure",3).with("version",1)
  pure val i2=i1.with("spent",Set(11,12)).with("exposure",5).with("version",2)
  pure val d0={request:r0,position:1,before:genesis,after:i1}
  pure val d1={request:r1,position:2,before:i1,after:i2}
  pure val initial={authority:genesis,log:List(),pending:Set(),sourceStore:zero,accountStore:zero,epoch:0,qualified:true,open:true,
    observed:Set(),applications:List(),activations:List(),queued:Set(),calls:0,everExposure:0,denied:false,policyVersion:0,queueRevision:0,permits:Set(),entries:Set(),admissions:List(),offers:Set(),sourceCalls:0,dequeued:false,laneOwner:0,rangeEpoch:0,revision:0,fenced:false,rangeAllowed:true,activation:-1,seen:-1,jobs:Set(),tickets:Set(),burns:Set(),submitted:false,laneCalls:0,unknown:false,full:false,executions:List(),receipts:List(),executionQualified:true}
  pure def validPrefix(log,p)=(p.position==0 and p.body==genesis) or
    log.indices().exists(i=>log.nth(i).position==p.position and log.nth(i).after==p.body)
  def joined=s.sourceStore.position==s.log.length() and s.accountStore.position==s.log.length() and
    s.sourceStore.body==s.authority and s.accountStore.body==s.authority
  def applyGate(p,d,worker)=s.qualified and worker==s.epoch and p.position<s.log.length() and s.log.nth(p.position)==d and
    d.position==p.position+1 and p.body==d.before
  action init=s'=initial
  action stage(r,worker)=all {worker==s.epoch,s.qualified,s.pending.forall(old=>old.id!=r.id or old==r),s'=s.with("pending",s.pending.union(Set(r)))}
  action commit(r,policy)=all {s.open,s.qualified,s.pending.contains(r),r.epoch==s.epoch,r.parent==s.log.length(),
    s.log.indices().forall(i=>s.log.nth(i).request.id!=r.id),not(s.authority.spent.contains(r.nonce)),policy,not(s.denied),
    Set(11,12).contains(r.nonce),r.amount>=0,s.authority.exposure+r.amount<=5,
    val after=s.authority.with("spent",s.authority.spent.union(Set(r.nonce))).with("exposure",s.authority.exposure+r.amount).with("version",s.authority.version+1)
    s'=s.with("authority",after).with("everExposure",after.exposure)
      .with("log",s.log.append({request:r,position:s.log.length()+1,before:s.authority,after:after}))}
  action applySource(d,worker)=all {applyGate(s.sourceStore,d,worker),s'=s.with("sourceStore",{position:d.position,body:d.after})
    .with("applications",s.applications.append({result:d,before:s.sourceStore,worker:worker,epoch:s.epoch}))}
  action applyAccount(d,worker)=all {applyGate(s.accountStore,d,worker),s'=s.with("accountStore",{position:d.position,body:d.after})
    .with("applications",s.applications.append({result:d,before:s.accountStore,worker:worker,epoch:s.epoch}))}
  action query(r)=all {s.qualified,s.log.indices().exists(i=>s.log.nth(i).request==r),s'=s.with("observed",s.observed.union(Set(r.id)))}
  action loseReply=s'=s.with("observed",Set())
  action restart=s'=s.with("executionQualified",false).with("epoch",s.epoch+1).with("qualified",false).with("open",false)
  action recover(exactPrefix)=all {not(s.qualified),not(s.open),exactPrefix,s'=s.with("qualified",true).with("open",false)}
  action restoreSource(p,worker)=all {s.qualified,not(s.open),worker==s.epoch,validPrefix(s.log,p),s'=s.with("sourceStore",p)}
  action restoreAccount(p,worker)=all {s.qualified,not(s.open),worker==s.epoch,validPrefix(s.log,p),s'=s.with("accountStore",p)}
  action activate=all {s.qualified,joined,s'=s.with("open",true).with("activations",s.activations.append(joined))}
  action denyHistory=s'=s.with("denied",true).with("policyVersion",s.policyVersion+1)
  val logBound=s.log.indices().forall(i=>{val d=s.log.nth(i)
    d.position==i+1 and d.before==(if (i==0) genesis else s.log.nth(i-1).after) and
    d.after==d.before.with("spent",d.before.spent.union(Set(d.request.nonce))).with("exposure",d.before.exposure+d.request.amount).with("version",d.before.version+1) and
    not(d.before.spent.contains(d.request.nonce)) and s.pending.contains(d.request)}) and
    s.authority==(if (s.log.length()==0) genesis else s.log.nth(s.log.length()-1).after)
  val projections=validPrefix(s.log,s.sourceStore) and validPrefix(s.log,s.accountStore)
  val applications=s.applications.indices().forall(i=>{val a=s.applications.nth(i)
    a.worker==a.epoch and a.before.body==a.result.before and a.result.position==a.before.position+1})
  val accounting=s.authority.exposure==s.everExposure and s.authority.exposure<=5
  val projectionSafety=logBound and projections and applications and accounting and s.activations.indices().forall(i=>s.activations.nth(i))
  action committed=init.then(stage(r0,0)).then(commit(r0,true))
  action sourceOnly=committed.then(applySource(d0,0))
  action complete=sourceOnly.then(applyAccount(d0,0))
  action pair=committed.then(stage(r1,0)).then(commit(r1,true))
  action restarted=sourceOnly.then(restart)
  pure val op0={key:1,slot:11,source:1,nonce:11,payload:30,route:100,profile:30,lo:0,hi:4}
  pure val op1={key:2,slot:12,source:2,nonce:12,payload:30,route:100,profile:30,lo:0,hi:4}
  pure val p0={operation:op0,position:1,body:i1,epoch:0,policy:0,queueRevision:0}
  pure val p1={operation:op1,position:2,body:i2,epoch:0,policy:0,queueRevision:0}
  def authentic(op)=s.log.indices().exists(i=>{val r=s.log.nth(i).request
    r.id==op.source and r.nonce==op.nonce and op.slot==r.nonce}) and op.payload==30 and op.route==100 and op.profile==30 and op.lo==0 and op.hi==4
  def imagePermit(op)={operation:op,position:s.log.length(),body:s.authority,epoch:s.epoch,policy:s.policyVersion,queueRevision:s.queueRevision}
  def gate(p)=s.permits.contains(p) and joined and s.open and s.qualified and p.position==s.log.length() and p.body==s.authority and
    p.epoch==s.epoch and p.policy==s.policyVersion and p.queueRevision==s.queueRevision
  def admission(p,afterCalls)={permit:p,position:s.log.length(),body:s.authority,epoch:s.epoch,policy:s.policyVersion,
    revision:s.queueRevision,joined:joined,beforeCalls:s.calls,afterCalls:afterCalls}
  action resolve(op)=all {joined,s.open,s.qualified,authentic(op),s'=s.with("permits",s.permits.union(Set(imagePermit(op))))}
  action enqueue(p,worker,policy,durable)=all {gate(p),worker==s.epoch,policy,not(s.denied),durable,authentic(p.operation),
    s.entries.forall(old=>old.key!=p.operation.key and old.slot!=p.operation.slot),
    s'=s.with("entries",s.entries.union(Set(p.operation))).with("queued",s.queued.union(Set(p.operation.key)))
      .with("queueRevision",s.queueRevision+1).with("admissions",s.admissions.append(admission(p,s.calls)))}
  action queryQueue(op)=all {s.qualified,s.entries.contains(op),s'=s.with("observed",s.observed.union(Set(op.key)))}
  val admissionCurrent=s.admissions.indices().forall(i=>{val a=s.admissions.nth(i) val p=a.permit
    a.joined and p.position==a.position and p.body==a.body and p.epoch==a.epoch and p.policy==a.policy and p.queueRevision==a.revision and a.beforeCalls==a.afterCalls})
  val slotUnique=s.admissions.indices().forall(i=>s.admissions.indices().forall(j=>i==j or s.admissions.nth(i).permit.operation.slot!=s.admissions.nth(j).permit.operation.slot))
  val immutableEntries=s.admissions.indices().forall(i=>s.entries.contains(s.admissions.nth(i).permit.operation))
  val boundEntries=s.entries.forall(op=>authentic(op))
  val sendOnce=s.calls==s.offers.size() and s.offers.forall(slot=>s.entries.exists(op=>op.slot==slot))
  val noCommitSend=s.sourceCalls==0
  val queueSafety=projectionSafety and admissionCurrent and slotUnique and immutableEntries and boundEntries and sendOnce and noCommitSend
  action resolved=complete.then(resolve(op0))
  action enqueued=resolved.then(enqueue(p0,0,true,true))
  action newCommit=resolved.then(stage(r1,0)).then(commit(r1,true))
  action newJoined=newCommit.then(applySource(d1,0)).then(applyAccount(d1,0))
  action newOwner=resolved.then(restart).then(recover(true)).then(activate)
  def registered=s.entries.contains(op0)
  action recoverExecution(exact)=all {not(s.executionQualified),s.qualified,exact,s'=s.with("executionQualified",true)}
  action dequeue(op,worker)=all {op==op0,registered,not(s.dequeued),s.qualified,worker==s.epoch,
    s'=s.with("dequeued",true)}
  action fenceLane=all {registered,s'=s.with("rangeEpoch",s.rangeEpoch+1).with("revision",s.revision+1).with("fenced",true).with("activation",-1).with("seen",-1)}
  action alignOwner(worker)=all {registered,s.qualified,s.executionQualified,worker==s.epoch,s.laneOwner!=s.epoch,
    s'=s.with("laneOwner",s.epoch).with("rangeEpoch",s.rangeEpoch+1).with("revision",s.revision+1).with("fenced",true).with("activation",-1).with("seen",-1)}
  action certify(exact)=all {s.fenced,exact,s'=s.with("seen",s.revision)}
  action prepareRange=all {s.fenced,s.seen==s.revision,s.laneCalls==0,s'=s.with("jobs",s.jobs.union(Set(s.revision)))}
  action activateRange(policy)=all {s.fenced,s.jobs.contains(s.revision),s.laneCalls==0,s.rangeAllowed,policy,
    s'=s.with("revision",s.revision+1).with("activation",s.revision+1).with("fenced",false).with("seen",-1)}
  def currentTicket={view:imagePermit(op0),rangeEpoch:s.rangeEpoch,revision:s.revision,activation:s.activation}
  def executionGate(t,worker)=registered and s.dequeued and s.qualified and s.open and joined and s.tickets.contains(t) and
    s.executionQualified and t==currentTicket and worker==s.epoch and s.laneOwner==s.epoch and s.activation>=0
  action observeOffer(worker)=all {registered,s.dequeued,s.qualified,s.executionQualified,s.open,joined,worker==s.epoch,s.laneOwner==s.epoch,s.activation>=0,
    s'=s.with("tickets",s.tickets.union(Set(currentTicket)))}
  action burn(t,worker,policy,durable)=all {executionGate(t,worker),policy,not(s.denied),s.burns.size()==0,s.laneCalls==0,durable,
    s'=s.with("burns",Set(t))}
  def offerRecord(t,worker)={ticket:t,actual:imagePermit(op0),rangeEpoch:s.rangeEpoch,revision:s.revision,activation:s.activation,
    worker:worker,owner:s.epoch,laneOwner:s.laneOwner,allowed:not(s.denied)}
  action submit(t,worker,policy,durable)=all {executionGate(t,worker),policy,not(s.denied),s.burns==Set(t),not(s.submitted),
    not(s.fenced),s.rangeAllowed,s.laneCalls==0,t.activation==s.activation,durable,
    s'=s.with("submitted",true).with("laneCalls",1).with("unknown",true).with("revision",s.revision+1).with("activation",-1)
      .with("executions",s.executions.append(offerRecord(t,worker))).with("calls",s.calls+1).with("offers",s.offers.union(Set(op0.slot)))}
  action partial(t,bytes)=all {s.executions.indices().exists(i=>s.executions.nth(i).ticket==t),bytes>0,bytes<4,
    s'=s.with("receipts",s.receipts.append({call:t,bytes:bytes,full:false}))}
  action fullReceipt(t,bytes,authentic)=all {s.executions.indices().exists(i=>s.executions.nth(i).ticket==t),bytes==4,authentic,
    s'=s.with("unknown",false).with("full",true).with("receipts",s.receipts.append({call:t,bytes:bytes,full:true}))}
  action timeout=s'=s
  action allowHistory=s'=s.with("denied",false).with("policyVersion",s.policyVersion+1)
  val offersCurrent=s.executions.indices().forall(i=>{val a=s.executions.nth(i) val t=a.ticket
    t.view==a.actual and t.rangeEpoch==a.rangeEpoch and t.revision==a.revision and t.activation==a.activation and
    a.worker==a.owner and a.laneOwner==a.owner and a.allowed and t.view.operation==op0})
  val once=s.laneCalls<=1 and s.laneCalls==s.executions.length() and (s.submitted iff s.laneCalls==1)
  val held=(s.unknown implies s.submitted and s.laneCalls==1 and not(s.full) and s.authority.exposure>=3) and
    (s.burns.size()>0 implies s.authority.exposure>=3)
  val receiptBound=s.receipts.indices().forall(i=>{val r=s.receipts.nth(i)
    (r.full implies r.bytes==4) and s.executions.indices().exists(j=>s.executions.nth(j).ticket==r.call)})
  val burnRetained=s.executions.indices().forall(i=>s.burns.contains(s.executions.nth(i).ticket)) and s.burns.size()<=1
  val safety=queueSafety and offersCurrent and once and held and receiptBound and burnRetained
  action dequeued=enqueued.then(dequeue(op0,0))
  action rangeReady=dequeued.then(fenceLane).then(certify(true)).then(prepareRange).then(activateRange(true))
  action observed=rangeReady.then(observeOffer(0))
  pure val t0={view:p0.with("queueRevision",1),rangeEpoch:1,revision:2,activation:2}
  action burned=observed.then(burn(t0,0,true,true))
  action offered=burned.then(submit(t0,0,true,true))
  action partialWrite=offered.then(partial(t0,2))
  action switched=observed.then(restart).then(recover(true)).then(activate)
  action realigned=switched.then(recoverExecution(true)).then(alignOwner(1)).then(certify(true)).then(prepareRange).then(activateRange(true)).then(observeOffer(1))
  pure val t1={view:p0.with("queueRevision",1).with("epoch",1),rangeEpoch:2,revision:4,activation:4}
  action step={nondet t=s.tickets.union(Set(t0)).oneOf() nondet r=Set(r0,r1).oneOf()
    nondet d=s.log.indices().map(i=>s.log.nth(i)).union(Set(d0)).oneOf()
    any {recoverExecution(true),stage(r,s.epoch),commit(r,true),applySource(d,s.epoch),applyAccount(d,s.epoch),resolve(op0),enqueue(p0,s.epoch,true,true),queryQueue(op0),
      dequeue(op0,s.epoch),fenceLane,alignOwner(s.epoch),certify(true),prepareRange,activateRange(true),observeOffer(s.epoch),burn(t,s.epoch,true,true),submit(t,s.epoch,true,true),
      partial(t,2),fullReceipt(t,4,true),timeout,denyHistory,allowHistory,restart,recover(true),activate}}
  run dequeueIsNotInvocationTest=dequeued.expect(safety and s.calls==0 and s.laneCalls==0)
  run dequeueRequiresDurableOriginalTest=complete.then(dequeue(op0,0).fail())
  run dequeueCannotMutateRouteTest=enqueued.then(dequeue(op0.with("route",999),0).fail())
  run observeAndBurnAreNotInvocationTest=burned.expect(safety and s.calls==0 and s.laneCalls==0 and s.burns.contains(t0))
  run submitRequiresOriginalBurnTest=observed.then(submit(t0,0,true,true).fail())
  run burnRequiresDurableEvidenceTest=observed.then(burn(t0,0,true,false).fail())
  run submitRequiresDurableMarkerTest=burned.then(submit(t0,0,true,false).fail())
  run policyChangesAfterDequeueTest=observed.then(denyHistory).then(burn(t0,0,true,true).fail())
  run freshTicketStillChecksEffectivePolicyTest=observed.then(denyHistory).then(observeOffer(0))
    .expect(executionGate(t0.with("view",t0.view.with("policy",1)),0) and s.denied)
    .then(burn(t0.with("view",t0.view.with("policy",1)),0,true,true).fail())
  run policyChangesAfterBurnTest=burned.then(denyHistory).then(submit(t0,0,true,true).fail())
  run currentTicketNeedsFinalOfferAllowTest=burned.expect(executionGate(t0,0)).then(submit(t0,0,false,true).fail())
  run policyABACannotReviveTicketTest=burned.then(denyHistory).then(allowHistory).then(submit(t0,0,true,true).fail())
  run newCommitAfterDequeueBlocksTicketTest=observed.then(stage(r1,0)).then(commit(r1,true)).then(burn(t0,0,true,true).fail())
  run caughtUpJoinStillRejectsOldOfferTicketTest=observed.then(stage(r1,0)).then(commit(r1,true)).then(applySource(d1,0)).then(applyAccount(d1,0))
    .expect(joined).then(burn(t0,0,true,true).fail())
  run newOwnerMustFenceRangeBeforeObservationTest=switched.then(observeOffer(1).fail())
  run executorRecoveryCannotTrustQueueOnlyTest=switched.then(alignOwner(1).fail())
  run executorRecoveryRequiresCompleteEvidenceTest=switched.then(recoverExecution(false).fail())
  run oldOwnerCannotBurnAfterSwitchTest=switched.then(burn(t0,0,true,true).fail())
  run currentOwnerCanUseRequalifiedUnusedRangeTest=realigned.then(burn(t1,1,true,true)).then(submit(t1,1,true,true)).expect(safety and s.laneCalls==1)
  run oldWorkerCannotUseFreshRangeTicketTest=realigned.expect(executionGate(t1,1)).then(burn(t1,0,true,true).fail())
  run restartAfterBurnCannotCreateNewBurnTest=burned.then(restart).then(recover(true)).then(activate).then(recoverExecution(true)).then(alignOwner(1)).then(certify(true)).then(prepareRange).then(activateRange(true))
    .then(observeOffer(1)).then(burn(t1,1,true,true).fail())
  run partialWriteCannotBeOfferedAgainTest=partialWrite.then(submit(t0,0,true,true).fail())
  run partialWriteCannotRearmRangeTest=partialWrite.then(fenceLane).then(certify(true)).then(prepareRange.fail())
  run timeoutCannotReleaseOrRearmTest=partialWrite.then(timeout).expect(safety and s.unknown and s.authority.exposure==3 and s.laneCalls==1)
  run partialReceiptCannotClaimFullCompletionTest=partialWrite.then(fullReceipt(t0,2,true).fail())
  run unauthenticatedFullReceiptRejectedTest=offered.then(fullReceipt(t0,4,false).fail())
  run lateFullReceiptAfterOwnerSwitchIsDataTest=partialWrite.then(restart).then(recover(true)).then(fullReceipt(t0,4,true))
    .expect(safety and s.full and not(s.unknown) and s.laneCalls==1 and s.authority.exposure==3)
  run fullReceiptDoesNotRestoreSendAuthorityTest=offered.then(fullReceipt(t0,4,true)).then(submit(t0,0,true,true).fail())
  run changedPayloadCannotUseBurnTest=burned.then(submit(t0.with("view",t0.view.with("operation",op0.with("payload",999))),0,true,true).fail())
  run tailMutationCannotUseOriginalBurnTest=burned.then(submit(t0.with("view",t0.view.with("operation",op0.with("lo",2))),0,true,true).fail())
  run originalSlotAndUnknownHoldSurviveRestartTest=partialWrite.then(restart).then(recover(true)).then(queryQueue(op0))
    .expect(safety and s.entries.contains(op0) and s.burns.contains(t0) and s.unknown and s.authority.exposure==3)
  run oneSubmitMarksOriginalUnknownTest=offered.expect(safety and s.submitted and s.unknown and s.laneCalls==1 and s.sourceCalls==0)
  action unsafeSubmit(t,worker)=s'=s.with("submitted",true).with("laneCalls",s.laneCalls+1).with("unknown",true)
    .with("executions",s.executions.append(offerRecord(t,worker))).with("calls",s.calls+1).with("offers",s.offers.union(Set(op0.slot)))
  action unsafeReset=s'=s.with("submitted",false).with("laneCalls",0).with("unknown",false)
  action unsafeRefund=s'=s.with("authority",s.authority.with("exposure",0))
  action unsafePartialFull=s'=s.with("full",true).with("unknown",false).with("receipts",s.receipts.append({call:t0,bytes:2,full:true}))
  action unsafeDequeueInvoke=s'=s.with("dequeued",true).with("laneCalls",1)
  action unsafeLaneOffer=s'=s.with("submitted",true).with("laneCalls",1).with("unknown",true)
    .with("executions",s.executions.append(offerRecord(currentTicket,1))).with("calls",1).with("offers",Set(11)).with("burns",Set(currentTicket))
  run stalePolicyExecutorCounterexampleTest=burned.then(denyHistory).then(unsafeSubmit(t0,0)).expect(not(offersCurrent))
  run oldOwnerExecutorCounterexampleTest=burned.then(restart).then(recover(true)).then(activate).then(unsafeSubmit(t0,0)).expect(not(offersCurrent))
  run unfencedRangeExecutorCounterexampleTest=switched.then(unsafeLaneOffer).expect(not(offersCurrent))
  run stalePrefixExecutorCounterexampleTest=burned.then(stage(r1,0)).then(commit(r1,true)).then(applySource(d1,0)).then(applyAccount(d1,0))
    .then(unsafeSubmit(t0,0)).expect(not(offersCurrent))
  run partialRetryExecutorCounterexampleTest=partialWrite.then(unsafeSubmit(t0,0)).expect(not(once))
  run snapshotResetExecutorCounterexampleTest=partialWrite.then(restart).then(unsafeReset).expect(not(once))
  run unknownRefundExecutorCounterexampleTest=partialWrite.then(unsafeRefund).expect(not(held))
  run forgedCompletionExecutorCounterexampleTest=partialWrite.then(unsafePartialFull).expect(not(receiptBound))
  run tailRewriteExecutorCounterexampleTest=burned.then(unsafeSubmit(t0.with("view",t0.view.with("operation",op0.with("lo",2))),0)).expect(not(offersCurrent))
  run dequeueSendExecutorCounterexampleTest=enqueued.then(unsafeDequeueInvoke).expect(not(once))
}
