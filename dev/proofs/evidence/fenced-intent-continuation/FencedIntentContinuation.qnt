// Durable intent decisions precede acknowledgement; fences never erase acceptance.
module FencedIntentContinuation {
  import DeviceIsolationRecovery as D from "./DeviceIsolationRecovery"
  import KeyBoundaryQueue as K from "./KeyBoundaryQueue"
  type Intent = {id:int,cut:D::Cut,worker:int,fence:int}
  type Resolution = {intent:Intent,kind:int}
  type Link = {id:int,root:Intent,cut:D::Cut,worker:int,fence:int,parent:int}
  type State = {worker:int,fence:int,accepted:Set[Intent],decisions:Set[Resolution],haveSlot:bool,slot:Intent,observed:bool,receipt:Resolution,links:Set[Link],retired:Set[int],commits:Set[Link],haveLink:bool,link:Link,phase:int,seenLink:bool,seenWorker:int}
  var f:State
  pure val emptyIntent = {id:-1,cut:D::emptyCut,worker:-1,fence:-1}
  pure val emptyResolution = {intent:emptyIntent,kind:0}
  pure val emptyLink = {id:-1,root:emptyIntent,cut:D::emptyCut,worker:-1,fence:-1,parent:-1}
  pure val initial = {worker:0,fence:0,accepted:Set(),decisions:Set(),haveSlot:false,slot:emptyIntent,observed:false,receipt:emptyResolution,links:Set(),retired:Set(),commits:Set(),haveLink:false,link:emptyLink,phase:14,seenLink:false,seenWorker:-1}
  action init = all {D::init,f' = initial}
  def decided(i) = f.decisions.exists(r => r.intent == i)
  def committed(i) = f.decisions.contains({intent:i,kind:1})
  def resumed(i) = f.commits.exists(l => l.root == i)
  def rootDone(i) = committed(i) or resumed(i)
  def unlocked = not(f.haveSlot)
  action accept(worker) = {
    val i = {id:f.accepted.size(),cut:D::d.certified,worker:worker,fence:f.fence}
    all {worker == f.worker,unlocked,f.phase == 14,D::prepareFloor,
      f' = f.with("accepted",f.accepted.union(Set(i))).with("haveSlot",true).with("slot",i).with("observed",false)}
  }
  action decide(i,worker) = all {f.haveSlot,i == f.slot,worker == f.worker,i.worker == worker,i.fence == f.fence,not(rootDone(i)),not(decided(i)),
    D::commitFloor,f' = f.with("decisions",f.decisions.union(Set({intent:i,kind:1}))).with("observed",false)}
  def fencedDecisions = if (f.haveSlot and not(decided(f.slot))) f.decisions.union(Set({intent:f.slot,kind:2})) else f.decisions
  action reset = all {D::resetDevice(D::d.profile),f' = f.with("worker",f.worker+1).with("fence",f.fence+1)
    .with("decisions",fencedDecisions).with("observed",false).with("phase",14).with("seenLink",false)
    .with("retired",if (f.haveLink) f.retired.union(Set(f.link.id)) else f.retired)}
  action restart = all {D::restartDriver(0),f' = f.with("worker",f.worker+1).with("fence",f.fence+1)
    .with("decisions",fencedDecisions).with("observed",false).with("phase",14).with("seenLink",false)
    .with("retired",if (f.haveLink) f.retired.union(Set(f.link.id)) else f.retired)}
  action close = all {D::close,f' = f.with("worker",f.worker+1).with("fence",f.fence+1)
    .with("decisions",fencedDecisions).with("observed",false).with("phase",14).with("seenLink",false)
    .with("retired",if (f.haveLink) f.retired.union(Set(f.link.id)) else f.retired)}
  // Authoritative reads bind the full decision prefix and current recovery session.
  action observe(r,prefix,worker,authentic) = all {authentic,worker == f.worker,prefix == f.decisions,f.haveSlot,r.intent == f.slot,
    f.decisions.contains(r),D::loseResponse,f' = f.with("observed",true).with("receipt",r)}
  action readDecision = observe({intent:f.slot,kind:if (committed(f.slot)) 1 else 2},f.decisions,f.worker,true)
  action acknowledge = all {f.haveSlot,f.observed,f.receipt == {intent:f.slot,kind:1},committed(f.slot),D::loseResponse,
    f' = f.with("haveSlot",false).with("observed",false)}
  action loseResponse = all {D::loseResponse,f' = f}
  action readCurrent = all {D::readCurrent,f' = f}
  action seal = all {unlocked,f.phase == 14,D::seal,f' = f}
  action blockAll = all {D::blockAll(true),f' = f}
  action certify = all {D::certify(D::d.captured,true),f' = f}
  action barrier = all {D::observeBarrier,f' = f}
  action liveFloor = all {unlocked,D::liveFloor,f' = f}
  action activate = all {unlocked,f.phase == 14,D::activate(true),f' = f.with("phase",0)}
  action register(id,kind) = all {D::register(id,kind,true),f' = f}
  action parentRead = all {D::parentRead,f' = f}
  action parentQualify = all {D::parentQualify,f' = f}
  action begin(id,v,value) = all {D::parentBegin(id,v,value),f' = f}
  action commit(id) = all {D::parentCommit(id),f' = f}
  action resolve(id) = all {D::parentResolve(id),f' = f}
  action handle(id,v) = all {unlocked,D::parentHandle(id,v),f' = f}
  action enqueue(job,id,h,a,b) = all {unlocked,D::enqueue(job,id,h,a,b),f' = f}
  action bind(job,a,b) = all {unlocked,D::bind(job,a,b),f' = f}
  action start(job) = all {unlocked,D::start(job),f' = f}
  action complete(job) = all {D::complete(job,D::d.submissions.get(job),true),f' = f}
  action emit(job) = all {unlocked,D::emit(job),f' = f}
  action archive(job) = all {D::archiveCallback(job,D::d.submissions.get(job),true),f' = f}
  action loseBuffer(job) = all {D::loseBuffer(job),f' = f}
  action election = all {D::parentElection,f' = f}
  action retire(v) = all {D::parentRetire(v),f' = f}
  action deliver(id) = all {D::parentDeliver(id),f' = f}
  action root(value) = all {D::parentRoot(value),f' = f}
  val conserved = f.accepted.forall(i => rootDone(i) or (f.haveSlot and f.slot == i))
  val uniqueDecision = f.decisions.forall(a => f.decisions.forall(b => a.intent == b.intent implies a == b))
  val journalBound = f.decisions.filter(r => r.kind == 1).forall(r => D::d.journal.contains(r.intent.cut))
  val fenceBound = f.decisions.filter(r => r.kind == 2).forall(r => not(D::d.journal.contains(r.intent.cut)) or resumed(r.intent))
  val slotBound = f.haveSlot implies (if (rootDone(f.slot)) D::d.journal.contains(f.slot.cut) else D::d.havePending and D::d.pendingFloor == f.slot.cut)
  val observationBound = f.observed implies f.haveSlot and f.receipt.intent == f.slot and f.decisions.contains(f.receipt)
  val continuationUnique = f.commits.forall(a => f.commits.forall(b => a.root == b.root implies a == b))
  val continuationBound = f.commits.forall(l => f.links.contains(l) and D::d.journal.contains(l.root.cut) and not(committed(l.root)))
  val immutablePromise = f.links.forall(l => l.cut.oldFloor == l.root.cut.oldFloor and l.cut.oldService == l.root.cut.oldService and
    l.cut.profile == l.root.cut.profile and l.root.cut.members.subseteq(l.cut.members) and f.accepted.contains(l.root))
  val lineageBound = f.links.forall(l => l.parent == -1 or f.links.exists(p => p.id == l.parent and p.id < l.id and p.root == l.root and f.retired.contains(p.id)))
  val readyBound = f.phase == 0 implies K::k.enabled
  val safety = continuationUnique and continuationBound and immutablePromise and lineageBound and readyBound and D::safety and conserved and uniqueDecision and journalBound and fenceBound and slotBound and observationBound
  action enterRecovery = all {f.phase == 14,f.haveSlot,not(rootDone(f.slot)),f.decisions.contains({intent:f.slot,kind:2}),
    D::loseResponse,f' = f.with("phase",13)}
  action recut(worker,root,authentic) = {
    val cut = {serial:D::d.serial+1,device:D::d.device,driver:D::d.driver,profile:D::d.profile,
      oldFloor:K::k.epoch,oldService:D::d.service,members:D::members(K::k.epoch)}
    val l = {id:f.links.size(),root:root,cut:cut,worker:worker,fence:f.fence,parent:if (f.haveLink and f.link.root == root) f.link.id else -1}
    all {authentic,f.phase == 13,f.haveSlot,root == f.slot,worker == f.worker,not(rootDone(root)),not(K::k.enabled),
      D::viewCurrent,D::d.havePending,D::d.pendingFloor == root.cut,f.decisions.contains({intent:root,kind:2}),
      cut.oldFloor == root.cut.oldFloor,cut.oldService == root.cut.oldService,cut.profile == root.cut.profile,root.cut.members.subseteq(cut.members),
      not(f.haveLink) or f.link.root != root or f.retired.contains(f.link.id),K::loseResponse,
      D::d' = D::d.with("serial",cut.serial).with("captured",cut).with("haveCut",true).with("haveCert",false),
      f' = f.with("links",f.links.union(Set(l))).with("haveLink",true).with("link",l).with("phase",12).with("seenLink",false)}
  }
  action observeLink(l,worker,prefix,authentic) = all {authentic,f.phase == 12,f.haveLink,f.haveSlot,l == f.link,l.root == f.slot,
    worker == f.worker,l.worker == worker,l.fence == f.fence,prefix == f.links,not(f.retired.contains(l.id)),D::loseResponse,f' = f.with("phase",11)}
  action readLink = observeLink(f.link,f.worker,f.links,true)
  action reblock = all {f.phase == 11,D::blockAll(true),f' = f.with("phase",10)}
  action recertify = all {f.phase == 10,D::certify(D::d.captured,true),f' = f.with("phase",9)}
  action rebarrier = all {f.phase == 9,D::observeBarrier,f' = f.with("phase",8)}
  action resumeCommit(l,worker,authentic) = all {authentic,f.phase == 8,f.haveSlot,f.haveLink,l == f.link,l.root == f.slot,worker == f.worker,
    l.worker == worker,l.fence == f.fence,not(f.retired.contains(l.id)),not(rootDone(l.root)),D::d.havePending,D::d.pendingFloor == l.root.cut,
    D::d.haveCert,D::d.certified == l.cut,D::context(l.cut),D::before(l.cut),D::allBlocked(l.cut),K::advance(true),
    D::d' = D::d.with("journal",D::d.journal.union(Set(l.root.cut))).with("service",D::d.service+1).with("havePending",false).with("viewKnown",false),
    f' = f.with("commits",f.commits.union(Set(l))).with("phase",7).with("seenLink",false)}
  action observeContinuation(l,worker,prefix,authentic) = all {authentic,f.haveSlot,l.root == f.slot,f.commits.contains(l),worker == f.worker,prefix == f.commits,
    D::loseResponse,f' = f.with("seenLink",true).with("seenWorker",worker).with("link",l).with("phase",if (f.phase == 7) 6 else f.phase)}
  action readContinuation = observeContinuation(f.link,f.worker,f.commits,true)
  action acknowledgeContinuation = all {f.haveSlot,f.haveLink,f.seenLink,f.seenWorker == f.worker,f.link.root == f.slot,f.commits.contains(f.link),
    D::loseResponse,f' = f.with("haveSlot",false).with("observed",false).with("seenLink",false).with("phase",if (f.phase == 6) 5 else 14)}
  action rereadFloor = all {f.phase == 5,D::readCurrent,f' = f.with("phase",4)}
  action reliveFloor = all {f.phase == 4,D::liveFloor,f' = f.with("phase",3)}
  action rereadParent = all {f.phase == 3,D::parentRead,f' = f.with("phase",2)}
  action requalify = all {f.phase == 2,D::parentQualify,f' = f.with("phase",1)}
  action reactivate = all {f.phase == 1,unlocked,D::activate(true),f' = f.with("phase",0)}
  action step = {
    nondet job = 0.to(5).oneOf()
    nondet a = 0.to(8).oneOf()
    nondet b = 0.to(8).oneOf()
    nondet kind = 0.to(2).oneOf()
    nondet v = 0.to(2).oneOf()
    nondet value = Set(1,2).oneOf()
    any {enterRecovery,recut(f.worker,f.slot,true),readLink,reblock,recertify,rebarrier,resumeCommit(f.link,f.worker,true),readContinuation,acknowledgeContinuation,rereadFloor,reliveFloor,rereadParent,requalify,reactivate,accept(f.worker),decide(f.slot,f.worker),reset,restart,close,readDecision,acknowledge,loseResponse,readCurrent,seal,blockAll,certify,barrier,
      liveFloor,activate,register(a,kind),parentRead,parentQualify,begin(job,v,value),commit(job),resolve(job),handle(job,v),enqueue(job,job,job,a,b),
      bind(job,a,b),start(job),complete(job),emit(job),archive(job),loseBuffer(job),election,retire(v),deliver(job),root(value)}
  }
  action initialAliases = register(0,0).then(register(1,1)).then(register(2,2))
  action prepare = readCurrent.then(seal).then(blockAll).then(certify).then(barrier).then(accept(f.worker))
  action recover = prepare.then(decide(f.slot,f.worker)).then(readDecision).then(acknowledge).then(readCurrent).then(liveFloor).then(parentRead).then(parentQualify).then(activate)
  action boot = init.then(initialAliases).then(recover).then(register(3,0)).then(register(4,1)).then(register(5,2))
  action pending = boot.then(close).then(prepare)
  action committedPending = pending.then(decide(f.slot,f.worker))
  action fencedPending = pending.then(reset)
  action signed = boot.then(begin(0,0,1)).then(commit(0)).then(resolve(0)).then(handle(0,0)).then(enqueue(0,0,0,4,5)).then(bind(0,4,5))
    .then(start(0)).then(complete(0)).then(emit(0))
  action recovering = fencedPending.then(readCurrent).then(enterRecovery)
  action admittedLink = recovering.then(recut(f.worker,f.slot,true))
  action linked = admittedLink.then(readLink)
  action prepared = linked.then(reblock).then(recertify).then(rebarrier)
  action resumedPending = prepared.then(resumeCommit(f.link,f.worker,true))
  action resumeReady = resumedPending.then(readContinuation).then(acknowledgeContinuation).then(rereadFloor).then(reliveFloor).then(rereadParent).then(requalify).then(reactivate)
  run unfairStutterDoesNotFinishTest = recovering.then(loseResponse).then(loseResponse).expect(safety and f.phase == 13)
  run repeatedResetRestartsRecoveryTest = linked.then(reset).then(reset).then(readCurrent).then(enterRecovery).expect(safety and f.phase == 13)
  action completedOldJob = boot.then(begin(0,0,1)).then(commit(0)).then(resolve(0)).then(handle(0,0)).then(enqueue(0,0,0,4,5)).then(bind(0,4,5)).then(start(0)).then(complete(0))
  action oldBufferRecovery = completedOldJob.then(close).then(prepare).then(reset).then(readCurrent).then(enterRecovery).then(recut(f.worker,f.slot,true)).then(readLink).then(reblock).then(recertify).then(rebarrier)
    .then(resumeCommit(f.link,f.worker,true)).then(readContinuation).then(acknowledgeContinuation).then(rereadFloor).then(reliveFloor).then(rereadParent).then(requalify).then(reactivate)
  run retainedOldBufferCannotReleaseTest = oldBufferRecovery.then(emit(0).fail())
  run newHandleCannotRecreateConsumedJobTest = oldBufferRecovery.then(handle(1,0)).then(enqueue(0,0,1,4,5).fail())
  run noHeadObservationCannotBlockTest = admittedLink.then(reblock.fail())
  run staleHeadObservationRejectedTest = admittedLink.then(observeLink(f.link,f.worker-1,f.links,true).fail())
  run missingHeadPrefixRejectedTest = admittedLink.then(observeLink(f.link,f.worker,Set(),true).fail())
  run oldHeadReadAfterResetRejectedTest = admittedLink.then(reset).then(observeLink(f.link,f.worker,f.links,true).fail())
  run originalPromiseContinuesTest = resumeReady.expect(safety and f.phase == 0 and f.accepted.size() == 2 and f.commits.size() == 1)
  run normalOriginalReleaseTest = signed.expect(safety)
  run lostResumeCommitReplyTest = resumedPending.then(loseResponse).then(readContinuation).then(acknowledgeContinuation).expect(safety)
  run duplicateResumeCommitRejectedTest = resumedPending.then(resumeCommit(f.link,f.worker,true).fail())
  run lateOldAttemptCommitRejectedTest = prepared.then(decide(f.slot,f.slot.worker).fail())
  run recutDoesNotFreeSlotTest = linked.expect(safety and f.haveSlot and D::d.havePending)
  run newClaimCannotReplaceRootTest = recovering.then(recut(f.worker,f.slot.with("id",9),true).fail())
  run falseContinuationReceiptRejectedTest = recovering.then(recut(f.worker,f.slot,false).fail())
  run oldWorkerCannotRecutTest = recovering.then(recut(f.worker-1,f.slot,true).fail())
  run concurrentSecondRecutRejectedTest = linked.then(recut(f.worker,f.slot,true).fail())
  run oldContinuationCannotCommitAfterResetTest = prepared.then(reset).then(resumeCommit(f.link,f.link.worker,true).fail())
  run currentWorkerCannotRelabelOldLinkTest = prepared.then(reset).then(resumeCommit(f.link,f.worker,true).fail())
  run reFenceKeepsLineageTest = prepared.then(reset).then(readCurrent).then(enterRecovery).then(recut(f.worker,f.slot,true))
    .expect(safety and f.links.size() == 2 and f.link.parent == 0)
  run secondAttemptRecoversSameRootTest = prepared.then(reset).then(readCurrent).then(enterRecovery).then(recut(f.worker,f.slot,true)).then(readLink).then(reblock).then(recertify).then(rebarrier)
    .then(resumeCommit(f.link,f.worker,true)).then(readContinuation).then(acknowledgeContinuation).then(rereadFloor).then(reliveFloor).then(rereadParent).then(requalify).then(reactivate)
    .expect(safety and f.commits.size() == 1 and f.accepted.size() == 2)
  run commitBeforeNewFenceRemainsHistoricalTest = resumedPending.then(reset).then(readContinuation).then(acknowledgeContinuation).expect(safety and f.phase == 14)
  run historicalContinuationCannotActivateTest = resumedPending.then(reset).then(readContinuation).then(acknowledgeContinuation).then(activate.fail())
  run newFenceInvalidatesObservationTest = resumedPending.then(readContinuation).then(reset).then(acknowledgeContinuation.fail())
  run staleContinuationObservationRejectedTest = resumedPending.then(reset).then(observeContinuation(f.link,f.worker-1,f.commits,true).fail())
  run incompleteContinuationPrefixRejectedTest = resumedPending.then(observeContinuation(f.link,f.worker,Set(),true).fail())
  run commitBeforeFenceDoesNotNeedContinuationTest = committedPending.then(reset).then(enterRecovery.fail())
  run retainedRootCannotBeAcknowledgedAsAbortTest = fencedPending.then(readDecision).then(acknowledge.fail())
  run lostRecutResponseUsesSameLinkTest = admittedLink.then(loseResponse).then(readLink).then(reblock).expect(safety and f.links.size() == 1)
  run originalAliasRosterRetainedTest = linked.expect(safety and f.slot.cut.members.subseteq(f.link.cut.members))
  run stableRecoveryDecreasesMilestonesTest = resumeReady.expect(safety and K::k.epoch == 2 and f.phase == 0)
  // Unsafe test-only mutations never occur in step.
  action unsafeFree = all {D::loseResponse,f' = f.with("haveSlot",false)}
  action unsafeRenameRoot = all {D::loseResponse,f' = f.with("links",f.links.union(Set(f.link.with("root",f.slot.with("id",9)))))}
  action unsafeDuplicate = all {D::loseResponse,f' = f.with("commits",f.commits.union(Set(f.link.with("id",99))))}
  action unsafeForgetParentFence = all {D::loseResponse,f' = f.with("retired",Set())}
  action unsafeReuseFloor = all {K::loseResponse,D::d' = D::d.with("journal",Set()),f' = f}
  run recutUnlockCounterexampleTest = linked.then(unsafeFree).expect(not(conserved))
  run newRootLaunderingCounterexampleTest = linked.then(unsafeRenameRoot).expect(not(immutablePromise))
  run duplicateRootCommitCounterexampleTest = resumedPending.then(unsafeDuplicate).expect(not(continuationUnique))
  run lostFenceLineageCounterexampleTest = prepared.then(reset).then(readCurrent).then(enterRecovery).then(recut(f.worker,f.slot,true))
    .then(unsafeForgetParentFence).expect(not(lineageBound))
  run rollbackCommittedContinuationCounterexampleTest = resumedPending.then(unsafeReuseFloor).expect(not(continuationBound))
}
