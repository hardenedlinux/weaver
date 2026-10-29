module RuntimeAdmission {
    // Abstract native deciding transactions; bounded to two original logical nodes.
    type State = { queued:Set[int], spent:Set[int], calls:int->int,
        holds:int->int, revision:int, fence:int, qRevision:int->int, qFence:int->int,
        tickets:Set[int], lock:bool, lockKey:int, staleSend:bool }
    var s:State
    val logicalKeys=Set(0,1)
    val held=s.holds.get(0)+s.holds.get(1)
    val safety=not(s.staleSend) and held<=10 and logicalKeys.forall(k=>s.calls.get(k)<=1 and
        (s.spent.contains(k) implies s.holds.get(k)>0) and
        (s.calls.get(k)>0 implies s.spent.contains(k)))
    action init=s'={queued:Set(),spent:Set(),calls:Map(0->0,1->0),holds:Map(0->0,1->0),
        revision:0,fence:1,qRevision:Map(0->0,1->0),qFence:Map(0->1,1->1),tickets:Set(),lock:false,lockKey: -1,staleSend:false}
    action queue(k:int,n:int,original:bool):bool=all {
        original, logicalKeys.contains(k),not(s.queued.contains(k)),n>=3,held+n<=10,
        s'=s.with("queued",s.queued.union(Set(k))).with("holds",s.holds.set(k,n))
            .with("qRevision",s.qRevision.set(k,s.revision)).with("qFence",s.qFence.set(k,s.fence))
    }
    action consume(k:int):bool=all {
        s.queued.contains(k),not(s.spent.contains(k)),s.qRevision.get(k)==s.revision,s.qFence.get(k)==s.fence,
        s'=s.with("spent",s.spent.union(Set(k))).with("tickets",s.tickets.union(Set(k)))
    }
    action publish=all {not(s.lock),s'=s.with("revision",s.revision+1).with("fence",s.fence+1)}
    action finalGuard(k:int):bool=all {
        not(s.lock),s.tickets.contains(k),s.qRevision.get(k)==s.revision,s.qFence.get(k)==s.fence,
        s'=s.with("lock",true).with("lockKey",k)
    }
    action send(k:int):bool=all {
        s.lock,s.lockKey==k,s.tickets.contains(k),s.qRevision.get(k)==s.revision,s.qFence.get(k)==s.fence,
        s.calls.get(k)==0,
        s'=s.with("calls",s.calls.set(k,1)).with("tickets",s.tickets.exclude(Set(k))).with("lock",false)
    }
    action crash= s'=s.with("tickets",Set()).with("lock",false)
    action lostReply=s'=s
    action unsafeRetry(k:int):bool=s'=s.with("calls",s.calls.set(k,s.calls.get(k)+1))
    action unsafeRefund(k:int):bool=s'=s.with("holds",s.holds.set(k,0))
    action unsafeCachedGuard(k:int):bool=s'=s.with("calls",s.calls.set(k,s.calls.get(k)+1)).with("staleSend",s.qRevision.get(k)!=s.revision or s.qFence.get(k)!=s.fence)
    action step={
        nondet k=logicalKeys.oneOf()
        any {queue(k,6,true),consume(k),publish,finalGuard(k),send(k),crash,lostReply}
    }
    action queued=init.then(queue(0,6,true))
    action consumed=queued.then(consume(0))
    action sent=consumed.then(finalGuard(0)).then(send(0))
    run originalBindingTest=init.then(queue(0,6,false).fail())
    run originalCostBoundTest=init.then(queue(0,1,true).fail())
    run sharedBudgetTest=queued.expect(safety and held==6).then(queue(1,6,true).fail())
    run enqueueNeverSendsTest=queued.expect(s.calls.get(0)==0 and safety)
    run consumeBeforeSendTest=queued.then(send(0).fail())
    run onceOnlyTest=sent.expect(safety).then(consume(0).fail())
    run restartRetainsSpentTest=consumed.then(crash).expect(safety and held==6).then(consume(0).fail())
    run lostReplyRetainsHoldTest=sent.then(lostReply).expect(safety and held==6)
    run stalePermitTest=consumed.then(publish).expect(safety).then(finalGuard(0).fail())
    run guardSerializesPublicationTest=consumed.then(finalGuard(0)).then(publish.fail())
    run duplicateRetryCounterexampleTest=sent.then(unsafeRetry(0)).expect(not(safety))
    run unknownRefundCounterexampleTest=consumed.then(crash).then(unsafeRefund(0)).expect(not(safety))
    run cachedGuardCounterexampleTest=consumed.then(publish).then(unsafeCachedGuard(0)).expect(not(safety))
}
