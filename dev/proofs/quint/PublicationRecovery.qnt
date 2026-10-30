module PublicationRecovery {
  type Decision = {payload:int,parent:int,requestedFence:int,outcome:int,resultHead:int,resultFence:int}
  type Event = {id:int,decision:Decision}
  type Ledger = {head:int,fence:int,policy:int,schema:int,records:int->Decision,log:List[Event],commits:List[Event],held:int,calls:int}
  var authority:Ledger
  val ids=Set(0,1,2)
  val empty={payload:0,parent:-1,requestedFence:1,outcome:0,resultHead:-1,resultFence:1}
  val safe = authority.head==authority.commits.length()-1 and authority.held==4 and authority.calls==1 and
    authority.log.indices().forall(i=>authority.records.get(authority.log.nth(i).id)==authority.log.nth(i).decision) and
    authority.commits.indices().forall(i=>authority.commits.nth(i).decision.outcome==1 and
      authority.commits.nth(i).decision.resultHead==i and authority.commits.nth(i).decision.parent==i-1) and
    (authority.head>=0 implies authority.policy==authority.commits.nth(authority.head).decision.payload and authority.schema==authority.policy)
  action init = authority'={head:-1,fence:1,policy:0,schema:0,records:ids.mapBy(_=>empty),log:[],commits:[],held:4,calls:1}
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
  action step = {nondet id=ids.oneOf() nondet payload=Set(0,1).oneOf() nondet parent=Set(-1,0,1,2).oneOf() nondet fence=Set(1,2,3).oneOf()
    any {publish(id,payload,parent,fence),replay(id,payload,parent,fence),observe,restart}}
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
}
