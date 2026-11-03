// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

// Actual mediated key boundary over protected-commit semantics.
module KeyBoundaryQueue {
  import ProtectedSignerRelease as P from "./ProtectedSignerRelease"
  type Handle = {epoch:int,service:int,voter:int,incarnation:int}
  type Ticket = {requestId:int,statement:P::Request,handleId:int,epoch:int}
  type Export = {ticket:Ticket,epoch:int,service:int,gateOpen:bool}
  type State = {epoch:int,enabled:bool,activeService:int,handles:Set[int],registrations:int->Handle,
    used:Set[int],queued:Set[int],running:Set[int],completed:Set[int],tickets:int->Ticket,
    isolation:int,barrierKnown:bool,floorKnown:bool,deviceIsolated:bool,produced:Set[Ticket],exports:Set[Export]}
  var k:State
  pure val jobIds = 0.to(5)
  pure val emptyHandle = {epoch:-1,service:-1,voter:-1,incarnation:-1}
  pure val emptyTicket = {requestId:-1,statement:P::absent,handleId:-1,epoch:-1}
  pure val initial = {epoch:0,enabled:false,activeService:-1,handles:Set(),registrations:jobIds.mapBy(_ => emptyHandle),
    used:Set(),queued:Set(),running:Set(),completed:Set(),tickets:jobIds.mapBy(_ => emptyTicket),
    isolation:-1,barrierKnown:false,floorKnown:false,deviceIsolated:false,produced:Set(),exports:Set()}
  action init = all {P::init,k' = initial}
  def currentHandle(t) = t.epoch == k.epoch and k.handles.contains(t.handleId) and k.registrations.get(t.handleId) ==
    {epoch:k.epoch,service:P::s.epoch,voter:t.statement.voter,incarnation:P::s.incarnation.get(t.statement.voter)}
  action issueHandle(h,v) = all {k.enabled,P::s.qualified,not(k.handles.contains(h)),P::loseResponse,
    k' = k.with("handles",k.handles.union(Set(h))).with("registrations",k.registrations.set(h,
      {epoch:k.epoch,service:P::s.epoch,voter:v,incarnation:P::s.incarnation.get(v)}))}
  action enqueue(job,id,h) = {
    val q = P::s.entries.get(id)
    val t = {requestId:id,statement:q,handleId:h,epoch:k.epoch}
    all {k.enabled,currentHandle(t),P::s.committed.contains(id),P::s.observed.contains(id),P::current(q),not(k.used.contains(job)),P::loseResponse,
      k' = k.with("used",k.used.union(Set(job))).with("queued",k.queued.union(Set(job))).with("tickets",k.tickets.set(job,t))}
  }
  action start(job) = all {k.queued.contains(job),k.enabled,currentHandle(k.tickets.get(job)),P::current(k.tickets.get(job).statement),P::loseResponse,
    k' = k.with("queued",k.queued.exclude(Set(job))).with("running",k.running.union(Set(job)))}
  action complete(job,result,authentic) = all {k.running.contains(job),authentic,result == k.tickets.get(job),P::loseResponse,
    k' = k.with("running",k.running.exclude(Set(job))).with("completed",k.completed.union(Set(job))).with("produced",k.produced.union(Set(result)))}
  action emit(job) = {
    val t = k.tickets.get(job)
    all {k.completed.contains(job),k.enabled,currentHandle(t),P::s.entries.get(t.requestId) == t.statement,P::release(t.requestId),
      k' = k.with("exports",k.exports.union(Set({ticket:t,epoch:k.epoch,service:P::s.epoch,gateOpen:k.enabled})))}
  }
  action close = all {P::loseResponse,k' = k.with("enabled",false).with("isolation",-1).with("barrierKnown",false)
    .with("floorKnown",false).with("deviceIsolated",false)}
  action isolate(authentic) = all {not(k.enabled),authentic,P::loseResponse,k' = k.with("isolation",k.epoch+1)
    .with("barrierKnown",false).with("floorKnown",false).with("deviceIsolated",true)}
  action observeBarrier = all {k.isolation == k.epoch+1,P::loseResponse,k' = k.with("barrierKnown",true)}
  action advance(authentic) = all {not(k.enabled),k.isolation == k.epoch+1,k.barrierKnown,authentic,P::restart,
    k' = k.with("epoch",k.epoch+1).with("barrierKnown",false).with("floorKnown",false)}
  action observeFloor(authentic) = all {k.isolation == k.epoch,authentic,P::loseResponse,k' = k.with("floorKnown",true)}
  action activate(authentic) = all {not(k.enabled),k.isolation == k.epoch,k.floorKnown,P::s.qualified,authentic,P::loseResponse,
    k' = k.with("enabled",true).with("activeService",P::s.epoch)}
  action loseBuffer(job) = all {P::loseResponse,k' = k.with("queued",k.queued.exclude(Set(job))).with("running",k.running.exclude(Set(job)))
    .with("completed",k.completed.exclude(Set(job)))}
  action parentRead = all {P::readCurrent,k' = k}
  action parentQualify = all {P::qualify,k' = k}
  action parentBegin(id,v,value) = all {P::begin(id,v,value),k' = k}
  action parentCommit(id) = all {P::commit(id),k' = k}
  action parentResolve(id) = all {P::resolve(id),k' = k}
  action parentElection = all {P::election,k' = k}
  action parentRetire(v) = all {P::retire(v),k' = k}
  action parentDeliver(id) = all {P::deliver(id),k' = k}
  action parentRoot(value) = all {P::rootCommit(value,Set(0,1)),k' = k}
  action loseResponse = all {P::loseResponse,k' = k}
  val releaseGateAudit = k.exports.forall(e => e.gateOpen and e.ticket.epoch == e.epoch and e.ticket.statement.epoch == e.service)
  val exportedComputed = k.exports.forall(e => k.produced.contains(e.ticket))
  val originalReleased = k.exports.forall(e => P::s.released.contains(e.ticket.statement))
  val barrierSound = k.isolation < 0 or k.deviceIsolated
  val qualifiedBoundary = k.enabled implies (k.floorKnown and k.isolation == k.epoch and k.deviceIsolated and k.activeService == P::s.epoch)
  val floorObservationCurrent = k.floorKnown implies k.isolation == k.epoch
  val safety = floorObservationCurrent and P::safety and releaseGateAudit and exportedComputed and originalReleased and barrierSound and qualifiedBoundary
  action step = {
    nondet job = jobIds.oneOf()
    nondet id = P::ids.oneOf()
    nondet h = jobIds.oneOf()
    nondet v = P::voters.oneOf()
    nondet value = Set(1,2).oneOf()
    any {parentRead,parentQualify,parentBegin(id,v,value),parentCommit(id),parentResolve(id),parentElection,parentRetire(v),parentDeliver(id),parentRoot(value),
      issueHandle(h,v),enqueue(job,id,h),start(job),complete(job,k.tickets.get(job),true),emit(job),close,isolate(true),observeBarrier,
      advance(true),observeFloor(true),activate(true),loseBuffer(job),loseResponse}
  }
  action recover = close.then(isolate(true)).then(observeBarrier).then(advance(true)).then(observeFloor(true)).then(parentRead).then(parentQualify).then(activate(true))
  action boot = init.then(recover)
  action durable = boot.then(parentBegin(0,0,1)).then(parentCommit(0)).then(parentResolve(0)).then(issueHandle(0,0))
  action queued = durable.then(enqueue(0,0,0))
  action running = queued.then(start(0))
  action computed = running.then(complete(0,k.tickets.get(0),true))
  action signed = computed.then(emit(0))
  run normalQueueCommitReleaseTest = signed.expect(safety and k.exports.size() == 1)
  run queueRequiresProtectedCommitTest = boot.then(parentBegin(0,0,1)).then(issueHandle(0,0)).then(enqueue(0,0,0).fail())
  run queueRequiresResolvedCommitTest = boot.then(parentBegin(0,0,1)).then(parentCommit(0)).then(issueHandle(0,0)).then(enqueue(0,0,0).fail())
  run wrongSignerHandleRejectedTest = durable.then(issueHandle(1,1)).then(enqueue(0,0,1).fail())
  run handleIdentityNeverRetaggedTest = durable.then(recover).then(issueHandle(0,0).fail())
  run queuedDigestCannotStartAfterCloseTest = queued.then(close).then(start(0).fail())
  run runningDigestCanCompleteButStaySealedTest = running.then(close).then(complete(0,k.tickets.get(0),true)).then(emit(0).fail())
  run completedOutputCannotEscapeAfterCloseTest = computed.then(close).then(emit(0).fail())
  run completeResponseMustMatchTicketTest = running.then(complete(0,emptyTicket,true).fail())
  run unauthenticDeviceResultRejectedTest = running.then(complete(0,k.tickets.get(0),false).fail())
  run lostDeviceResponseDoesNotRecreateOutputTest = running.then(loseResponse).then(emit(0).fail())
  run lostBarrierReplyCannotAdvanceTest = queued.then(close).then(isolate(true)).then(loseResponse).then(advance(true).fail())
  run authenticBarrierQueryCanResumeTest = queued.then(close).then(isolate(true)).then(loseResponse).then(observeBarrier).then(advance(true)).expect(safety)
  run lostFloorReplyCannotActivateTest = queued.then(close).then(isolate(true)).then(observeBarrier).then(advance(true))
    .then(parentRead).then(parentQualify).then(activate(true).fail())
  run lostFloorCommitCannotAllocateSecondEpochTest = queued.then(close).then(isolate(true)).then(observeBarrier).then(advance(true))
    .then(loseResponse).then(advance(true).fail())
  run originalFloorObservationCanResumeRecoveryTest = queued.then(close).then(isolate(true)).then(observeBarrier).then(advance(true))
    .then(loseResponse).then(observeFloor(true)).then(parentRead).then(parentQualify).then(activate(true)).expect(safety)
  run newIsolationCannotReuseOldFloorObservationTest = init.then(close).then(isolate(true)).then(observeBarrier).then(advance(true)).then(observeFloor(true))
    .then(isolate(true)).expect(safety and not(k.floorKnown))
  run fakePhysicalBarrierRejectedTest = queued.then(close).then(isolate(false).fail())
  run fakeFloorObservationRejectedTest = queued.then(close).then(isolate(true)).then(observeBarrier).then(advance(true)).then(observeFloor(false).fail())
  run cachedQualificationCannotOpenNewKeyEpochTest = queued.then(close).then(isolate(true)).then(observeBarrier).then(advance(true)).then(observeFloor(true))
    .then(activate(true).fail())
  run oldQueuedDigestSurvivesRestartButCannotStartTest = queued.then(recover).then(start(0).fail())
  run lateDeviceCompletionAfterRestartStaysSealedTest = running.then(recover).then(complete(0,k.tickets.get(0),true)).then(emit(0).fail())
  run oldCompletedBufferSurvivesRestartButCannotExportTest = computed.then(recover).then(emit(0).fail())
  run staleHandleCannotServeFreshRequestTest = computed.then(recover).then(parentBegin(1,0,1)).then(parentCommit(1)).then(parentResolve(1)).then(enqueue(1,1,0).fail())
  run freshHandleCanRepeatExactOriginalPrefixTest = signed.then(recover).then(parentBegin(1,0,1)).then(parentCommit(1)).then(parentResolve(1)).then(issueHandle(1,0))
    .then(enqueue(1,1,1)).then(start(1)).then(complete(1,k.tickets.get(1),true)).then(emit(1)).expect(safety and k.exports.size() == 2)
  run freshHandleCannotChangeOriginalPrefixTest = signed.then(recover).then(parentBegin(1,0,2)).then(parentCommit(1).fail())
  run usedTicketCannotBeReboundAfterBufferLossTest = queued.then(loseBuffer(0)).then(enqueue(0,0,0).fail())
  run retiredSignerCannotExportQueuedResultTest = computed.then(parentRetire(0)).then(emit(0).fail())
  run electionCannotRelabelQueuedDigestTest = computed.then(parentElection).then(emit(0).fail())
  run releasedOriginalMayDeliverAfterRevocationTest = signed.then(close).then(parentDeliver(0)).expect(safety and P::s.delivered.size() == 1)
  // Excluded device/adapter faults. These emit real model signatures outside the live gate.
  action unsafeAutomaticReply(job) = {
    val t = k.tickets.get(job)
    all {k.completed.contains(job),P::s' = P::s.with("released",P::s.released.union(Set(t.statement))),
      k' = k.with("exports",k.exports.union(Set({ticket:t,epoch:k.epoch,service:P::s.epoch,gateOpen:k.enabled})))}
  }
  action unsafeRawHandleReply(h,value) = {
    val old = k.registrations.get(h)
    val q = P::request(5,old.voter,value).with("epoch",old.service)
    val t = {requestId:5,statement:q,handleId:h,epoch:old.epoch}
    all {P::unsafeRawKey(old.voter,value,old.service),k' = k.with("exports",k.exports.union(Set({ticket:t,epoch:k.epoch,service:P::s.epoch,gateOpen:k.enabled})))}
  }
  action unsafeDigestSubstitution(job) = {
    val t = k.tickets.get(job)
    val changed = t.with("statement",t.statement.with("candidate",P::proposal(2)))
    all {P::loseResponse,k' = k.with("tickets",k.tickets.set(job,changed)).with("produced",k.produced.union(Set(changed)))}
  }
  action unsafeQueueEmptyBarrier = all {k.queued.size() == 0,P::loseResponse,k' = k.with("isolation",k.epoch+1).with("barrierKnown",true)}
  action unsafeWarmRestart = all {P::restart,k' = k.with("enabled",true)}
  run queuedAutomaticReplyAfterRevocationCounterexampleTest = running.then(close).then(complete(0,k.tickets.get(0),true))
    .then(unsafeAutomaticReply(0)).expect(not(releaseGateAudit))
  run oldRawHSMHandleAfterRestartCounterexampleTest = signed.then(recover).then(unsafeRawHandleReply(0,2)).expect(not(P::noConflictingRelease))
  run digestSubstitutionAtDeviceOutputCounterexampleTest = signed.then(unsafeDigestSubstitution(0)).then(unsafeAutomaticReply(0))
    .expect(not(P::durableBeforeRelease) and not(P::noConflictingRelease))
  run softwareQueueDrainIsNotIsolationCounterexampleTest = running.then(close).then(unsafeQueueEmptyBarrier).expect(not(barrierSound))
  run serviceRestartWithoutKeyFloorCounterexampleTest = signed.then(unsafeWarmRestart).expect(not(qualifiedBoundary))
}
