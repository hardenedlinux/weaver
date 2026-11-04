// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

// Driver restart is separate from owner restart. Results are canonical and immutable.
// Authenticated quiescence and external fence acknowledgments are input events.
module DriverCompletionRecovery {
  import FiniteStreamManifest as M from "./FiniteStreamManifest"
  type Request = {key:(int,int),manifest:int,generation:int,epoch:int,inc:int,frontier:int}
  type Recovery = {generation:int,online:bool,tails:(int,int)->int,
    pending:Set[(int,int)],requests:(int,int)->Request,done:Set[(int,int)],
    isolated:Set[(int,int)],usage:Set[int],observed:Set[int],charged:Set[int],violations:int}
  var y:Recovery
  pure def blank(p) = {key:p,manifest:100+p._1,generation:-1,epoch:-1,inc:-1,frontier:0}
  action initWith(n) = all {M::initWith(n), y' = {generation:0,online:true,
    tails:M::pairIds(n).mapBy(_ => -1),pending:Set(),requests:M::pairIds(n).mapBy(p => blank(p)),
    done:Set(),isolated:Set(),usage:Set(),observed:Set(),charged:Set(),violations:0}}
  action init = initWith(3)
  action emptyInit = initWith(0)
  action singletonInit = initWith(1)
  action largerInit = initWith(5)
  action stay = all {M::baseStay,M::x' = M::x}
  def request(p) = {key:p,manifest:M::manifestId(p._1),generation:y.generation,
    epoch:M::x.ranges.get(p).holderEpoch,inc:M::x.ranges.get(p).holderInc,frontier:M::x.ranges.get(p).cursor}
  def current(q) = q == request(q.key) and y.tails.get(q.key) == y.generation and
    M::x.ranges.get(q.key).active and q.frontier == 4 and y.online
  action install(k) = all {M::install(k,M::manifestId(k),k),y' = y}
  action delegate(k,r,e,inc) = all {y.online,M::delegate(k,r,M::spec(k,r),k,e,inc),
    y' = y.with("tails",y.tails.set((k,r),y.generation))}
  action write(k,r,n) = all {y.online,y.tails.get((k,r)) == y.generation,
    not(y.isolated.contains((k,r))),M::writePrefix(k,r,n,M::x.ranges.get((k,r)).holderEpoch,M::x.ranges.get((k,r)).holderInc),y' = y}
  action prepare(q) = all {current(q),not(y.pending.contains(q.key)),stay,
    y' = y.with("pending",y.pending.union(Set(q.key))).with("requests",y.requests.set(q.key,q))}
  // finish denotes trusted quiescence. It is not a delayed raw SDK callback.
  action finish(q) = all {current(q),y.pending.contains(q.key),y.requests.get(q.key) == q,
    not(y.done.contains(q.key)),M::finishRange(q.key._1,q.key._2,q.epoch,q.inc,q.frontier),
    y' = y.with("done",y.done.union(Set(q.key)))}
  action crash = all {stay,y' = y.with("generation",y.generation+1).with("online",false)}
  action recover = all {stay,y' = y.with("online",true)}
  action fence(p) = all {M::x.ranges.get(p).active,stay,
    y' = y.with("isolated",y.isolated.union(Set(p)))}
  action quarantine(p) = all {y.isolated.contains(p),
    M::uncertain(p._1,p._2,M::x.ranges.get(p).holderEpoch,M::x.ranges.get(p).holderInc),y' = y}
  action resolve(q) = all {y.done.contains(q.key),y.requests.get(q.key) == q,stay,y' = y}
  action resolvePending(q) = all {y.pending.contains(q.key),y.requests.get(q.key) == q,
    not(y.done.contains(q.key)),stay,y' = y}
  action loseReply = all {stay,y' = y}
  action restartOwner = all {M::restartOwner,y' = y}
  action recoverOwner = all {M::recoverOwner,y' = y}
  action restrict(h) = all {M::restrict(h),y' = y}
  action recoverHost = all {M::recoverHost,y' = y}
  action observe(k) = all {M::observe(k),y' = y.with("observed",y.observed.union(Set(k)))}
  action retire(k) = all {M::retire(k),y' = y}
  // Authenticated original-message final usage, independent of driver completion.
  action finalUsage(k) = all {stay,y' = y.with("usage",y.usage.union(Set(k)))}
  action settle(k) = all {M::x.retired.contains(k),y.usage.contains(k),y.observed.contains(k),stay,
    y' = y.with("charged",y.charged.union(Set(k)))}
  val resultSafety = y.done.forall(p => y.pending.contains(p) and y.requests.get(p).key == p and
    y.requests.get(p).manifest == M::manifestId(p._1) and y.requests.get(p).frontier == 4 and
    M::x.ranges.get(p).cursor == 4 and not(M::x.ranges.get(p).active))
  val settlementSafety = y.charged.forall(k => M::x.retired.contains(k) and y.usage.contains(k) and
    y.observed.contains(k) and M::rangeIds(M::x.n).forall(r => not(M::x.ranges.get((k,r)).active)))
  val safety = M::safety and resultSafety and settlementSafety and y.violations == 0
  action step = {
    nondet k = Set(0,1,2,3).oneOf()
    nondet r = (if (M::x.n == 0) Set(0) else M::rangeIds(M::x.n)).oneOf()
    nondet n = 1.to(4).oneOf()
    nondet ownerInc = 0.to(3).oneOf()
    val p = (k,r)
    val q = if (r < M::x.n) request(p) else blank(p)
    any {install(k),crash,recover,loseReply,restartOwner,recoverOwner,
      restrict(k%2),recoverHost,observe(k),retire(k),finalUsage(k),settle(k),
      if (r < M::x.n) any {delegate(k,r,0,ownerInc),write(k,r,n),prepare(q),finish(q),
        fence(p),quarantine(p),resolve(q),resolvePending(q)} else all {stay,y' = y}}
  }
  // Bad designs deliberately excluded from step.
  action releaseFromCallback(p) = all {M::baseStay,
    M::x' = M::x.with("ranges",M::x.ranges.set(p,M::x.ranges.get(p).with("active",false))),
    y' = y.with("violations",y.violations+1)}
  action copyRecoveredTail(p) = all {stay,y' = y.with("tails",y.tails.set(p,y.generation)).with("violations",y.violations+1)}
  action settleFromFinish(k) = all {stay,y' = y.with("charged",y.charged.union(Set(k)))}
  action eraseResult(p) = all {stay,y' = y.with("done",y.done.exclude(Set(p))).with("violations",y.violations+1)}

  action ready = init.then(install(0)).then(delegate(0,0,0,0))
  action full = ready.then(write(0,0,4)).then(prepare(request((0,0))))
  run lostPrepareReplyTest = full.then(loseReply).then(resolvePending(y.requests.get((0,0)))).expect(safety and M::x.ranges.get((0,0)).active)
  run fullFrontierStillBusyTest = full.then(delegate(0,1,0,0).fail())
  run completionLostReplyTest = full.then(finish(request((0,0)))).then(loseReply).then(crash).then(recover)
    .then(resolve(y.requests.get((0,0)))).then(delegate(0,1,0,0)).expect(safety)
  run lateReceiptCannotCloseNewRangeTest = full.then(finish(request((0,0)))).then(delegate(0,1,0,0))
    .then(resolve(y.requests.get((0,0)))).expect(safety and M::x.ranges.get((0,1)).active)
  run duplicateFinishRejectedTest = full.then(finish(request((0,0)))).then(finish(y.requests.get((0,0))).fail())
  run wrongOrdinalStatusRejectedTest = full.then(finish(request((0,0)))).then(resolve(y.requests.get((0,0)).with("key",(0,1))).fail())
  run restartBeforeCommitRejectsOldFinishTest = full.then(crash).then(recover).then(finish(y.requests.get((0,0))).fail())
  run missingStatusRejectedTest = full.then(crash).then(recover).then(resolve(y.requests.get((0,0))).fail())
  run prepareDoesNotAuthorizeRecoveryTest = full.then(crash).then(recover).then(write(0,0,1).fail())
  run partialRestartRejectsTailTest = ready.then(write(0,0,1)).then(crash).then(recover).then(write(0,0,3).fail())
  run oldDriverCannotFreeSlotTest = ready.then(write(0,0,1)).then(crash).then(recover).then(delegate(0,1,0,0).fail())
  run fenceRequiredTest = ready.then(crash).then(recover).then(quarantine((0,0)).fail())
  run fencedTailCannotWriteTest = ready.then(write(0,0,1)).then(fence((0,0))).then(write(0,0,3).fail())
  run isolationQuarantinesTest = ready.then(write(0,0,1)).then(crash).then(recover).then(fence((0,0)))
    .then(quarantine((0,0))).expect(safety and M::used(M::x,0) == 1).then(delegate(0,1,0,0).fail())
  run lateFinishAfterQuarantineRejectedTest = full.then(crash).then(recover).then(fence((0,0)))
    .then(quarantine((0,0))).then(finish(y.requests.get((0,0))).fail())
  run completionDoesNotSettleTest = full.then(finish(request((0,0)))).then(observe(0)).then(settle(0).fail())
  run retirementDoesNotProveUsageTest = full.then(finish(request((0,0)))).then(retire(0)).then(observe(0)).then(settle(0).fail())
  run independentUsageAndRetirementTest = full.then(finish(request((0,0)))).then(retire(0)).then(observe(0))
    .then(finalUsage(0)).then(settle(0)).expect(safety and M::used(M::x,0) == 1)
  run ownerRestartKeepsDriverTest = ready.then(write(0,0,1)).then(restartOwner).then(recoverOwner)
    .then(write(0,0,3)).then(prepare(request((0,0)))).then(finish(request((0,0)))).expect(safety)
  run alteredManifestReceiptRejectedTest = full.then(finish(y.requests.get((0,0)).with("manifest",999)).fail())
  run parallelPrepareConflictRejectedTest = full.then(prepare(y.requests.get((0,0)).with("generation",1)).fail())
  run futureFenceRejectedTest = init.then(fence((0,0)).fail())
  run usageCannotRetireLiveTailTest = ready.then(finalUsage(0)).then(observe(0)).then(settle(0).fail())
  run quarantineRetainsUnknownHoldTest = ready.then(crash).then(recover).then(fence((0,0)))
    .then(quarantine((0,0))).then(retire(0)).then(observe(0)).expect(safety and M::used(M::x,0) == 1)
    .then(settle(0).fail())
  run latePrefixCallbackCounterexampleTest = ready.then(write(0,0,1)).then(releaseFromCallback((0,0))).expect(not(safety))
  run recoveredTailCopyCounterexampleTest = ready.then(write(0,0,1)).then(crash).then(recover).then(copyRecoveredTail((0,0)))
    .then(write(0,0,3)).expect(not(safety))
  run finishAsUsageCounterexampleTest = full.then(finish(request((0,0)))).then(settleFromFinish(0)).expect(not(settlementSafety))
  run oldReceiptReleasesSuccessorCounterexampleTest = full.then(finish(request((0,0)))).then(delegate(0,1,0,0))
    .then(releaseFromCallback((0,1))).expect(not(safety))
  run lostReplyResetsResultCounterexampleTest = full.then(finish(request((0,0)))).then(loseReply).then(eraseResult((0,0))).expect(not(safety))
  run unmediatedOldBufferCounterexampleTest = ready.then(write(0,0,1)).then(crash).then(recover)
    .then(fence((0,0))).then(quarantine((0,0))).then(all {M::cloneDriverPrefix(0,0,1),y' = y}).expect(not(M::rangeSafety))

}
