// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

// Scoped native isolation evidence and durable floor recovery over the real key model.
module DeviceIsolationRecovery {
  import KeyBoundaryQueue as K from "./KeyBoundaryQueue"
  type Alias = {kind:int,epoch:int,device:int,driver:int,generation:int}
  type Member = {id:int,alias:Alias}
  type Cut = {serial:int,device:int,driver:int,profile:int,oldFloor:int,oldService:int,members:Set[Member]}
  type Submission = {ticket:K::Ticket,device:int,driver:int,profile:int,dmaId:int,dma:Alias,callbackId:int,callback:Alias}
  type CallbackAudit = {job:int,actual:Submission,claimed:Submission}
  type State = {device:int,driver:int,profile:int,serial:int,service:int,registered:Set[int],aliases:int->Alias,blocked:Set[int],
    captured:Cut,haveCut:bool,certified:Cut,haveCert:bool,lastCertificate:Cut,journal:Set[Cut],accepted:Set[Cut],pendingFloor:Cut,havePending:bool,viewIntent:int,viewKnown:bool,viewFloor:int,viewService:int,viewHead:int,
    submitted:Set[int],submissions:int->Submission,validated:Set[int],archived:Set[Submission],callbacks:Set[CallbackAudit]}
  var d:State
  pure val aliasIds = 0.to(8)
  pure val emptyAlias = {kind:-1,epoch:-1,device:-1,driver:-1,generation:-1}
  pure val emptyCut = {serial:-1,device:-1,driver:-1,profile:-1,oldFloor:-1,oldService:-1,members:Set()}
  pure val emptySubmission = {ticket:K::emptyTicket,device:-1,driver:-1,profile:-1,dmaId:-1,dma:emptyAlias,callbackId:-1,callback:emptyAlias}
  pure val initial = {device:0,driver:0,profile:0,serial:0,service:0,registered:Set(),aliases:aliasIds.mapBy(_ => emptyAlias),blocked:Set(),
    captured:emptyCut,haveCut:false,certified:emptyCut,haveCert:false,lastCertificate:emptyCut,journal:Set(),accepted:Set(),pendingFloor:emptyCut,havePending:false,viewIntent:-1,viewKnown:false,viewFloor:-1,viewService:-1,viewHead:-1,
    submitted:Set(),submissions:K::jobIds.mapBy(_ => emptySubmission),validated:Set(),archived:Set(),callbacks:Set()}
  action init = all {K::init,d' = initial}
  def members(floor) = d.registered.filter(id => d.aliases.get(id).epoch <= floor).map(id => {id:id,alias:d.aliases.get(id)})
  def viewCurrent = d.viewKnown and d.viewFloor == K::k.epoch and d.viewService == d.service and d.viewHead == d.journal.size() and d.viewIntent == (if (d.havePending) d.pendingFloor.serial else -1)
  def context(c) = c.serial == d.serial and c.device == d.device and c.driver == d.driver and c.profile == d.profile and c.members == members(c.oldFloor)
  def before(c) = c.oldFloor == K::k.epoch and c.oldService == d.service
  def after(c) = c.oldFloor+1 == K::k.epoch and c.oldService+1 == d.service
  def allBlocked(c) = c.members.forall(m => d.blocked.contains(m.id))
  def hardwareReady = d.haveCert and context(d.certified) and after(d.certified) and allBlocked(d.certified) and viewCurrent
  def currentSubmission(q) = q.device == d.device and q.driver == d.driver and q.profile == d.profile and q.ticket.epoch == K::k.epoch and
    d.registered.contains(q.dmaId) and d.registered.contains(q.callbackId) and d.aliases.get(q.dmaId) == q.dma and d.aliases.get(q.callbackId) == q.callback and
    q.dma.kind == 1 and q.callback.kind == 2 and q.dma.device == d.device and q.callback.device == d.device and q.dma.driver == d.driver and q.callback.driver == d.driver and
    q.dma.epoch == K::k.epoch and q.callback.epoch == K::k.epoch
  action register(id,kind,authentic) = all {authentic,not(d.registered.contains(id)),not(d.haveCut) or K::k.enabled,K::loseResponse,
    d' = d.with("registered",d.registered.union(Set(id))).with("aliases",d.aliases.set(id,
      {kind:kind,epoch:K::k.epoch,device:d.device,driver:d.driver,generation:d.serial+id+1}))}
  action readFloor(history,floor,service,intent,authentic) = all {authentic,history == d.journal,floor == K::k.epoch,service == d.service,
    intent == (if (d.havePending) d.pendingFloor else emptyCut),K::loseResponse,
    d' = d.with("viewKnown",true).with("viewFloor",floor).with("viewService",service).with("viewHead",history.size()).with("viewIntent",if (d.havePending) d.pendingFloor.serial else -1)}
  action readCurrent = readFloor(d.journal,K::k.epoch,d.service,if (d.havePending) d.pendingFloor else emptyCut,true)
  action close = all {K::close,d' = d.with("serial",d.serial+1).with("haveCut",false).with("haveCert",false).with("viewKnown",false)}
  action seal = {
    val c = {serial:d.serial+1,device:d.device,driver:d.driver,profile:d.profile,oldFloor:K::k.epoch,oldService:d.service,members:members(K::k.epoch)}
    all {not(K::k.enabled),viewCurrent,not(d.havePending),K::loseResponse,d' = d.with("serial",c.serial).with("captured",c).with("haveCut",true).with("haveCert",false)}
  }
  action block(id,authentic) = all {authentic,d.haveCut,context(d.captured),before(d.captured),d.captured.members.exists(m => m.id == id),K::loseResponse,
    d' = d.with("blocked",d.blocked.union(Set(id)))}
  action blockAll(authentic) = all {authentic,d.haveCut,context(d.captured),before(d.captured),K::loseResponse,
    d' = d.with("blocked",d.blocked.union(d.captured.members.map(m => m.id)))}
  action certify(receipt,authentic) = all {authentic,d.haveCut,receipt == d.captured,context(receipt),before(receipt),allBlocked(receipt),K::isolate(true),
    d' = d.with("certified",receipt).with("haveCert",true).with("lastCertificate",receipt)}
  action observeBarrier = all {d.haveCert,context(d.certified),before(d.certified),allBlocked(d.certified),K::observeBarrier,d' = d}
  action prepareFloor = all {not(K::k.enabled),d.haveCert,context(d.certified),before(d.certified),allBlocked(d.certified),K::k.barrierKnown,not(d.havePending),K::loseResponse,
    d' = d.with("pendingFloor",d.certified).with("havePending",true).with("viewKnown",false).with("accepted",d.accepted.union(Set(d.certified)))}
  action commitFloor = all {d.havePending,d.pendingFloor == d.certified,d.haveCert,context(d.certified),before(d.certified),allBlocked(d.certified),K::advance(true),
    d' = d.with("journal",d.journal.union(Set(d.certified))).with("service",d.service+1).with("viewKnown",false).with("havePending",false)}
  action liveFloor = all {hardwareReady,K::observeFloor(true),d' = d}
  action activate(authentic) = all {authentic,hardwareReady,K::activate(true),d' = d}
  action resetDevice(profile) = all {K::close,d' = d.with("device",d.device+1).with("driver",d.driver+1).with("profile",profile).with("serial",d.serial+1)
    .with("blocked",Set()).with("haveCut",false).with("haveCert",false).with("viewKnown",false)}
  action restartDriver(staleFloor) = all {K::close,d' = d.with("driver",d.driver+1).with("serial",d.serial+1).with("blocked",Set())
    .with("haveCut",false).with("haveCert",false).with("viewKnown",false).with("viewFloor",staleFloor)}
  action enqueue(job,id,h,dmaId,callbackId) = {
    // The parent builds the actual protected statement. Capture its queued ticket in a subsequent exact binding action.
    all {hardwareReady,not(d.submitted.contains(job)),d.registered.contains(dmaId),d.registered.contains(callbackId),
      d.aliases.get(dmaId).kind == 1,d.aliases.get(callbackId).kind == 2,
      d.aliases.get(dmaId).device == d.device,d.aliases.get(callbackId).device == d.device,
      d.aliases.get(dmaId).driver == d.driver,d.aliases.get(callbackId).driver == d.driver,
      d.aliases.get(dmaId).epoch == K::k.epoch,d.aliases.get(callbackId).epoch == K::k.epoch,
      K::enqueue(job,id,h),d' = d}
  }
  action bind(job,dmaId,callbackId) = {
    val q = {ticket:K::k.tickets.get(job),device:d.device,driver:d.driver,profile:d.profile,
      dmaId:dmaId,dma:d.aliases.get(dmaId),callbackId:callbackId,callback:d.aliases.get(callbackId)}
    all {hardwareReady,K::k.queued.contains(job),not(d.submitted.contains(job)),currentSubmission(q),K::loseResponse,
      d' = d.with("submitted",d.submitted.union(Set(job))).with("submissions",d.submissions.set(job,q))}
  }
  action start(job) = all {hardwareReady,d.submitted.contains(job),currentSubmission(d.submissions.get(job)),K::start(job),d' = d}
  action complete(job,receipt,authentic) = all {authentic,d.submitted.contains(job),receipt == d.submissions.get(job),currentSubmission(receipt),
    K::complete(job,receipt.ticket,true),d' = d.with("validated",d.validated.union(Set(job)))
      .with("callbacks",d.callbacks.union(Set({job:job,actual:receipt,claimed:receipt})))}
  action emit(job) = all {hardwareReady,d.submitted.contains(job),d.validated.contains(job),currentSubmission(d.submissions.get(job)),K::emit(job),d' = d}
  action archiveCallback(job,receipt,authentic) = all {authentic,d.submitted.contains(job),receipt == d.submissions.get(job),K::loseResponse,
    d' = d.with("archived",d.archived.union(Set(receipt)))}
  action parentRead = all {K::parentRead,d' = d}
  action parentQualify = all {K::parentQualify,d' = d}
  action parentBegin(id,v,value) = all {K::parentBegin(id,v,value),d' = d}
  action parentCommit(id) = all {K::parentCommit(id),d' = d}
  action parentResolve(id) = all {K::parentResolve(id),d' = d}
  action parentHandle(id,v) = all {hardwareReady,K::issueHandle(id,v),d' = d}
  action parentElection = all {K::parentElection,d' = d}
  action parentRetire(v) = all {K::parentRetire(v),d' = d}
  action parentDeliver(id) = all {K::parentDeliver(id),d' = d}
  action parentRoot(value) = all {K::parentRoot(value),d' = d}
  action loseBuffer(job) = all {K::loseBuffer(job),d' = d}
  action loseResponse = all {K::loseResponse,d' = d}
  val journalComplete = d.journal.size() == K::k.epoch and d.journal.forall(c => c.oldFloor < K::k.epoch) and
    0.to(K::k.epoch-1).forall(position => d.journal.filter(c => c.oldFloor == position).size() == 1)
  val viewSound = d.viewKnown implies (d.viewFloor == K::k.epoch and d.viewService == d.service and d.viewHead == d.journal.size() and d.viewIntent == (if (d.havePending) d.pendingFloor.serial else -1))
  val certificateCurrent = d.haveCert implies (context(d.certified) and allBlocked(d.certified))
  val callbackSound = d.callbacks.forall(e => e.actual == e.claimed)
  val activeHardware = K::k.enabled implies hardwareReady
  val intentConserved = d.accepted.forall(c => d.journal.contains(c) or (d.havePending and d.pendingFloor == c))
  val safety = intentConserved and K::safety and journalComplete and viewSound and certificateCurrent and callbackSound and activeHardware
  action step = {
    nondet job = K::jobIds.oneOf()
    nondet id = K::jobIds.oneOf()
    nondet a = aliasIds.oneOf()
    nondet b = aliasIds.oneOf()
    nondet kind = 0.to(2).oneOf()
    nondet v = 0.to(2).oneOf()
    nondet value = Set(1,2).oneOf()
    any {parentRead,parentQualify,parentBegin(id,v,value),parentCommit(id),parentResolve(id),parentHandle(id,v),parentElection,parentRetire(v),parentDeliver(id),parentRoot(value),
      register(a,kind,true),readCurrent,close,seal,block(a,true),blockAll(true),certify(d.captured,true),observeBarrier,prepareFloor,commitFloor,liveFloor,activate(true),
      resetDevice(d.profile),restartDriver(0),enqueue(job,id,id,a,b),bind(job,a,b),start(job),complete(job,d.submissions.get(job),true),emit(job),
      archiveCallback(job,d.submissions.get(job),true),loseBuffer(job),loseResponse}
  }
  action initialAliases = register(0,0,true).then(register(1,1,true)).then(register(2,2,true))
  action newAliases = register(3,0,true).then(register(4,1,true)).then(register(5,2,true))
  action freshAliases = register(6,0,true).then(register(7,1,true)).then(register(8,2,true))
  action recover = readCurrent.then(seal).then(blockAll(true)).then(certify(d.captured,true)).then(observeBarrier).then(prepareFloor).then(commitFloor)
    .then(readCurrent).then(liveFloor).then(parentRead).then(parentQualify).then(activate(true))
  action boot = init.then(initialAliases).then(recover).then(newAliases)
  action durable = boot.then(parentBegin(0,0,1)).then(parentCommit(0)).then(parentResolve(0)).then(parentHandle(0,0))
  action queued = durable.then(enqueue(0,0,0,4,5)).then(bind(0,4,5))
  action running = queued.then(start(0))
  action computed = running.then(complete(0,d.submissions.get(0),true))
  action signed = computed.then(emit(0))
  action barrierPending = queued.then(close).then(readCurrent).then(seal).then(blockAll(true)).then(certify(d.captured,true))
  run exactScopedIsolationAndFloorTest = boot.expect(safety and K::k.epoch == 1)
  run oldFDPreventsIsolationTest = init.then(initialAliases).then(readCurrent).then(seal).then(block(1,true)).then(block(2,true)).then(certify(d.captured,true).fail())
  run wrongProfileReceiptRejectedTest = init.then(initialAliases).then(readCurrent).then(seal).then(blockAll(true))
    .then(certify(d.captured.with("profile",9),true).fail())
  run missingAliasRosterRejectedTest = init.then(initialAliases).then(readCurrent).then(seal).then(blockAll(true))
    .then(certify(d.captured.with("members",d.captured.members.filter(m => m.id != 0)),true).fail())
  run falseNativeIsolationReceiptRejectedTest = init.then(initialAliases).then(readCurrent).then(seal).then(blockAll(true)).then(certify(d.captured,false).fail())
  run resetInvalidatesOldIsolationReceiptTest = barrierPending.then(resetDevice(0)).then(certify(d.lastCertificate,true).fail())
  run resetDoesNotEraseCommittedFloorTest = computed.then(resetDevice(0)).expect(safety and K::k.epoch == 1 and d.journal.size() == 1)
  run historicalFloorReadAfterResetIsValidTest = computed.then(resetDevice(0)).then(readCurrent).expect(safety and viewCurrent and not(d.haveCert))
  run historicalFloorReadCannotActivateHardwareTest = computed.then(resetDevice(0)).then(readCurrent).then(liveFloor.fail())
  run oldDeviceCounterCannotRestoreFloorTest = computed.then(restartDriver(0)).then(readFloor(d.journal,0,d.service,emptyCut,true).fail())
  run staleFloorPrefixCannotQualifyReadTest = computed.then(resetDevice(0)).then(readFloor(Set(),1,d.service,emptyCut,true).fail())
  run forgedFloorReadRejectedTest = computed.then(resetDevice(0)).then(readFloor(d.journal,1,d.service,emptyCut,false).fail())
  run lostBarrierReplyStaysClosedTest = barrierPending.then(loseResponse).then(prepareFloor.fail())
  run authenticBarrierQueryResumesOriginalCutTest = barrierPending.then(loseResponse).then(observeBarrier).then(prepareFloor).then(commitFloor).expect(safety and K::k.epoch == 2)
  run floorCommitReplyLostThenResetKeepsHistoryTest = barrierPending.then(observeBarrier).then(prepareFloor).then(commitFloor).then(loseResponse).then(resetDevice(0))
    .then(readCurrent).expect(safety and K::k.epoch == 2 and d.journal.size() == 2 and not(K::k.enabled))
  run unknownFloorCommitCannotAllocateSameSuccessorTest = barrierPending.then(observeBarrier).then(prepareFloor).then(commitFloor).then(loseResponse).then(commitFloor.fail())
  run preparedFloorIntentSurvivesResetTest = barrierPending.then(observeBarrier).then(prepareFloor).then(loseResponse).then(resetDevice(0)).then(readCurrent)
    .expect(safety and d.havePending and K::k.epoch == 1)
  run unresolvedIntentPreventsNewCutTest = barrierPending.then(observeBarrier).then(prepareFloor).then(resetDevice(0)).then(readCurrent).then(seal.fail())
  run preparedOldCutCannotCommitAfterResetTest = barrierPending.then(observeBarrier).then(prepareFloor).then(resetDevice(0)).then(commitFloor.fail())
  run recoveryReadCannotOmitPendingIntentTest = barrierPending.then(observeBarrier).then(prepareFloor).then(resetDevice(0))
    .then(readFloor(d.journal,1,d.service,emptyCut,true).fail())
  run oldCompletedDMACannotExportAfterResetTest = computed.then(resetDevice(0)).then(emit(0).fail())
  run oldDeviceCallbackCannotCompleteCurrentStateTest = running.then(resetDevice(0)).then(complete(0,d.submissions.get(0),true).fail())
  run oldCallbackMayArchiveOriginalOnlyTest = running.then(resetDevice(0)).then(archiveCallback(0,d.submissions.get(0),true)).expect(safety and d.archived.size() == 1)
  run forgedLateCallbackCannotEnterArchiveTest = running.then(resetDevice(0)).then(archiveCallback(0,d.submissions.get(0),false).fail())
  run alteredDMAGenerationRejectedTest = running.then(complete(0,d.submissions.get(0).with("dma",d.submissions.get(0).dma.with("generation",99)),true).fail())
  run forgedCallbackRejectedTest = running.then(complete(0,d.submissions.get(0),false).fail())
  run aliasIdentityCannotRetagAfterResetTest = computed.then(resetDevice(0)).then(register(4,1,true).fail())
  run lostBufferDoesNotReopenJobIDTest = queued.then(loseBuffer(0)).then(enqueue(0,0,0,4,5).fail())
  action freshPending = running.then(resetDevice(0)).then(recover).then(freshAliases).then(parentBegin(1,0,1)).then(parentCommit(1)).then(parentResolve(1))
    .then(parentHandle(1,0)).then(enqueue(1,1,1,7,8)).then(bind(1,7,8)).then(start(1))
  run oldCallbackCannotCompleteNewJobTest = freshPending.then(complete(1,d.submissions.get(0),true).fail())
  run exactFreshCallbackCanReleaseOriginalPrefixTest = freshPending.then(complete(1,d.submissions.get(1),true)).then(emit(1)).expect(safety)
  run alreadyEmittedOriginalMayDeliverAfterResetTest = signed.then(resetDevice(0)).then(parentDeliver(0)).expect(safety)
  // Unsafe recovery adapters, not members of step.
  action unsafeReplayIsolation = all {K::isolate(true),d' = d.with("haveCert",true).with("certified",d.lastCertificate)}
  action unsafeOmitOldFD = {
    val c = d.captured.with("members",d.captured.members.filter(m => m.id != 0))
    all {K::isolate(true),d' = d.with("certified",c).with("haveCert",true)}
  }
  action unsafeLeakDMA(job) = all {K::unsafeAutomaticReply(job),d' = d}
  action unsafeRebindCallback(oldJob,newJob) = all {K::complete(newJob,K::k.tickets.get(newJob),true),d' = d.with("validated",d.validated.union(Set(newJob)))
    .with("callbacks",d.callbacks.union(Set({job:newJob,actual:d.submissions.get(oldJob),claimed:d.submissions.get(newJob)})))}
  action unsafeTrustDeviceFloor = all {K::loseResponse,d' = d.with("viewKnown",true).with("viewFloor",0).with("viewService",d.service).with("viewHead",d.journal.size())}
  action unsafeForgetAcceptedIntent = all {K::loseResponse,d' = d.with("havePending",false)}
  action unsafeLoseCommittedFloorRow = all {K::loseResponse,d' = d.with("journal",Set())}
  run resetReceiptReplayCounterexampleTest = barrierPending.then(resetDevice(0)).then(unsafeReplayIsolation).expect(not(certificateCurrent))
  run omittedOldFDIsolationCounterexampleTest = init.then(initialAliases).then(readCurrent).then(seal).then(block(1,true)).then(block(2,true))
    .then(unsafeOmitOldFD).expect(not(certificateCurrent))
  run retainedDMABufferLeaksOnResetCounterexampleTest = computed.then(resetDevice(0)).then(unsafeLeakDMA(0)).expect(not(K::releaseGateAudit))
  run lateCallbackRelabelsNewJobCounterexampleTest = freshPending.then(unsafeRebindCallback(0,1)).expect(not(callbackSound))
  run resettableDeviceCounterRestoresFloorCounterexampleTest = computed.then(resetDevice(0)).then(unsafeTrustDeviceFloor).expect(not(viewSound))
  run resetForgetsAcceptedFloorIntentCounterexampleTest = barrierPending.then(observeBarrier).then(prepareFloor).then(resetDevice(0))
    .then(unsafeForgetAcceptedIntent).expect(not(intentConserved))
  run floorScalarWithoutCommitPrefixCounterexampleTest = computed.then(unsafeLoseCommittedFloorRow).expect(not(journalComplete))
}
