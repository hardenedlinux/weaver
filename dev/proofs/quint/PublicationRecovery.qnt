module PublicationRecovery {
  type Decision = {payload:int,parent:int,requestedFence:int,outcome:int,resultHead:int,resultFence:int}
  type Event = {id:int,decision:Decision}
  type Part={id:int,payload:int,key:int}
  type Cut={publication:List[Part],consumption:List[Part],account:List[Part],history:List[Part]}
  type Intent={id:int,payload:int,key:int,kind:int,scope:int,epoch:int,before:Cut}
  type FloorOutcome={intent:Intent,committed:bool,after:Cut,epoch:int}
  // Only this existing recovery owner models the protocol envelope. Domain
  // publication/account/effect validity remains with its existing owner.
  type Floor={epoch:int,cut:Cut,outcomes:List[FloorOutcome],pending:Set[Intent],local:Cut,
    observed:Cut,observedEpoch:int,haveRead:bool,active:bool,burned:Set[int],admitted:Set[int],handles:Set[int],tickets:Set[{key:int,cut:Cut,epoch:int}],calls:int,external:int}
  type Ledger = {head:int,fence:int,policy:int,schema:int,records:int->Decision,log:List[Event],commits:List[Event],held:int,calls:int,floor:Floor}
  var authority:Ledger
  val ids=Set(0,1,2)
  val empty={payload:0,parent:-1,requestedFence:1,outcome:0,resultHead:-1,resultFence:1}
  val safe = authority.head==authority.commits.length()-1 and authority.held==4 and authority.calls==1 and
    authority.log.indices().forall(i=>authority.records.get(authority.log.nth(i).id)==authority.log.nth(i).decision) and
    authority.commits.indices().forall(i=>authority.commits.nth(i).decision.outcome==1 and
      authority.commits.nth(i).decision.resultHead==i and authority.commits.nth(i).decision.parent==i-1) and
    (authority.head>=0 implies authority.policy==authority.commits.nth(authority.head).decision.payload and authority.schema==authority.policy) and floorSafe(authority.floor)
  pure val emptyCut={publication:List(),consumption:List(),account:List(),history:List()}
  pure val floor0={epoch:0,cut:emptyCut,outcomes:List(),pending:Set(),local:emptyCut,observed:emptyCut,observedEpoch:0,haveRead:true,active:true,burned:Set(),admitted:Set(),handles:Set(),tickets:Set(),calls:0,external:0}
  action init = authority'={head:-1,fence:1,policy:0,schema:0,records:ids.mapBy(_=>empty),log:[],commits:[],held:4,calls:1,floor:floor0}
  action publish(id:int,payload:int,parent:int,fence:int):bool = {
    val accepted=parent==authority.head and fence>=authority.fence
    val d={payload:payload,parent:parent,requestedFence:fence,outcome:if(accepted)1 else 2,
      resultHead:if(accepted)authority.head+1 else authority.head,resultFence:if(accepted)fence else authority.fence}
    val event={id:id,decision:d}
    all {authority.records.get(id).outcome==0,
      authority'=authority.with("records",authority.records.set(id,d)).with("log",authority.log.append(event))
        .with("commits",if(accepted)authority.commits.append(event) else authority.commits)
        .with("head",d.resultHead).with("fence",d.resultFence)
        .with("policy",if(accepted)payload else authority.policy).with("schema",if(accepted)payload else authority.schema)}
  }
  action replay(id:int,payload:int,parent:int,fence:int):bool = all {
    authority.records.get(id).outcome!=0,authority.records.get(id).payload==payload,authority.records.get(id).parent==parent,authority.records.get(id).requestedFence==fence,authority'=authority}
  action observe = authority'=authority
  action restart = authority'=authority
  action unsafeHeadOnly = authority'=authority.with("head",authority.head+1)
  action unsafeForget(id:int):bool = all {authority.records.get(id).outcome!=0,authority'=authority.with("records",authority.records.set(id,empty))}
  action unsafeRebind(id:int):bool = all {authority.records.get(id).outcome!=0,authority'=authority.with("records",authority.records.set(id,authority.records.get(id).with("payload",1-authority.records.get(id).payload)))}
  pure def floorPost(c:Cut,q:Intent):Cut={val p={id:q.id,payload:q.payload,key:q.key}
    if(q.kind==0)c.with("publication",c.publication.append(p)) else if(q.kind==1)c.with("consumption",c.consumption.append(p))
    else if(q.kind==2)c.with("account",c.account.append(p)) else c.with("history",c.history.append(p))}
  pure def floorGate(f:Floor,q:Intent):bool=q.scope==7 and q.epoch==f.epoch and q.before==f.cut and Set(0,1,2,3).contains(q.kind) and
    (q.kind!=1 or f.cut.consumption.indices().forall(i=>f.cut.consumption.nth(i).key!=q.key)) and
    (q.kind!=2 or (f.cut.consumption.indices().exists(i=>f.cut.consumption.nth(i).key==q.key) and f.cut.account.indices().forall(i=>f.cut.account.nth(i).key!=q.key)))
  pure def floorSafe(f:Floor):bool={val committed=f.outcomes.foldl(List(),(acc,d)=>if(d.committed)acc.append(d) else acc)
    f.cut==(if(committed.length()==0)emptyCut else committed.nth(committed.length()-1).after) and
    f.outcomes.indices().forall(i=>f.outcomes.indices().forall(j=>i==j or f.outcomes.nth(i).intent.id!=f.outcomes.nth(j).intent.id)) and
    committed.indices().forall(i=>{val d=committed.nth(i)
      d.intent.scope==7 and d.intent.epoch==d.epoch and d.intent.before==(if(i==0)emptyCut else committed.nth(i-1).after) and d.after==floorPost(d.intent.before,d.intent)}) and
    (f.active implies f.haveRead and f.local==f.cut and f.observed==f.cut and f.observedEpoch==f.epoch and f.pending==Set()) and
    f.calls==f.external and f.calls==f.admitted.size() and f.admitted.forall(k=>f.burned.contains(k)) and f.burned.forall(k=>f.cut.consumption.indices().exists(i=>f.cut.consumption.nth(i).key==k))}
  def f=authority.floor
  pure val consume0={id:10,payload:100,key:1,kind:1,scope:7,epoch:0,before:emptyCut}
  pure val publication0=consume0.with("id",11).with("kind",0).with("payload",101)
  pure val account0=consume0.with("id",12).with("kind",2).with("payload",102).with("before",floorPost(emptyCut,consume0))
  pure val history0=consume0.with("id",13).with("kind",3).with("payload",103).with("before",floorPost(account0.before,account0))
  action floorStage(q:Intent):bool=all {f.pending.forall(p=>p.id!=q.id or p==q),
    authority'=authority.with("floor",f.with("pending",f.pending.union(Set(q))).with("active",false))}
  // Final epoch/cut/domain checks and immutable result are one authority step.
  // qualified is supplied by authenticated domain validation, never client data.
  action floorCommit(q:Intent,qualified:bool):bool=all {f.pending.contains(q),f.outcomes.indices().forall(i=>f.outcomes.nth(i).intent.id!=q.id),
    val ok=floorGate(f,q) and qualified
    val post=if(ok)floorPost(f.cut,q) else f.cut
    authority'=authority.with("floor",f.with("cut",post).with("outcomes",f.outcomes.append({intent:q,committed:ok,after:post,epoch:f.epoch})).with("active",false))}
  action floorReplay(q:Intent):bool=all {f.outcomes.indices().exists(i=>f.outcomes.nth(i).intent==q),authority'=authority}
  action floorResolve(q:Intent):bool=all {f.outcomes.indices().exists(i=>f.outcomes.nth(i).intent==q),authority'=authority.with("floor",f.with("pending",f.pending.exclude(Set(q))))}
  action floorRead=authority'=authority.with("floor",f.with("observed",f.cut).with("observedEpoch",f.epoch).with("haveRead",true))
  action floorAbsent=authority'=authority
  action floorLoseReply=authority'=authority.with("floor",f.with("haveRead",false).with("active",false).with("handles",Set()))
  action floorRotate=authority'=authority.with("floor",f.with("epoch",f.epoch+1).with("haveRead",false).with("active",false).with("handles",Set()))
  action floorRestore(c:Cut):bool=authority'=authority.with("floor",f.with("local",c).with("haveRead",false).with("active",false).with("handles",Set()))
  action floorRepair=all {f.haveRead,f.observed==f.cut,f.observedEpoch==f.epoch,
    authority'=authority.with("floor",f.with("local",f.cut).with("active",false))}
  action floorActivate=all {f.haveRead,f.observed==f.cut,f.observedEpoch==f.epoch,f.local==f.cut,f.pending==Set(),
    authority'=authority.with("floor",f.with("active",true))}
  // Durable burn precedes actual admission; a crash/fence between may omit the
  // call forever. Only this sole transport owner retains a pending burn handle.
  action floorBurn(k:int,c:Cut,epoch:int):bool=all {f.active,c==f.cut,epoch==f.epoch,f.cut.consumption.indices().exists(i=>f.cut.consumption.nth(i).key==k),not(f.burned.contains(k)),
    authority'=authority.with("floor",f.with("burned",f.burned.union(Set(k))).with("handles",f.handles.union(Set(k))).with("tickets",f.tickets.union(Set({key:k,cut:c,epoch:epoch}))))}
  action floorAdmit(k:int,c:Cut,epoch:int):bool=all {f.active,c==f.cut,epoch==f.epoch,f.burned.contains(k),f.handles.contains(k),f.tickets.contains({key:k,cut:c,epoch:epoch}),not(f.admitted.contains(k)),
    authority'=authority.with("floor",f.with("handles",f.handles.exclude(Set(k))).with("admitted",f.admitted.union(Set(k))).with("calls",f.calls+1).with("external",f.external+1))}
  action floorSend(k:int,c:Cut,epoch:int):bool=floorBurn(k,c,epoch).then(floorAdmit(k,c,epoch))
  action unsafeFloorLocalActivation=authority'=authority.with("floor",f.with("active",true))
  action unsafeFloorForgetBurn=authority'=authority.with("floor",f.with("burned",Set()).with("calls",0))
  action step = {nondet id=ids.oneOf() nondet payload=Set(0,1).oneOf() nondet parent=Set(-1,0,1,2).oneOf() nondet fence=Set(1,2,3).oneOf()
    nondet kind=Set(0,1,2,3).oneOf()
    nondet scope=Set(7,8).oneOf()
    val q={id:id+10,payload:payload,key:1,kind:kind,scope:scope,epoch:f.epoch,before:f.cut}
    nondet waiting=f.pending.union(Set(q)).oneOf()
    any {publish(id,payload,parent,fence),replay(id,payload,parent,fence),observe,restart,floorStage(q),floorCommit(waiting,true),floorCommit(waiting,false),floorReplay(waiting),floorResolve(waiting),
      floorRead,floorLoseReply,floorRotate,floorRestore(emptyCut),floorRepair,floorActivate,floorBurn(1,f.cut,f.epoch),floorAdmit(1,f.cut,f.epoch)}}
  action first = init.then(publish(0,0,-1,1))
  run lostReplyRestartReplayTest = first.then(observe).then(restart).then(replay(0,0,-1,1)).expect(safe and authority.head==0)
  run concurrentParentHasOneWinnerTest = first.then(publish(1,1,-1,2)).expect(safe and authority.records.get(1).outcome==2 and authority.head==0)
  run lateReceiptIsHistoricalTest = first.then(publish(2,1,0,2)).then(observe).expect(safe and authority.records.get(0).resultHead==0 and authority.head==1)
  run changedParentCannotReuseIdTest = first.then(replay(0,0,0,1).fail())
  run changedSchemaCannotReuseIdTest = first.then(replay(0,1,-1,1).fail())
  run rejectedDecisionCannotRebaseTest = first.then(publish(1,1,-1,2)).then(publish(2,1,0,2)).then(replay(1,1,-1,2)).expect(safe and authority.records.get(1).resultHead==0)
  run absenceDoesNotAbortLateCommitTest = init.then(observe).then(publish(0,0,-1,1)).expect(safe)
  run headWithoutOutcomeCounterexampleTest = first.then(unsafeHeadOnly).expect(not(safe))
  run deletedOutcomeCounterexampleTest = first.then(unsafeForget(0)).expect(not(safe))
  run reboundOutcomeCounterexampleTest = first.then(unsafeRebind(0)).expect(not(safe))
  action floorConsumed=init.then(floorStage(consume0)).then(floorCommit(consume0,true))
  action floorReady=floorConsumed.then(floorResolve(consume0)).then(floorRead).then(floorRepair).then(floorActivate)
  run floorDurableCommitBeforeLostReplyTest=floorConsumed.then(floorLoseReply).then(floorRestore(emptyCut)).then(floorReplay(consume0)).expect(safe and f.cut.consumption.length()==1 and authority.held==4)
  run floorMissingOutcomeCannotActivateTest=init.then(floorStage(consume0)).then(floorAbsent).expect(safe).then(floorActivate.fail())
  run floorLateCommitAfterAbsentReadTest=init.then(floorStage(consume0)).then(floorAbsent).then(floorCommit(consume0,true)).expect(safe)
  run floorFencedRejectionStopsLateCommitTest=init.then(floorStage(consume0)).then(floorRotate).then(floorCommit(consume0,true)).then(floorReplay(consume0)).expect(safe and f.cut==emptyCut and not(f.outcomes.nth(0).committed))
  run floorOldEpochCannotSendTest=floorReady.then(floorRotate).expect(safe).then(floorBurn(1,floorPost(emptyCut,consume0),0).fail())
  run floorEqualLengthWrongBodyCannotActivateTest=floorReady.then(floorRestore(floorPost(emptyCut,consume0.with("payload",999)))).then(floorRead).expect(safe).then(floorActivate.fail())
  run floorNewIdCannotRepeatClaimTest=floorReady.then(floorStage(consume0.with("id",20).with("before",floorPost(emptyCut,consume0))))
    .then(floorCommit(consume0.with("id",20).with("before",floorPost(emptyCut,consume0)),true)).expect(safe and f.cut.consumption.length()==1)
  pure val finalPublication=publication0.with("before",floorPost(history0.before,history0))
  run floorFourPrefixesRecoverTogetherTest=floorConsumed.then(floorStage(account0)).then(floorCommit(account0,true)).then(floorStage(history0)).then(floorCommit(history0,true))
    .then(floorStage(finalPublication)).then(floorCommit(finalPublication,true)).then(floorRestore(emptyCut))
    .then(floorResolve(consume0)).then(floorResolve(account0)).then(floorResolve(history0)).then(floorResolve(finalPublication)).then(floorRead).then(floorRepair).then(floorActivate)
    .expect(safe and f.cut.publication.length()==1 and f.cut.account.length()==1 and f.cut.history.length()==1 and f.cut.consumption.length()==1)
  run floorStaleParentCannotBeRebasedTest=init.then(floorStage(publication0)).then(floorStage(consume0)).then(floorCommit(publication0,true)).then(floorCommit(consume0,true))
    .expect(safe and f.cut.publication.length()==1 and f.cut.consumption.length()==0)
  run floorSendCannotRepeatAcrossLocalRestoreTest=floorReady.then(floorSend(1,floorPost(emptyCut,consume0),0)).then(floorRestore(emptyCut)).then(floorRead).then(floorRepair).then(floorActivate)
    .expect(safe and f.external==1).then(floorBurn(1,floorPost(emptyCut,consume0),0).fail())
  run floorLocalOnlyActivationCounterexampleTest=floorConsumed.then(floorRestore(emptyCut)).then(unsafeFloorLocalActivation).expect(not(safe))
  run floorAuthorityRollbackCounterexampleTest=floorReady.then(floorSend(1,floorPost(emptyCut,consume0),0)).then(unsafeFloorForgetBurn).expect(not(safe))
  run floorFenceAfterBurnRetainsUnknownTest=floorReady.then(floorBurn(1,floorPost(emptyCut,consume0),0)).then(floorRotate)
    .expect(safe and f.burned.contains(1) and f.external==0 and authority.held==4).then(floorAdmit(1,floorPost(emptyCut,consume0),0).fail())
  run floorRestartAfterBurnCannotReissueHandleTest=floorReady.then(floorBurn(1,floorPost(emptyCut,consume0),0)).then(floorLoseReply)
    .then(floorRead).then(floorRepair).then(floorActivate).expect(safe and f.external==0 and f.burned.contains(1))
    .then(floorAdmit(1,floorPost(emptyCut,consume0),0).fail())
  pure val wrongScope=consume0.with("scope",8)
  run floorWrongOriginalScopeCannotCommitTest=init.then(floorStage(wrongScope)).then(floorCommit(wrongScope,true))
    .expect(safe and f.cut==emptyCut and not(f.outcomes.nth(0).committed))
}
