// Reuse the actual checked coordinator, excluding its one-range delegate/drain.
// n is arbitrary finite. Tests/samples instantiate different finite sizes.
module FiniteStreamManifest {
  import ComposedGatewayLifecycle as Base from "./ComposedGatewayLifecycle"
  type Descriptor = {start:int,length:int,quota:int,content:int,route:int}
  type Range = {issued:bool,accepts:int,cursor:int,active:bool,holderEpoch:int,holderInc:int,
    descriptor:Descriptor,offers:int -> int}
  type ManifestWorld = {n:int,installed:Set[int],ranges:(int,int) -> Range,blocked:Set[int],retired:Set[int],violations:int}
  var x:ManifestWorld
  pure def spec(k,r) = {start:r*4,length:4,quota:r+1,content:1000+100*k+r,route:500+k}
  pure def manifestId(k) = 100+k
  pure def stream(k) = k % 2
  pure def rangeIds(n) = 0.to(n-1)
  pure def pairIds(n) = Base::messages.map(k => rangeIds(n).map(r => (k,r))).flatten()
  pure def unit(n) = if (n == 0) 1 else n*(n+1)/2
  pure def blank(k,r) = {issued:false,accepts:0,cursor:0,active:false,holderEpoch:0,holderInc:0,
    descriptor:spec(k,r),offers:0.to(3).mapBy(_ => 0)}
  action initWith(n) = all {n >= 0,Base::init,x' = {n:n,installed:Set(),
    ranges:pairIds(n).mapBy(p => blank(p._1,p._2)),blocked:Set(),retired:Set(),violations:0}}
  action init = initWith(3)
  action emptyInit = initWith(0)
  action singletonInit = initWith(1)
  action largerInit = initWith(5)
  action baseStay = Base::s' = Base::s
  def canInstall(k,id,t) = not(x.retired.contains(k)) and not(x.installed.contains(k)) and id == manifestId(k) and
    Base::canDelegate(k,t,Base::s.epoch,Base::s.inc)
  action install(k,id,t) = all {canInstall(k,id,t),baseStay,x' = x.with("installed",x.installed.union(Set(k)))}
  def idle(k) = pairIds(x.n).forall(p => stream(p._1) == stream(k) implies not(x.ranges.get(p).active))
  def predecessorsDone(k,r) = rangeIds(x.n).forall(i => i < r implies
    (x.ranges.get((k,i)).cursor == 4 and not(x.ranges.get((k,i)).active)))
  def canDelegate(k,r,d,t,e,inc) = not(x.retired.contains(k)) and x.installed.contains(k) and r >= 0 and r < x.n and
    d == spec(k,r) and not(x.blocked.contains(stream(k))) and not(x.ranges.get((k,r)).issued) and
    Base::canDelegate(k,t,e,inc) and idle(k) and predecessorsDone(k,r)
  def accepted(w,k,r,d) = {
    val old = w.ranges.get((k,r))
    w.with("ranges",w.ranges.set((k,r),old.with("issued",true).with("accepts",old.accepts+1)
      .with("active",true).with("holderEpoch",Base::s.epoch).with("holderInc",Base::s.inc).with("descriptor",d)))
  }
  action delegate(k,r,d,t,e,inc) = all {canDelegate(k,r,d,t,e,inc),baseStay,x' = accepted(x,k,r,d)}
  pure def advanced(w,k,r,n) = {
    val old = w.ranges.get((k,r))
    val frontier = old.cursor+n
    w.with("ranges",w.ranges.set((k,r),old.with("cursor",frontier).with("active",frontier < 4)
      .with("offers",0.to(3).mapBy(b => old.offers.get(b)+(if (old.cursor <= b and b < frontier) 1 else 0)))))
  }
  action writePrefix(k,r,n,e,inc) = all {r >= 0,r < x.n,x.ranges.get((k,r)).issued,
    x.ranges.get((k,r)).active,e == x.ranges.get((k,r)).holderEpoch,inc == x.ranges.get((k,r)).holderInc,
    n > 0,x.ranges.get((k,r)).cursor+n <= 4,baseStay,x' = advanced(x,k,r,n)}
  action uncertain(k,r,e,inc) = all {r >= 0,r < x.n,x.ranges.get((k,r)).issued,
    x.ranges.get((k,r)).active,e == x.ranges.get((k,r)).holderEpoch,inc == x.ranges.get((k,r)).holderInc,
    baseStay,x' = advanced(x,k,r,4-x.ranges.get((k,r)).cursor).with("blocked",x.blocked.union(Set(stream(k))))}
  action retire(k) = all {x.installed.contains(k),rangeIds(x.n).forall(r => not(x.ranges.get((k,r)).active)),
    baseStay,x' = x.with("retired",x.retired.union(Set(k)))}
  action observe(k) = all {Base::observe(k),x' = x}
  action restartOwner = all {Base::restartOwner,x' = x}
  action recoverOwner = all {Base::recoverOwner,x' = x}
  action recoverHost = all {Base::recoverHost,x' = x}
  action restrict(h) = all {Base::restrict(h),x' = x}
  action seal(r) = all {Base::seal(r),x' = x}
  action commit(cid,r) = all {Base::commit(cid,r),x' = x}
  action abort(cid,r) = all {Base::abort(cid,r),x' = x}
  action activate(r,inc) = all {Base::activate(r,inc),x' = x}
  action loseReply = all {Base::loseReply,x' = x}
  action rollbackHost = all {Base::rollbackHost,x' = x}
  action partition = all {Base::partition,x' = x}
  action reconnect = all {Base::reconnect,x' = x}
  action step = {
    nondet k = Base::messages.oneOf()
    nondet r = (if (x.n == 0) Set(0) else rangeIds(x.n)).oneOf()
    nondet n = 1.to(4).oneOf()
    nondet op = Base::operations.oneOf()
    nondet cid = Base::cmdIds.oneOf()
    nondet h = Set(0,1).oneOf()
    val holderEpoch = if (r < x.n) x.ranges.get((k,r)).holderEpoch else 0
    val holderInc = if (r < x.n) x.ranges.get((k,r)).holderInc else 0
    val migration = Base::req(op,Base::s.head,Base::s.epoch)
    any {install(k,manifestId(k),k),delegate(k,r,spec(k,r),k,Base::s.epoch,Base::s.inc),
      writePrefix(k,r,n,holderEpoch,holderInc),uncertain(k,r,holderEpoch,holderInc),retire(k),observe(k),restartOwner,recoverOwner,recoverHost,
      restrict(h),seal(migration),commit(cid,Base::s.sealed),abort(cid,Base::s.sealed),
      activate(Base::s.sealed,Base::s.inc),loseReply,rollbackHost,partition,reconnect}
  }
  pure def used(w,k) = rangeIds(w.n).fold(0,(total,r) => total+
    (if (w.ranges.get((k,r)).issued) w.ranges.get((k,r)).descriptor.quota else 0))
  val manifestSafety = pairIds(x.n).forall(p => x.ranges.get(p).descriptor == spec(p._1,p._2) and
    (x.ranges.get(p).issued implies x.installed.contains(p._1)))
  val coverageSafety = Base::messages.forall(k =>
    rangeIds(x.n).forall(r => x.ranges.get((k,r)).descriptor.start+4 <= 4*x.n) and
    0.to(4*x.n-1).forall(b => rangeIds(x.n).filter(r => {
      val d = x.ranges.get((k,r)).descriptor
      d.start <= b and b < d.start+4
    }).size() == 1))
  val rangeSafety = pairIds(x.n).forall(p => {
    val q = x.ranges.get(p)
    q.accepts <= 1 and (q.issued iff q.accepts == 1) and q.cursor >= 0 and q.cursor <= 4 and
      (not(q.issued) implies q.cursor == 0 and not(q.active)) and
      (q.active implies q.issued and q.cursor < 4) and
      0.to(3).forall(b => q.offers.get(b) == (if (b < q.cursor) 1 else 0))
  })
  val uniqueTailSafety = pairIds(x.n).forall(a => pairIds(x.n).forall(b =>
    (x.ranges.get(a).active and x.ranges.get(b).active and stream(a._1) == stream(b._1)) implies a == b))
  val sharedBudgetSafety = Set(0,1).forall(h => Base::messages.filter(k => Base::account(k) == h)
    .fold(0,(total,k) => total+used(x,k)) <= 4*unit(x.n)) and
    Base::messages.forall(k => used(x,k) <= Base::s.held.get(k)*unit(x.n))
  val byteAliasSafety = Base::messages.forall(k => 0.to(4*x.n-1).forall(b =>
    rangeIds(x.n).fold(0,(total,r) => {
      val q = x.ranges.get((k,r))
      total+(if (q.descriptor.start <= b and b < q.descriptor.start+4) q.offers.get(b-q.descriptor.start) else 0)
    }) <= 1))
  val retirementSafety = Base::messages.forall(k => x.retired.contains(k) implies
    rangeIds(x.n).forall(r => not(x.ranges.get((k,r)).active)))
  val safety = Base::safety and manifestSafety and rangeSafety and uniqueTailSafety and sharedBudgetSafety and coverageSafety and byteAliasSafety and retirementSafety and x.violations == 0

  // Excluded bad designs. Historical acceptance/exposure facts are retained.
  action rewindFromReportedCount(k,r,count) = all {baseStay,
    x' = x.with("ranges",x.ranges.set((k,r),x.ranges.get((k,r)).with("cursor",count).with("active",true)))}
  action rebuildAfterRestart(k,r) = all {baseStay,x' = x.with("ranges",x.ranges.set((k,r),
    x.ranges.get((k,r)).with("issued",false).with("cursor",0).with("active",false)))}
  action replaceManifest(k,r) = all {baseStay,x' = x.with("installed",x.installed.exclude(Set(k)))
    .with("ranges",x.ranges.set((k,r),x.ranges.get((k,r)).with("issued",false).with("cursor",0).with("active",false)))}
  action unsafeDelegate(k,r,d) = all {baseStay,x' = accepted(x,k,r,d).with("violations",x.violations+
    (if (canDelegate(k,r,d,k,Base::s.epoch,Base::s.inc)) 0 else 1))}
  action cloneDriverPrefix(k,r,n) = all {baseStay,x' = x.with("ranges",x.ranges.set((k,r),
    x.ranges.get((k,r)).with("offers",0.to(3).mapBy(b => x.ranges.get((k,r)).offers.get(b)+(if (b < n) 1 else 0)))))}
  action unsafeRetire(k) = all {baseStay,x' = x.with("retired",x.retired.union(Set(k)))}
  action retagOldTail(k,r) = all {baseStay,x' = x.with("ranges",x.ranges.set((k,r),
    x.ranges.get((k,r)).with("holderInc",Base::s.inc))).with("violations",x.violations+1)}

  run emptyManifestTest = initWith(0).then(install(0,100,0)).expect(safety and used(x,0) == 0)
  run singletonManifestTest = initWith(1).then(install(0,100,0)).then(delegate(0,0,spec(0,0),0,0,0))
    .then(writePrefix(0,0,4,0,0)).expect(safety)
  run finiteManifestSequenceTest = init.then(install(0,100,0)).then(delegate(0,0,spec(0,0),0,0,0))
    .then(writePrefix(0,0,1,0,0)).then(writePrefix(0,0,3,0,0)).then(delegate(0,1,spec(0,1),0,0,0))
    .then(writePrefix(0,1,4,0,0)).then(delegate(0,2,spec(0,2),0,0,0)).then(writePrefix(0,2,4,0,0))
    .expect(safety and used(x,0) == 6)
  run fiveRangeManifestTest = initWith(5).then(install(0,100,0)).then(delegate(0,0,spec(0,0),0,0,0))
    .then(writePrefix(0,0,4,0,0)).then(delegate(0,1,spec(0,1),0,0,0)).then(writePrefix(0,1,4,0,0))
    .then(delegate(0,2,spec(0,2),0,0,0)).then(writePrefix(0,2,4,0,0))
    .then(delegate(0,3,spec(0,3),0,0,0)).then(writePrefix(0,3,4,0,0))
    .then(delegate(0,4,spec(0,4),0,0,0)).then(writePrefix(0,4,4,0,0)).expect(safety and used(x,0) == 15)
  run duplicateRangeRejectedTest = init.then(install(0,100,0)).then(delegate(0,0,spec(0,0),0,0,0))
    .then(writePrefix(0,0,4,0,0)).then(delegate(0,0,spec(0,0),0,0,0).fail())
  run manifestReplacementRejectedTest = init.then(install(0,100,0)).then(install(0,101,0).fail())
  run alteredDescriptorRejectedTest = init.then(install(0,100,0)).then(delegate(0,0,spec(0,0).with("route",999),0,0,0).fail())
  run predecessorRejectedTest = init.then(install(0,100,0)).then(delegate(0,1,spec(0,1),0,0,0).fail())
  run sharedStreamConcurrentTailRejectedTest = init.then(install(0,100,0)).then(install(2,102,2))
    .then(delegate(0,0,spec(0,0),0,0,0)).then(delegate(2,0,spec(2,0),2,0,0).fail())
  run independentStreamConcurrencyTest = init.then(install(0,100,0)).then(install(1,101,1))
    .then(delegate(0,0,spec(0,0),0,0,0)).then(delegate(1,0,spec(1,0),1,0,0)).expect(safety)
  run uncertaintyQuarantinesStreamTest = init.then(install(0,100,0)).then(delegate(0,0,spec(0,0),0,0,0))
    .then(writePrefix(0,0,1,0,0)).then(uncertain(0,0,0,0)).then(restartOwner).then(recoverOwner)
    .expect(safety and used(x,0) == 1).then(delegate(0,1,spec(0,1),0,0,1).fail())
  run ownerRestartPreservesOriginalTailTest = init.then(install(0,100,0)).then(delegate(0,0,spec(0,0),0,0,0))
    .then(writePrefix(0,0,1,0,0)).then(restartOwner).then(recoverOwner)
    .then(writePrefix(0,0,3,0,0)).then(delegate(0,1,spec(0,1),0,0,1)).expect(safety)
  run newOwnerCannotUseOldTailTest = init.then(install(0,100,0)).then(delegate(0,0,spec(0,0),0,0,0))
    .then(restartOwner).then(recoverOwner).then(writePrefix(0,0,1,0,1).fail())
  run historyCutPreservesOldExposureTest = init.then(install(0,100,0)).then(delegate(0,0,spec(0,0),0,0,0))
    .then(restrict(0)).then(writePrefix(0,0,4,0,0)).then(recoverHost).expect(safety)
    .then(delegate(0,1,spec(0,1),0,0,0).fail())
  run sharedHistoryRejectsOtherMessageTest = init.then(install(0,100,0)).then(install(2,102,2))
    .then(restrict(0)).then(recoverHost).then(delegate(2,0,spec(2,0),2,0,0).fail())
  run migrationPreservesManifestAndTailTest = init.then(install(0,100,0)).then(delegate(0,0,spec(0,0),0,0,0))
    .then(writePrefix(0,0,1,0,0)).then(seal(Base::req(0,0,0))).then(commit(0,Base::req(0,0,0)))
    .then(loseReply).then(restartOwner).then(recoverHost).then(recoverOwner).then(activate(Base::req(0,0,0),1))
    .then(writePrefix(0,0,3,0,0)).then(delegate(0,1,spec(0,1),0,1,1)).expect(safety)
  run sharedBudgetSequenceTest = init.then(install(0,100,0)).then(install(2,102,2))
    .then(delegate(0,0,spec(0,0),0,0,0)).then(writePrefix(0,0,4,0,0))
    .then(delegate(2,0,spec(2,0),2,0,0)).then(writePrefix(2,0,4,0,0)).expect(safety and used(x,0)+used(x,2) == 2)
  run freshNonceRejectedTest = init.then(install(0,100,0)).then(delegate(0,0,spec(0,0),100,0,0).fail())
  run lateObservationDoesNotReopenTest = init.then(install(0,100,0)).then(delegate(0,0,spec(0,0),0,0,0))
    .then(writePrefix(0,0,4,0,0)).then(observe(0)).then(delegate(0,0,spec(0,0),0,0,0).fail())
  run retireWhileTailLiveRejectedTest = init.then(install(0,100,0)).then(delegate(0,0,spec(0,0),0,0,0))
    .then(writePrefix(0,0,1,0,0)).then(retire(0).fail())
  run retiredMessageCannotDelegateTest = init.then(install(0,100,0)).then(delegate(0,0,spec(0,0),0,0,0))
    .then(writePrefix(0,0,4,0,0)).then(retire(0)).then(observe(0)).expect(safety)
    .then(delegate(0,1,spec(0,1),0,0,0).fail())
  run reportedCountRewindCounterexampleTest = init.then(install(0,100,0)).then(delegate(0,0,spec(0,0),0,0,0))
    .then(writePrefix(0,0,4,0,0)).then(rewindFromReportedCount(0,0,1)).then(writePrefix(0,0,3,0,0)).expect(not(rangeSafety))
  run restartReplayCounterexampleTest = init.then(install(0,100,0)).then(delegate(0,0,spec(0,0),0,0,0))
    .then(writePrefix(0,0,4,0,0)).then(restartOwner).then(recoverOwner).then(rebuildAfterRestart(0,0))
    .then(delegate(0,0,spec(0,0),0,0,1)).expect(not(rangeSafety))
  run newManifestAliasCounterexampleTest = init.then(install(0,100,0)).then(delegate(0,0,spec(0,0),0,0,0))
    .then(writePrefix(0,0,4,0,0)).then(replaceManifest(0,0)).then(install(0,100,0))
    .then(delegate(0,0,spec(0,0),0,0,0)).expect(not(rangeSafety))
  run overlappingRangesCounterexampleTest = init.then(install(0,100,0)).then(delegate(0,0,spec(0,0),0,0,0))
    .then(writePrefix(0,0,4,0,0)).then(unsafeDelegate(0,1,spec(0,1).with("start",0)))
    .then(writePrefix(0,1,4,0,0)).expect(not(byteAliasSafety))
  run duplicateDriverCapabilityCounterexampleTest = init.then(install(0,100,0)).then(delegate(0,0,spec(0,0),0,0,0))
    .then(writePrefix(0,0,2,0,0)).then(cloneDriverPrefix(0,0,2)).expect(not(rangeSafety))
  run rangeBudgetOverrunCounterexampleTest = init.then(install(0,100,0))
    .then(unsafeDelegate(0,0,spec(0,0).with("quota",1000))).expect(not(sharedBudgetSafety))
  run historyBypassCounterexampleTest = init.then(install(0,100,0)).then(restrict(0)).then(recoverHost)
    .then(unsafeDelegate(0,0,spec(0,0))).expect(not(safety))
  run concurrentStreamTailsCounterexampleTest = init.then(install(0,100,0)).then(install(2,102,2))
    .then(delegate(0,0,spec(0,0),0,0,0)).then(unsafeDelegate(2,0,spec(2,0))).expect(not(uniqueTailSafety))
  run ownerRetaggingCounterexampleTest = init.then(install(0,100,0)).then(delegate(0,0,spec(0,0),0,0,0))
    .then(restartOwner).then(recoverOwner).then(retagOldTail(0,0)).then(writePrefix(0,0,1,0,1)).expect(not(safety))  run incompleteCoverageCounterexampleTest = initWith(1).then(install(0,100,0))
    .then(unsafeDelegate(0,0,spec(0,0).with("start",1))).expect(not(coverageSafety))
  run prematureRetirementCounterexampleTest = init.then(install(0,100,0)).then(delegate(0,0,spec(0,0),0,0,0))
    .then(writePrefix(0,0,1,0,0)).then(unsafeRetire(0)).expect(not(retirementSafety))

}
