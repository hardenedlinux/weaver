// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

module LlmJoinEnqueue {
  type Image={spent:Set[int],exposure:int,version:int,root:int,profile:int,budget:int,history:int}
  type Request={id:int,nonce:int,amount:int,parent:int,epoch:int}
  type Result={request:Request,position:int,before:Image,after:Image}
  type Projection={position:int,body:Image}
  type Application={result:Result,before:Projection,worker:int,epoch:int}
  type Operation={key:int,slot:int,source:int,nonce:int,payload:int,route:int,profile:int,lo:int,hi:int}
  type Permit={operation:Operation,position:int,body:Image,epoch:int,policy:int,queueRevision:int}
  type Admission={permit:Permit,position:int,body:Image,epoch:int,policy:int,revision:int,joined:bool,beforeCalls:int,afterCalls:int}
  type State={authority:Image,log:List[Result],pending:Set[Request],sourceStore:Projection,accountStore:Projection,
    epoch:int,qualified:bool,open:bool,observed:Set[int],applications:List[Application],activations:List[bool],queued:Set[int],calls:int,everExposure:int,denied:bool,policyVersion:int,queueRevision:int,permits:Set[Permit],entries:Set[Operation],admissions:List[Admission],offers:Set[int],sourceCalls:int}
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
    observed:Set(),applications:List(),activations:List(),queued:Set(),calls:0,everExposure:0,denied:false,policyVersion:0,queueRevision:0,permits:Set(),entries:Set(),admissions:List(),offers:Set(),sourceCalls:0}
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
  action restart=s'=s.with("epoch",s.epoch+1).with("qualified",false).with("open",false)
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
  pure val op0={key:1,slot:11,source:1,nonce:11,payload:30,route:100,profile:30,lo:0,hi:1}
  pure val op1={key:2,slot:12,source:2,nonce:12,payload:30,route:100,profile:30,lo:0,hi:1}
  pure val p0={operation:op0,position:1,body:i1,epoch:0,policy:0,queueRevision:0}
  pure val p1={operation:op1,position:2,body:i2,epoch:0,policy:0,queueRevision:0}
  def authentic(op)=s.log.indices().exists(i=>{val r=s.log.nth(i).request
    r.id==op.source and r.nonce==op.nonce and op.slot==r.nonce}) and op.payload==30 and op.route==100 and op.profile==30 and op.lo==0 and op.hi==1
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
  action send(op,worker,policy)=all {s.qualified,s.open,joined,worker==s.epoch,policy,not(s.denied),s.entries.contains(op),authentic(op),
    not(s.offers.contains(op.slot)),s'=s.with("offers",s.offers.union(Set(op.slot))).with("calls",s.calls+1)}
  val admissionCurrent=s.admissions.indices().forall(i=>{val a=s.admissions.nth(i) val p=a.permit
    a.joined and p.position==a.position and p.body==a.body and p.epoch==a.epoch and p.policy==a.policy and p.queueRevision==a.revision and a.beforeCalls==a.afterCalls})
  val slotUnique=s.admissions.indices().forall(i=>s.admissions.indices().forall(j=>i==j or s.admissions.nth(i).permit.operation.slot!=s.admissions.nth(j).permit.operation.slot))
  val immutableEntries=s.admissions.indices().forall(i=>s.entries.contains(s.admissions.nth(i).permit.operation))
  val boundEntries=s.entries.forall(op=>authentic(op))
  val sendOnce=s.calls==s.offers.size() and s.offers.forall(slot=>s.entries.exists(op=>op.slot==slot))
  val noCommitSend=s.sourceCalls==0
  val safety=projectionSafety and admissionCurrent and slotUnique and immutableEntries and boundEntries and sendOnce and noCommitSend
  action resolved=complete.then(resolve(op0))
  action enqueued=resolved.then(enqueue(p0,0,true,true))
  action sent=enqueued.then(send(op0,0,true))
  action newCommit=resolved.then(stage(r1,0)).then(commit(r1,true))
  action newJoined=newCommit.then(applySource(d1,0)).then(applyAccount(d1,0))
  action newOwner=resolved.then(restart).then(recover(true)).then(activate)
  action step={nondet op=Set(op0,op1).oneOf() nondet d=s.log.indices().map(i=>s.log.nth(i)).union(Set(d0)).oneOf()
    nondet p=s.permits.union(Set(p0)).oneOf() nondet r=Set(r0,r1).oneOf()
    any {stage(r,s.epoch),commit(r,true),applySource(d,s.epoch),applyAccount(d,s.epoch),resolve(op),enqueue(p,s.epoch,true,true),queryQueue(op),send(op,s.epoch,true),
      loseReply,restart,recover(true),activate,denyHistory}}
  run noSendDuringCommitTest=committed.expect(safety and s.calls==0 and s.sourceCalls==0 and s.entries.size()==0)
  run noSendDuringProjectionTest=complete.expect(safety and s.calls==0 and s.sourceCalls==0)
  run initialJoinCannotGrantUncommittedOperationTest=init.then(resolve(op0).fail())
  run finalEnqueueChecksFullCurrentImageTest=enqueued.expect(safety and s.calls==0 and s.entries.contains(op0) and s.authority==i1 and s.sourceStore.body==i1 and s.accountStore.body==i1)
  run partialJoinCannotResolveTest=sourceOnly.then(resolve(op0).fail())
  run newCommitInvalidatesJoinReceiptTest=newCommit.then(enqueue(p0,0,true,true).fail())
  run caughtUpProjectionStillRejectsOldReceiptTest=newJoined.expect(joined).then(enqueue(p0,0,true,true).fail())
  run freshReceiptAfterNewCommitCanEnqueueTest=newJoined.then(resolve(op0)).then(enqueue(p0.with("position",2).with("body",i2),0,true,true)).expect(safety)
  run ownerSwitchInvalidatesOldReceiptTest=newOwner.expect(joined).then(enqueue(p0,1,true,true).fail())
  run oldWorkerCannotUseFreshReceiptTest=newOwner.then(resolve(op0)).expect(gate(p0.with("epoch",1))).then(enqueue(p0.with("epoch",1),0,true,true).fail())
  run currentOwnerCanUseFreshReceiptTest=newOwner.then(resolve(op0)).then(enqueue(p0.with("epoch",1),1,true,true)).expect(safety)
  run policyChangeInvalidatesReceiptTest=resolved.then(denyHistory).then(enqueue(p0,0,true,true).fail())
  run freshPolicyReceiptStillCannotBypassDenialTest=resolved.then(denyHistory).then(resolve(op0)).expect(gate(p0.with("policy",1)) and s.denied)
    .then(enqueue(p0.with("policy",1),0,true,true).fail())
  run finalPolicyMustAllowTest=resolved.then(enqueue(p0,0,false,true).fail())
  run enqueueRequiresDurableDecisionTest=resolved.then(enqueue(p0,0,true,false).fail())
  run lostQueueReplyQueriesOriginalTest=enqueued.then(loseReply).then(queryQueue(op0)).expect(safety and s.entries.size()==1 and s.calls==0)
  run oldQueueRevisionCannotReplayTest=enqueued.then(enqueue(p0,0,true,true).fail())
  run freshQueueReceiptStillSeesOriginalClaimTest=enqueued.then(resolve(op0)).expect(gate(p0.with("queueRevision",1)))
    .then(enqueue(p0.with("queueRevision",1),0,true,true).fail())
  run sdkFreshKeyCannotCloneSlotTest=enqueued.then(resolve(op0.with("key",7))).expect(gate(p0.with("operation",op0.with("key",7)).with("queueRevision",1)))
    .then(enqueue(p0.with("operation",op0.with("key",7)).with("queueRevision",1),0,true,true).fail())
  run sdkRouteConversionMustMatchOriginalTest=complete.then(resolve(op0.with("route",999)).fail())
  run sdkPayloadConversionMustMatchOriginalTest=complete.then(resolve(op0.with("payload",999)).fail())
  run restartPreservesQueueSlotTest=enqueued.then(restart).then(recover(true)).then(activate).then(resolve(op0))
    .then(enqueue(p0.with("epoch",1).with("queueRevision",1),1,true,true).fail())
  run finalQueueDoesNotRefundUnknownTest=sent.then(loseReply).then(queryQueue(op0)).expect(safety and s.authority.exposure==3 and s.authority.spent.contains(11))
  run sdkRetryCannotRepeatOfferTest=sent.then(send(op0,0,true).fail())
  run oldWorkerCannotDrainAfterSwitchTest=enqueued.then(restart).then(recover(true)).then(activate).then(send(op0,0,true).fail())
  run newCommitBlocksDrainUntilJoinTest=enqueued.then(stage(r1,0)).then(commit(r1,true)).then(send(op0,0,true).fail())
  run freshDrainStillChecksPolicyTest=enqueued.then(denyHistory).then(send(op0,0,true).fail())
  run admissionHasNoProviderInvocationTest=enqueued.expect(safety and s.calls==0 and s.offers.size()==0)
  run laterProviderOfferIsSeparateTest=sent.expect(safety and s.calls==1 and s.entries.size()==1 and s.sourceCalls==0)
  run lostReplyCannotReassignUnknownBudgetTest=sent.then(restart).then(recover(true)).then(activate).then(queryQueue(op0)).expect(safety and s.authority.exposure==3 and s.calls==1)
  action unsafeEnqueue(p)=s'=s.with("entries",s.entries.union(Set(p.operation))).with("queued",s.queued.union(Set(p.operation.key)))
    .with("queueRevision",s.queueRevision+1).with("admissions",s.admissions.append(admission(p,s.calls)))
  action unsafeCommitSend=s'=s.with("sourceCalls",1)
  action unsafeEnqueueAndSend(p)=s'=s.with("entries",s.entries.union(Set(p.operation))).with("queued",s.queued.union(Set(p.operation.key)))
    .with("queueRevision",s.queueRevision+1).with("admissions",s.admissions.append(admission(p,s.calls+1))).with("calls",s.calls+1).with("offers",Set(11))
  action unsafeEraseQueue=s'=s.with("entries",Set()).with("queued",Set())
  run staleJoinCommitJoinCounterexampleTest=newJoined.then(unsafeEnqueue(p0)).expect(not(admissionCurrent))
  run oldOwnerJoinCounterexampleTest=newOwner.then(unsafeEnqueue(p0)).expect(not(admissionCurrent))
  run stalePolicyJoinCounterexampleTest=resolved.then(denyHistory).then(unsafeEnqueue(p0)).expect(not(admissionCurrent))
  run sdkReplayJoinCounterexampleTest=enqueued.then(resolve(op0)).expect(gate(p0.with("queueRevision",1)))
    .then(unsafeEnqueue(p0.with("queueRevision",1))).expect(not(slotUnique))
  run freshKeyCloneJoinCounterexampleTest=enqueued.then(resolve(op0.with("key",7))).then(unsafeEnqueue(p0.with("operation",op0.with("key",7)).with("queueRevision",1))).expect(not(slotUnique))
  run commitSendJoinCounterexampleTest=committed.then(unsafeCommitSend).expect(not(noCommitSend))
  run enqueueSendJoinCounterexampleTest=resolved.then(unsafeEnqueueAndSend(p0)).expect(not(admissionCurrent))
  run routeSwapJoinCounterexampleTest=resolved.then(unsafeEnqueue(p0.with("operation",op0.with("route",999)))).expect(not(boundEntries))
  run partialJoinJoinCounterexampleTest=newCommit.then(unsafeEnqueue(p0)).expect(not(admissionCurrent))
  run queueRollbackJoinCounterexampleTest=enqueued.then(restart).then(unsafeEraseQueue).expect(not(immutableEntries))
}
