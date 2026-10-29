module PublicationRecovery {
  type Decision = {payload:int,parent:int,requestedFence:int,outcome:int,resultHead:int,resultFence:int}
  type Event = {id:int,decision:Decision}
  type Ledger = {head:int,fence:int,policy:int,schema:int,records:int->Decision,log:List[Event],commits:List[Event],held:int,calls:int}
  var s:Ledger
  val ids=Set(0,1,2)
  val empty={payload:0,parent:-1,requestedFence:1,outcome:0,resultHead:-1,resultFence:1}
  val safe = s.head==s.commits.length()-1 and s.held==4 and s.calls==1 and
    s.log.indices().forall(i=>s.records.get(s.log.nth(i).id)==s.log.nth(i).decision) and
    s.commits.indices().forall(i=>s.commits.nth(i).decision.outcome==1 and
      s.commits.nth(i).decision.resultHead==i and s.commits.nth(i).decision.parent==i-1) and
    (s.head>=0 implies s.policy==s.commits.nth(s.head).decision.payload and s.schema==s.policy)
  action init = s'={head:-1,fence:1,policy:0,schema:0,records:ids.mapBy(_=>empty),log:[],commits:[],held:4,calls:1}
  action publish(id:int,payload:int,parent:int,fence:int):bool = {
    val accepted=parent==s.head and fence>=s.fence
    val d={payload:payload,parent:parent,requestedFence:fence,outcome:if(accepted)1 else 2,
      resultHead:if(accepted)s.head+1 else s.head,resultFence:if(accepted)fence else s.fence}
    val event={id:id,decision:d}
    all {s.records.get(id).outcome==0,
      s'=s.with("records",s.records.set(id,d)).with("log",s.log.append(event))
        .with("commits",if(accepted)s.commits.append(event) else s.commits)
        .with("head",d.resultHead).with("fence",d.resultFence)
        .with("policy",if(accepted)payload else s.policy).with("schema",if(accepted)payload else s.schema)}
  }
  action replay(id:int,payload:int,parent:int,fence:int):bool = all {
    s.records.get(id).outcome!=0,s.records.get(id).payload==payload,s.records.get(id).parent==parent,s.records.get(id).requestedFence==fence,s'=s}
  action observe = s'=s
  action restart = s'=s
  action unsafeHeadOnly = s'=s.with("head",s.head+1)
  action unsafeForget(id:int):bool = all {s.records.get(id).outcome!=0,s'=s.with("records",s.records.set(id,empty))}
  action unsafeRebind(id:int):bool = all {s.records.get(id).outcome!=0,s'=s.with("records",s.records.set(id,s.records.get(id).with("payload",1-s.records.get(id).payload)))}
  action step = {nondet id=ids.oneOf() nondet payload=Set(0,1).oneOf() nondet parent=Set(-1,0,1,2).oneOf() nondet fence=Set(1,2,3).oneOf()
    any {publish(id,payload,parent,fence),replay(id,payload,parent,fence),observe,restart}}
  action first = init.then(publish(0,0,-1,1))
  run lostReplyRestartReplayTest = first.then(observe).then(restart).then(replay(0,0,-1,1)).expect(safe and s.head==0)
  run concurrentParentHasOneWinnerTest = first.then(publish(1,1,-1,2)).expect(safe and s.records.get(1).outcome==2 and s.head==0)
  run lateReceiptIsHistoricalTest = first.then(publish(2,1,0,2)).then(observe).expect(safe and s.records.get(0).resultHead==0 and s.head==1)
  run changedParentCannotReuseIdTest = first.then(replay(0,0,0,1).fail())
  run changedSchemaCannotReuseIdTest = first.then(replay(0,1,-1,1).fail())
  run rejectedDecisionCannotRebaseTest = first.then(publish(1,1,-1,2)).then(publish(2,1,0,2)).then(replay(1,1,-1,2)).expect(safe and s.records.get(1).resultHead==0)
  run absenceDoesNotAbortLateCommitTest = init.then(observe).then(publish(0,0,-1,1)).expect(safe)
  run headWithoutOutcomeCounterexampleTest = first.then(unsafeHeadOnly).expect(not(safe))
  run deletedOutcomeCounterexampleTest = first.then(unsafeForget(0)).expect(not(safe))
  run reboundOutcomeCounterexampleTest = first.then(unsafeRebind(0)).expect(not(safe))
}
