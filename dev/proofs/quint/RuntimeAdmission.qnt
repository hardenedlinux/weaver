module RuntimeAdmission {
    // Abstract native deciding transactions; bounded to two original logical nodes.
    type State = { queued:Set[int], retained:Set[int], spent:Set[int], calls:int->int, digests:int->int,
        holds:int->int, originals:int->int, revision:int, fence:int, qRevision:int->int, qFence:int->int,
        tickets:Set[int], lock:bool, lockKey:int, staleSend:bool }
    var s:State
    val logicalKeys=Set(0,1)
    val held=s.holds.get(0)+s.holds.get(1)
    // Row-local amounts cannot establish that every durable claim still has a row.
    val originalBindings=s.retained.forall(k=>s.holds.get(k)==s.originals.get(k))
    val claimCoverage=s.queued.subseteq(s.retained)
    // Frozen original digest identity, separate from the mutable outcome image.
    val memberBindings=s.retained.forall(k=>s.digests.get(k)==k)
    // Two members intentionally share one stream owner. Node-level coverage is
    // weaker than the exact retained manifest, even with balanced row amounts.
    val ownerOf=Map(0->0,1->0)
    val nodeCoverage=s.queued.forall(k=>s.retained.exists(r=>ownerOf.get(k)==ownerOf.get(r)))
    val originalHeld=s.originals.get(0)+s.originals.get(1)
    val aggregateSafety=not(s.staleSend) and held<=10 and logicalKeys.forall(k=>s.calls.get(k)<=1 and
        (s.spent.contains(k) implies s.holds.get(k)>0) and
        (s.calls.get(k)>0 implies s.spent.contains(k)))
    val safety=aggregateSafety and originalBindings and claimCoverage and memberBindings
    val initial:State={queued:Set(),retained:Set(),spent:Set(),calls:Map(0->0,1->0),digests:Map(0->0,1->1),holds:Map(0->0,1->0),originals:Map(0->0,1->0),
        revision:0,fence:1,qRevision:Map(0->0,1->0),qFence:Map(0->1,1->1),tickets:Set(),lock:false,lockKey: -1,staleSend:false}
    action init=s'=initial
    action queue(k:int,n:int,original:bool):bool=all {
        claimCoverage, memberBindings, originalBindings, original, logicalKeys.contains(k),not(s.queued.contains(k)),n>=3,held+n<=10,
        s'=s.with("queued",s.queued.union(Set(k))).with("retained",s.retained.union(Set(k))).with("holds",s.holds.set(k,n)).with("originals",s.originals.set(k,n))
            .with("qRevision",s.qRevision.set(k,s.revision)).with("qFence",s.qFence.set(k,s.fence))
    }
    action consume(k:int):bool=all {
        claimCoverage, memberBindings, originalBindings,
        s.queued.contains(k),not(s.spent.contains(k)),s.qRevision.get(k)==s.revision,s.qFence.get(k)==s.fence,
        s'=s.with("spent",s.spent.union(Set(k))).with("tickets",s.tickets.union(Set(k)))
    }
    action publish=all {not(s.lock),s'=s.with("revision",s.revision+1).with("fence",s.fence+1)}
    action finalGuard(k:int):bool=all {
        claimCoverage, memberBindings, originalBindings,
        not(s.lock),s.tickets.contains(k),s.qRevision.get(k)==s.revision,s.qFence.get(k)==s.fence,
        s'=s.with("lock",true).with("lockKey",k)
    }
    action send(k:int):bool=all {
        claimCoverage, memberBindings, originalBindings,
        s.lock,s.lockKey==k,s.tickets.contains(k),s.qRevision.get(k)==s.revision,s.qFence.get(k)==s.fence,
        s.calls.get(k)==0,
        s'=s.with("calls",s.calls.set(k,1)).with("tickets",s.tickets.exclude(Set(k))).with("lock",false)
    }
    action crash= s'=s.with("tickets",Set()).with("lock",false)
    action lostReply=s'=s
    action unsafeRetry(k:int):bool=s'=s.with("calls",s.calls.set(k,s.calls.get(k)+1))
    action unsafeRefund(k:int):bool=s'=s.with("holds",s.holds.set(k,0))
    action unsafeCachedGuard(k:int):bool=s'=s.with("calls",s.calls.set(k,s.calls.get(k)+1)).with("staleSend",s.qRevision.get(k)!=s.revision or s.qFence.get(k)!=s.fence)
    // Fault injection preserves the apparent aggregate, but loses original exposure.
    action unsafeBalancedShrink(k:int):bool=s'=s.with("holds",s.holds.set(k,1))
    action unsafeDropRow(k:int):bool=s'=s.with("retained",s.retained.exclude(Set(k))).with("holds",s.holds.set(k,0))
    action unsafeSubstituteDigest(k:int):bool=s'=s.with("digests",s.digests.set(k,k+2))
    // Fault model for a caller presenting newly observed authority. This is not
    // a recovery capability and is deliberately excluded from the safe step.
    action unsafeFreshAuthorityObservation(k:int):bool=s'=s.with("qRevision",s.qRevision.set(k,s.revision))
        .with("qFence",s.qFence.set(k,s.fence))
    action unsafeAggregateQueue(k:int,n:int):bool=all {
        not(s.queued.contains(k)),held+n<=10,
        s'=s.with("queued",s.queued.union(Set(k))).with("retained",s.retained.union(Set(k))).with("holds",s.holds.set(k,n)).with("originals",s.originals.set(k,n))
    }
    run orphanedClaimCounterexampleTest=consumed.then(unsafeDropRow(0))
        .expect(originalBindings and held==0 and not(claimCoverage))
        .then(unsafeAggregateQueue(1,6)).expect(originalHeld>10 and not(safety))
    run orphanedClaimRecoveryGuardTest=consumed.then(unsafeDropRow(0)).then(crash)
        .expect(s.queued.contains(0) and originalHeld==6)
        .then(queue(1,6,true).fail())
    run orphanedClaimConsumeGuardTest=consumed.then(unsafeDropRow(0)).then(crash)
        .then(consume(0).fail())
    run orphanedClaimFinalUseTest=consumed.then(finalGuard(0))
        .then(unsafeDropRow(0)).then(send(0).fail())
    action sameStream=init.then(queue(0,4,true)).then(queue(1,4,true)).then(consume(0))
    run partialMessageLossCounterexampleTest=sameStream.then(unsafeDropRow(0))
        .expect(nodeCoverage and originalBindings and held==4 and not(claimCoverage))
    run partialMessageRecoveryGuardTest=sameStream.then(unsafeDropRow(0)).then(crash)
        .expect(nodeCoverage and not(claimCoverage)).then(consume(1).fail())
    run partialMessageFinalUseGuardTest=sameStream.then(finalGuard(0)).then(unsafeDropRow(1))
        .expect(nodeCoverage and originalBindings).then(send(0).fail())
    run partialLossFreshAuthorityRecoveryGuardTest=sameStream.then(unsafeDropRow(0)).then(crash)
        .then(publish).then(unsafeFreshAuthorityObservation(1))
        .expect(s.retained.contains(1) and not(s.spent.contains(1)) and s.qFence.get(1)==s.fence and not(claimCoverage))
        .then(consume(1).fail())
    run partialLossFreshAuthorityFinalUseGuardTest=sameStream.then(unsafeDropRow(1))
        .then(publish).then(unsafeFreshAuthorityObservation(0))
        .expect(s.tickets.contains(0) and s.qFence.get(0)==s.fence and not(claimCoverage))
        .then(finalGuard(0).fail())
    run digestSubstitutionCounterexampleTest=sameStream.then(unsafeSubstituteDigest(1))
        .expect(nodeCoverage and claimCoverage and originalBindings and not(memberBindings))
    run digestSubstitutionFinalUseGuardTest=sameStream.then(finalGuard(0)).then(unsafeSubstituteDigest(1))
        .then(send(0).fail())
    run balancedProjectionCounterexampleTest=consumed.then(unsafeBalancedShrink(0))
        .expect(aggregateSafety and not(originalBindings)).then(unsafeAggregateQueue(1,6))
        .expect(aggregateSafety and originalHeld>10 and not(safety))
    run originalReservationGuardTest=consumed.then(unsafeBalancedShrink(0)).then(crash)
        .expect(held==1 and originalHeld==6).then(queue(1,6,true).fail())
    run originalReservationFinalUseTest=consumed.then(finalGuard(0))
        .then(unsafeBalancedShrink(0)).then(send(0).fail())
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
