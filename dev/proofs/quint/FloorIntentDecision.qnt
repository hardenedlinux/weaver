// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

// Durable intent decisions precede acknowledgement; fences never erase acceptance.
module FloorIntentDecision {
  import DeviceIsolationRecovery as D from "./DeviceIsolationRecovery"
  type Intent = {id:int,cut:D::Cut,worker:int,fence:int}
  type Resolution = {intent:Intent,kind:int}
  type State = {worker:int,fence:int,accepted:Set[Intent],decisions:Set[Resolution],haveSlot:bool,slot:Intent,observed:bool,receipt:Resolution}
  var f:State
  pure val emptyIntent = {id:-1,cut:D::emptyCut,worker:-1,fence:-1}
  pure val emptyResolution = {intent:emptyIntent,kind:0}
  pure val initial = {worker:0,fence:0,accepted:Set(),decisions:Set(),haveSlot:false,slot:emptyIntent,observed:false,receipt:emptyResolution}
  action init = all {D::init,f' = initial}
  def decided(i) = f.decisions.exists(r => r.intent == i)
  def committed(i) = f.decisions.contains({intent:i,kind:1})
  def unlocked = not(f.haveSlot)
  action accept(worker) = {
    val i = {id:f.accepted.size(),cut:D::d.certified,worker:worker,fence:f.fence}
    all {worker == f.worker,unlocked,D::prepareFloor,
      f' = f.with("accepted",f.accepted.union(Set(i))).with("haveSlot",true).with("slot",i).with("observed",false)}
  }
  action decide(i,worker) = all {f.haveSlot,i == f.slot,worker == f.worker,i.worker == worker,i.fence == f.fence,not(decided(i)),
    D::commitFloor,f' = f.with("decisions",f.decisions.union(Set({intent:i,kind:1}))).with("observed",false)}
  def fencedDecisions = if (f.haveSlot and not(decided(f.slot))) f.decisions.union(Set({intent:f.slot,kind:2})) else f.decisions
  action reset = all {D::resetDevice(D::d.profile),f' = f.with("worker",f.worker+1).with("fence",f.fence+1)
    .with("decisions",fencedDecisions).with("observed",false)}
  action restart = all {D::restartDriver(0),f' = f.with("worker",f.worker+1).with("fence",f.fence+1)
    .with("decisions",fencedDecisions).with("observed",false)}
  action close = all {D::close,f' = f.with("worker",f.worker+1).with("fence",f.fence+1)
    .with("decisions",fencedDecisions).with("observed",false)}
  // Authoritative reads bind the full decision prefix and current recovery session.
  action observe(r,prefix,worker,authentic) = all {authentic,worker == f.worker,prefix == f.decisions,f.haveSlot,r.intent == f.slot,
    f.decisions.contains(r),D::loseResponse,f' = f.with("observed",true).with("receipt",r)}
  action readDecision = observe({intent:f.slot,kind:if (committed(f.slot)) 1 else 2},f.decisions,f.worker,true)
  action acknowledge = all {f.haveSlot,f.observed,f.receipt == {intent:f.slot,kind:1},committed(f.slot),D::loseResponse,
    f' = f.with("haveSlot",false).with("observed",false)}
  action loseResponse = all {D::loseResponse,f' = f}
  action readCurrent = all {D::readCurrent,f' = f}
  action seal = all {unlocked,D::seal,f' = f}
  action blockAll = all {D::blockAll(true),f' = f}
  action certify = all {D::certify(D::d.captured,true),f' = f}
  action barrier = all {D::observeBarrier,f' = f}
  action liveFloor = all {unlocked,D::liveFloor,f' = f}
  action activate = all {unlocked,D::activate(true),f' = f}
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
  val conserved = f.accepted.forall(i => committed(i) or (f.haveSlot and f.slot == i))
  val uniqueDecision = f.decisions.forall(a => f.decisions.forall(b => a.intent == b.intent implies a == b))
  val journalBound = f.decisions.filter(r => r.kind == 1).forall(r => D::d.journal.contains(r.intent.cut))
  val fenceBound = f.decisions.filter(r => r.kind == 2).forall(r => not(D::d.journal.contains(r.intent.cut)))
  val slotBound = f.haveSlot implies (if (committed(f.slot)) D::d.journal.contains(f.slot.cut) else D::d.havePending and D::d.pendingFloor == f.slot.cut)
  val observationBound = f.observed implies f.haveSlot and f.receipt.intent == f.slot and f.decisions.contains(f.receipt)
  val safety = D::safety and conserved and uniqueDecision and journalBound and fenceBound and slotBound and observationBound
  action step = {
    nondet job = 0.to(5).oneOf()
    nondet a = 0.to(8).oneOf()
    nondet b = 0.to(8).oneOf()
    nondet kind = 0.to(2).oneOf()
    nondet v = 0.to(2).oneOf()
    nondet value = Set(1,2).oneOf()
    any {accept(f.worker),decide(f.slot,f.worker),reset,restart,close,readDecision,acknowledge,loseResponse,readCurrent,seal,blockAll,certify,barrier,
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
  run durableAcceptanceTest = pending.expect(safety and f.haveSlot)
  run commitBeforeFenceLostResponseTest = committedPending.then(loseResponse).then(reset).then(readDecision).then(acknowledge).expect(safety and unlocked)
  run historicalCommitRequiresFreshCutTest = committedPending.then(reset).then(readDecision).then(acknowledge).then(readCurrent).then(seal).expect(safety)
  run fenceBeforeDecisionRejectsLateCommitTest = fencedPending.then(decide(f.slot,f.worker-1).fail())
  run fencedResolutionDoesNotUnlockTest = fencedPending.then(readDecision).then(acknowledge.fail())
  run missingObservationCannotUnlockTest = committedPending.then(acknowledge.fail())
  run duplicateDecisionRejectedTest = committedPending.then(decide(f.slot,f.worker).fail())
  run staleWorkerCannotAcceptTest = boot.then(close).then(readCurrent).then(seal).then(blockAll).then(certify).then(barrier).then(accept(f.worker-1).fail())
  run staleRecoverySessionRejectedTest = committedPending.then(reset).then(observe({intent:f.slot,kind:1},f.decisions,f.worker-1,true).fail())
  run stalePrefixRejectedTest = committedPending.then(observe({intent:f.slot,kind:1},Set(),f.worker,true).fail())
  run falseDecisionReceiptRejectedTest = committedPending.then(observe({intent:f.slot,kind:1},f.decisions,f.worker,false).fail())
  run wrongCutReceiptRejectedTest = committedPending.then(observe({intent:f.slot.with("cut",D::emptyCut),kind:1},f.decisions,f.worker,true).fail())
  run restartPreservesUnresolvedTest = pending.then(restart).then(loseResponse).then(readDecision).then(acknowledge.fail())
  run resetInvalidatesObservedSessionTest = committedPending.then(readDecision).then(reset).then(acknowledge.fail())
  run secondCutPreservesOriginalDecisionTest = committedPending.then(readDecision).then(acknowledge).then(close).then(prepare).expect(safety and f.accepted.size() == 3)
  run fencedCurrentWorkerCannotCommitTest = fencedPending.then(decide(f.slot,f.worker).fail())
  run fencedNewCutRejectedTest = fencedPending.then(readCurrent).then(seal.fail())
  run historicalReceiptCannotActivateTest = committedPending.then(reset).then(readDecision).then(acknowledge).then(activate.fail())
  run currentSessionRecoversHistoricalCommitTest = committedPending.then(readDecision).then(reset).then(readDecision).then(acknowledge).expect(safety)
  run originalActualReleaseStillWorksTest = signed.expect(safety)
  // Deliberately unsafe mutations are test-only; none appears in step.
  action unsafeForget = all {D::loseResponse,f' = f.with("haveSlot",false).with("observed",false)}
  action unsafeLateCommit = all {D::loseResponse,f' = f.with("decisions",f.decisions.union(Set({intent:f.slot,kind:1})))}
  action unsafeEraseDecision = all {D::loseResponse,f' = f.with("decisions",Set())}
  action unsafeAcknowledge = all {D::loseResponse,f' = f.with("haveSlot",false)}
  action unsafeRelabelReceipt = all {D::loseResponse,f' = f.with("observed",true).with("receipt",{intent:emptyIntent,kind:1})}
  run timeoutUnlockCounterexampleTest = pending.then(loseResponse).then(unsafeForget).expect(not(conserved))
  run lateCommitAfterFenceCounterexampleTest = fencedPending.then(unsafeLateCommit).expect(not(uniqueDecision) and not(journalBound))
  run rollbackDecisionPrefixCounterexampleTest = committedPending.then(readDecision).then(acknowledge).then(unsafeEraseDecision).expect(not(conserved))
  run negativeResolutionUnlockCounterexampleTest = fencedPending.then(readDecision).then(unsafeAcknowledge).expect(not(conserved))
  run oldWorkerReceiptRelabelCounterexampleTest = committedPending.then(reset).then(unsafeRelabelReceipt).expect(not(observationBound))
}
