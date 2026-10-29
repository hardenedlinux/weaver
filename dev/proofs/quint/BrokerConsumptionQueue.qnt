// Post-admission software queue refinement; no provider exactly-once assumption.
module BrokerConsumptionQueue {
  import GatewayHeadCAS as H from "./GatewayHeadCAS"
  type Range = {lo:int,hi:int,epoch:int}
  type Queue = {scope:H::Head,recovered:bool,spent:bool,intent:bool,accepted:bool,ack:bool,epoch:int,allowed:bool,
    frontier:int,pending:Range,hasPending:bool,calls:int->int,ranges:Set[Range],full:Set[Range],unknown:bool,
    completed:bool,usage:bool,settled:bool,settlements:int}
  var q:Queue
  pure val payloadLength = 4
  pure val noRange = {lo:-1,hi:-1,epoch:-1}
  pure val initial = {scope:H::emptyHead,recovered:true,spent:false,intent:false,accepted:false,ack:false,epoch:0,allowed:true,
    frontier:0,pending:noRange,hasPending:false,calls:0.to(4).mapBy(_ => 0),ranges:Set(),full:Set(),unknown:false,
    completed:false,usage:false,settled:false,settlements:0}
  action init = all {H::ready,q' = initial}
  action holdParent = H::reconnect
  // The durable spent record corresponds to the parent's one logical offer.
  // No queue action may invoke H::send a second time.
  action consume = all {not(q.spent),H::send(H::decidedJob,0,0,8,0,10),q' = q.with("spent",true).with("scope",H::g.head)}
  action persistIntent = all {q.spent,holdParent,q' = q.with("intent",true)}
  action accept = all {q.spent,q.intent,holdParent,q' = q.with("accepted",true)}
  action acknowledge = all {q.accepted,holdParent,q' = q.with("ack",true)}
  action loseReply = all {holdParent,q' = q.with("ack",false)}
  action restart = all {H::restartBroker,q' = q.with("epoch",q.epoch+1).with("ack",false).with("recovered",false)}
  action recover(authentic) = all {authentic,q.spent,q.epoch == H::g.worker,holdParent,q' = q.with("recovered",true)}
  action changeRoute = all {H::changeHead(0,1,0,H::g.worker),q' = q}
  action revoke = all {H::restrict(0),q' = q.with("allowed",false)}
  action reauthorize = all {holdParent,q' = q.with("allowed",true)}
  action reserveWrite(n) = {
    val r = {lo:q.frontier,hi:q.frontier+n,epoch:q.epoch}
    all {q.accepted,q.recovered,q.allowed,H::g.head == q.scope,H::livePolicy(q.scope),not(q.settled),not(q.unknown),not(q.hasPending),n>0,q.frontier+n<=payloadLength,
      holdParent,q' = q.with("frontier",r.hi).with("pending",r).with("hasPending",true).with("ranges",q.ranges.union(Set(r)))}
  }
  action invoke(r,worker) = all {q.hasPending,q.pending == r,r.epoch == q.epoch,worker == q.epoch,
    q.recovered,q.allowed,H::g.head == q.scope,H::livePolicy(q.scope),q.epoch == H::g.worker,not(q.settled),not(q.unknown),q.calls.get(r.lo) == 0,holdParent,
    q' = q.with("calls",q.calls.set(r.lo,1)).with("unknown",true)}
  action fullReceipt(r,authentic) = all {authentic,q.hasPending,q.pending == r,q.calls.get(r.lo) == 1,not(q.settled),
    holdParent,q' = q.with("hasPending",false).with("pending",noRange).with("unknown",false).with("full",q.full.union(Set(r)))}
  action partialOrTimeout = all {holdParent,q' = q}
  action terminal(authentic) = all {authentic,q.accepted,q.frontier == payloadLength,not(q.hasPending),not(q.unknown),
    holdParent,q' = q.with("completed",true)}
  action finalUsage(authentic) = all {authentic,q.completed,holdParent,q' = q.with("usage",true)}
  action settle = all {q.completed,q.usage,not(q.unknown),not(q.hasPending),not(q.settled),q.settlements == 0,
    holdParent,q' = q.with("settled",true).with("settlements",q.settlements+1)}
  val callOnce = q.calls.keys().forall(i => q.calls.get(i)<=1)
  val bounded = q.frontier>=0 and q.frontier<=payloadLength and q.ranges.forall(r => r.lo<r.hi and r.hi<=q.frontier)
  val separated = q.ranges.forall(a => q.ranges.forall(b => a!=b implies a.hi<=b.lo or b.hi<=a.lo))
  val acceptanceBound = q.accepted implies q.intent and q.spent
  val unknownHeld = q.unknown implies not(q.settled)
  val settlementBound = q.settled implies q.completed and q.usage and not(q.unknown) and not(q.hasPending)
  val evidenceBound = q.settled implies q.ranges.subseteq(q.full)
  val authorityBound = q.spent implies H::g.sends.size() == 1
  val safety = H::safety and callOnce and bounded and separated and acceptanceBound and unknownHeld and settlementBound and authorityBound and evidenceBound and q.settlements<=1
  action step = {
    nondet n = 1.to(4).oneOf()
    nondet w = Set(q.epoch,q.epoch-1).oneOf()
    any {consume,persistIntent,accept,acknowledge,loseReply,restart,recover(true),changeRoute,revoke,reauthorize,
      reserveWrite(n),invoke(q.pending,w),fullReceipt(q.pending,true),partialOrTimeout,terminal(true),finalUsage(true),settle}
  }
  action consumed = init.then(consume)
  action intended = consumed.then(persistIntent)
  action queued = intended.then(accept)
  action reserved = queued.then(reserveWrite(2))
  action uncertain = reserved.then(invoke(q.pending,q.epoch))
  action firstDone = uncertain.then(fullReceipt(q.pending,true))
  action complete = firstDone.then(reserveWrite(2)).then(invoke(q.pending,q.epoch)).then(fullReceipt(q.pending,true)).then(terminal(true)).then(finalUsage(true))
  run normalCompletionTest = complete.then(settle).expect(safety and q.settlements == 1)
  run lostConsumeReplyTest = consumed.then(loseReply).then(persistIntent).then(accept).expect(safety and q.spent)
  run duplicateConsumptionRejectedTest = consumed.then(consume.fail())
  run crashBeforeEnqueueTest = consumed.then(restart).then(persistIntent).then(accept).expect(safety and q.accepted)
  run missingIntentCannotEnqueueTest = consumed.then(accept.fail())
  run crashAfterEnqueueTest = queued.then(restart).then(accept).then(acknowledge).expect(safety and q.accepted)
  run lostQueueReplyTest = queued.then(loseReply).then(accept).then(reserveWrite(2)).expect(safety and q.ranges.size()==1)
  run sdkRetryCannotInvokeAgainTest = uncertain.then(invoke(q.pending,q.epoch).fail())
  run oldWorkerCannotInvokeTest = reserved.then(restart).then(recover(true)).then(invoke(q.pending,q.epoch-1).fail())
  run newWorkerCannotRelabelRangeTest = reserved.then(restart).then(recover(true)).then(invoke(q.pending,q.epoch).fail())
  run routeChangeBeforeInvokeTest = reserved.then(changeRoute).then(invoke(q.pending,q.epoch).fail())
  run revocationBeforeInvokeTest = reserved.then(revoke).then(invoke(q.pending,q.epoch).fail())
  run localReallowCannotUndoHistoryRestrictionTest = reserved.then(revoke).then(reauthorize).then(invoke(q.pending,q.epoch).fail())
  run crashBeforeCallCannotAllocateTailTest = reserved.then(restart).then(reserveWrite(2).fail())
  run restartRequiresPrefixRecoveryTest = firstDone.then(restart).then(reserveWrite(2).fail())
  run verifiedRecoveryContinuesSuffixTest = firstDone.then(restart).then(recover(true)).then(reserveWrite(2)).then(invoke(q.pending,q.epoch)).expect(safety and q.unknown)
  run forgedRecoveryRejectedTest = firstDone.then(restart).then(recover(false).fail())
  run partialWriteKeepsHoldTest = uncertain.then(partialOrTimeout).then(restart).expect(safety and q.unknown and not(q.settled))
  run partialWriteCannotReplayTest = uncertain.then(partialOrTimeout).then(reserveWrite(2).fail())
  run timeoutCannotSettleTest = uncertain.then(partialOrTimeout).then(settle.fail())
  run forgedReceiptRejectedTest = uncertain.then(fullReceipt(q.pending,false).fail())
  run lateOriginalFullReceiptTest = uncertain.then(restart).then(fullReceipt(q.pending,true)).expect(safety and not(q.unknown) and not(q.settled))
  run oldReceiptCannotClearNewTailTest = firstDone.then(reserveWrite(2)).then(fullReceipt({lo:0,hi:2,epoch:0},true).fail())
  run secondRangeUsesUnwrittenSuffixTest = firstDone.then(reserveWrite(2)).expect(safety and q.pending.lo==2)
  run missingFinalUsageTest = firstDone.then(settle.fail())
  run duplicateSettlementRejectedTest = complete.then(settle).then(loseReply).then(settle.fail())
  action parentRead = all {H::readJoin,q' = q}
  action parentRetry = all {H::send(H::decidedJob,0,0,8,0,10),q' = q}
  run nonceRetryCannotMintNewAdmissionTest = consumed.then(parentRead).then(parentRetry.fail())
  // Intentionally unsafe controls, excluded from step.
  action unsafeReplay = all {holdParent,q' = q.with("calls",q.calls.set(0,2))}
  action unsafeRefund = all {holdParent,q' = q.with("settled",true)}
  action unsafeTail = all {holdParent,q' = q.with("ranges",q.ranges.union(Set({lo:1,hi:3,epoch:q.epoch})))}
  action unsafeForgetSpent = all {holdParent,q' = q.with("spent",false)}
  action unsafeAcceptWithoutIntent = all {holdParent,q' = q.with("accepted",true)}
  action unsafeLateReceipt = all {holdParent,q' = q.with("hasPending",false).with("pending",noRange).with("unknown",false).with("completed",true).with("usage",true).with("settled",true)}
  run sdkReplayCounterexampleTest = uncertain.then(unsafeReplay).expect(not(callOnce))
  run timeoutRefundCounterexampleTest = uncertain.then(unsafeRefund).expect(not(unknownHeld))
  run overlappingTailCounterexampleTest = reserved.then(unsafeTail).expect(not(separated))
  run restartedSpentLossCounterexampleTest = queued.then(restart).then(unsafeForgetSpent).expect(not(acceptanceBound))
  run enqueueBeforeIntentCounterexampleTest = consumed.then(unsafeAcceptWithoutIntent).expect(not(acceptanceBound))
  // This unsafe observation passes weak boolean invariants: provenance is indispensable.
  run unboundLateReceiptCounterexampleTest = uncertain.then(unsafeLateReceipt).expect(settlementBound and not(evidenceBound))
}
