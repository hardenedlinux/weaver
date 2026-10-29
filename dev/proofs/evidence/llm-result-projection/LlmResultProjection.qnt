module LlmResultProjection {
  type Image={spent:Set[int],exposure:int,version:int,root:int,profile:int,budget:int,history:int}
  type Request={id:int,nonce:int,amount:int,parent:int,epoch:int}
  type Result={request:Request,position:int,before:Image,after:Image}
  type Projection={position:int,body:Image}
  type Application={result:Result,before:Projection,worker:int,epoch:int}
  type State={authority:Image,log:List[Result],pending:Set[Request],sourceStore:Projection,accountStore:Projection,
    epoch:int,qualified:bool,open:bool,observed:Set[int],applications:List[Application],activations:List[bool],queued:Set[int],calls:int,everExposure:int,denied:bool}
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
    observed:Set(),applications:List(),activations:List(),queued:Set(),calls:0,everExposure:0,denied:false}
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
  action enqueue(r,worker)=all {s.qualified,s.open,joined,worker==s.epoch,s.log.indices().exists(i=>s.log.nth(i).request==r),
    not(s.queued.contains(r.id)),s'=s.with("queued",s.queued.union(Set(r.id))).with("calls",s.calls+1)}
  action denyHistory=s'=s.with("denied",true)
  val logBound=s.log.indices().forall(i=>{val d=s.log.nth(i)
    d.position==i+1 and d.before==(if (i==0) genesis else s.log.nth(i-1).after) and
    d.after==d.before.with("spent",d.before.spent.union(Set(d.request.nonce))).with("exposure",d.before.exposure+d.request.amount).with("version",d.before.version+1) and
    not(d.before.spent.contains(d.request.nonce)) and s.pending.contains(d.request)}) and
    s.authority==(if (s.log.length()==0) genesis else s.log.nth(s.log.length()-1).after)
  val projections=validPrefix(s.log,s.sourceStore) and validPrefix(s.log,s.accountStore)
  val applications=s.applications.indices().forall(i=>{val a=s.applications.nth(i)
    a.worker==a.epoch and a.before.body==a.result.before and a.result.position==a.before.position+1})
  val accounting=s.authority.exposure==s.everExposure and s.authority.exposure<=5 and s.calls==s.queued.size()
  val safety=logBound and projections and applications and accounting and s.activations.indices().forall(i=>s.activations.nth(i))
  action committed=init.then(stage(r0,0)).then(commit(r0,true))
  action sourceOnly=committed.then(applySource(d0,0))
  action complete=sourceOnly.then(applyAccount(d0,0))
  action sent=complete.then(enqueue(r0,0))
  action pair=committed.then(stage(r1,0)).then(commit(r1,true))
  action restarted=sourceOnly.then(restart)
  action step={nondet nonce=Set(11,12).oneOf() nondet amount=Set(0,2,3).oneOf()
    val r={id:s.pending.size()+1,nonce:nonce,amount:amount,parent:s.log.length(),epoch:s.epoch}
    nondet pending=s.pending.union(Set(r)).oneOf() nondet d=s.log.indices().map(i=>s.log.nth(i)).union(Set(d0)).oneOf()
    nondet p=s.log.indices().map(i=>s.log.nth(i)).map(d=>{position:d.position,body:d.after}).union(Set(zero)).oneOf()
    any {stage(r,s.epoch),commit(pending,true),applySource(d,s.epoch),applyAccount(d,s.epoch),query(pending),loseReply,
      restart,recover(true),restoreSource(p,s.epoch),restoreAccount(p,s.epoch),activate,enqueue(pending,s.epoch),denyHistory}}
  run commitBeforeProjectionRetainsUnknownTest=committed.expect(safety and s.authority.spent.contains(11) and s.authority.exposure==3 and not(joined))
  run lostCommitReplyQueriesOriginalTest=committed.then(loseReply).then(query(r0)).expect(safety and s.log.length()==1 and s.observed.contains(1))
  run lostCommitReplyCannotConsumeAgainTest=committed.then(loseReply).then(commit(r0,true).fail())
  run newTransactionCannotReuseNonceTest=committed.then(stage(r0.with("id",7).with("parent",1),0)).then(commit(r0.with("id",7).with("parent",1),true).fail())
  run exactSourceCASPublishesCommittedBodyTest=sourceOnly.expect(safety and s.sourceStore.body==i1 and s.accountStore.body==genesis)
  run sourceOnlyCannotActivateTest=sourceOnly.then(activate.fail())
  run sourceOnlyCannotEnqueueTest=sourceOnly.then(enqueue(r0,0).fail())
  run sourceLostReplyCannotApplyDeltaAgainTest=sourceOnly.then(loseReply).then(applySource(d0,0).fail())
  run accountLostReplyCannotApplyDeltaAgainTest=complete.then(loseReply).then(applyAccount(d0,0).fail())
  run accountLostReplyQueryChangesNoExposureTest=complete.then(loseReply).then(query(r0)).expect(safety and s.accountStore.body.exposure==3 and s.authority.exposure==3)
  run wrongResultBodyCannotApplyTest=committed.then(applySource(d0.with("after",genesis),0).fail())
  run wrongBeforeCannotApplyTest=committed.then(applySource(d0.with("before",i1),0).fail())
  run projectionCannotSkipPrefixTest=pair.then(applySource(d1,0).fail())
  run twoResultsApplyInOrderTest=pair.then(applySource(d0,0)).then(applySource(d1,0)).then(applyAccount(d0,0)).then(applyAccount(d1,0)).expect(safety and joined and s.authority.exposure==5)
  run restartClosesOwnerAndBrokerTest=restarted.then(enqueue(r0,0).fail())
  run recoveryRequiresRetiredOwnerTest=committed.then(recover(true).fail())
  run unqualifiedRecoveryRejectedTest=restarted.then(recover(false).fail())
  run oldOwnerCannotApplyAfterRecoveryTest=restarted.then(recover(true)).then(applyAccount(d0,0).fail())
  run currentOwnerMayApplyOldCommittedResultTest=restarted.then(recover(true)).then(applyAccount(d0,1)).then(activate).expect(safety and joined)
  run oldOwnerCannotRestoreSnapshotTest=restarted.then(recover(true)).then(restoreSource(zero,0).fail())
  run projectionRestoreCannotRunWhileActiveTest=complete.then(restoreSource(zero,0).fail())
  run forgedSnapshotBodyRejectedTest=restarted.then(recover(true)).then(restoreSource({position:1,body:i1.with("exposure",0)},1).fail())
  run mixedSnapshotRemainsClosedTest=restarted.then(recover(true)).then(restoreSource(zero,1)).then(activate.fail())
  run exactReplayAfterProjectionRollbackTest=restarted.then(recover(true)).then(restoreSource(zero,1)).then(applySource(d0,1)).then(applyAccount(d0,1)).then(activate)
    .expect(safety and joined and s.authority.exposure==3 and s.log.length()==1)
  run replayNeverSendsAgainTest=sent.then(restart).then(recover(true)).then(restoreSource(zero,1)).then(applySource(d0,1)).then(activate).then(enqueue(r0,1).fail())
  run lateCommitObservationIsNotActivationTest=restarted.then(recover(true)).then(query(r0)).expect(safety and not(s.open) and not(joined))
  run lateObservationDoesNotReleaseUnknownTest=sourceOnly.then(loseReply).then(query(r0)).expect(safety and s.authority.exposure==3 and s.authority.spent.contains(11))
  run historyDenialBlocksNewConsumeTest=committed.then(denyHistory).then(stage(r1,0)).then(commit(r1,true).fail())
  run currentOwnerRequiredAtFinalQueueTest=complete.then(restart).then(recover(true)).then(activate).then(enqueue(r0,0).fail())
  run proposalAndReplyHaveNoSendAuthorityTest=init.then(stage(r0,0)).then(query(r0).fail())
  run unknownAccountLagCannotRefundTest=sourceOnly.then(restart).then(recover(true)).then(restoreAccount(zero,1)).expect(safety and s.authority.exposure==3 and not(joined))
  action unsafeResult=s'=s.with("log",List(d0.with("after",genesis)))
  action unsafeReconsume=s'=s.with("authority",s.authority.with("exposure",6)).with("everExposure",6)
  action unsafeDelta=s'=s.with("accountStore",{position:1,body:i1.with("exposure",6)})
  action unsafeTorn=s'=s.with("sourceStore",{position:1,body:i1.with("spent",Set())})
  action unsafeOldOwner=s'=s.with("applications",s.applications.append({result:d0,before:zero,worker:0,epoch:s.epoch}))
  action unsafeSkip=s'=s.with("applications",s.applications.append({result:d1,before:zero,worker:0,epoch:0}))
  action unsafeRefund=s'=s.with("authority",s.authority.with("exposure",0))
  action unsafeActivate=s'=s.with("open",true).with("activations",s.activations.append(joined))
  action unsafeLateSend=s'=s.with("calls",s.calls+1)
  action unsafeProfile=s'=s.with("authority",s.authority.with("profile",99))
  run resultReplacementCounterexampleTest=committed.then(loseReply).then(unsafeResult).expect(not(logBound))
  run duplicateConsumptionCounterexampleTest=committed.then(loseReply).then(unsafeReconsume).expect(not(accounting))
  run accountDeltaRetryCounterexampleTest=complete.then(loseReply).then(unsafeDelta).expect(not(projections))
  run tornSourceRowCounterexampleTest=sourceOnly.then(unsafeTorn).expect(not(projections))
  run oldOwnerApplicationCounterexampleTest=restarted.then(recover(true)).then(unsafeOldOwner).expect(not(applications))
  run skippedPrefixCounterexampleTest=pair.then(unsafeSkip).expect(not(applications))
  run unknownRefundCounterexampleTest=sourceOnly.then(unsafeRefund).expect(not(accounting))
  run mixedSnapshotActivationCounterexampleTest=restarted.then(recover(true)).then(restoreSource(zero,1)).then(unsafeActivate).expect(not(safety))
  run lateObservationResendCounterexampleTest=sent.then(loseReply).then(query(r0)).then(unsafeLateSend).expect(not(accounting))
  run profileReplacementCounterexampleTest=committed.then(unsafeProfile).expect(not(logBound))
}
