// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

// Qualified root publication is assumed; broker authority is modeled separately.
module AnchorBrokerCommit {
  import GateConsumptionPersistence as G from "./GateConsumptionPersistence"
  type Entry = {root:int,config:int,term:int,index:int,phase:int,key:int,epoch:int,image:G::Journal}
  type Dispatch = {entry:Entry,observedTerm:int,observedEpoch:int}
  type State = {term:int,head:int,log:Set[Entry],proposals:Set[Entry],replies:Set[Entry],
    grants:Set[int],grantRows:int->Entry,burns:Set[int],burnRows:int->Entry,
    sent:Set[int],dispatchRows:int->Dispatch,dispatchCount:int->int,
    readTerm:int,readHead:int,readImage:G::Journal,fencedTerm:int,writerTerm:int,writerEpoch:int,gateOpen:bool,barrierTerm:int,active:bool}
  var n:State
  pure val domain = 17
  pure val configuration = 5
  pure val emptyEntry = {root:domain,config:configuration,term:0,index:0,phase:0,key:0,epoch:0,image:G::emptyJournal}
  pure val initial = {term:0,head:0,log:Set(),proposals:Set(),replies:Set(),grants:Set(),
    grantRows:G::messageKeys.mapBy(_ => emptyEntry),burns:Set(),burnRows:G::messageKeys.mapBy(_ => emptyEntry),
    sent:Set(),dispatchRows:G::messageKeys.mapBy(_ => {entry:emptyEntry,observedTerm:0,observedEpoch:0}),
    dispatchCount:G::messageKeys.mapBy(_ => 0),readTerm:-1,readHead:0,readImage:G::emptyJournal,fencedTerm:-1,writerTerm:0,writerEpoch:0,gateOpen:true,barrierTerm:-1,active:true}
  action initWith(ranges) = all {G::initWith(ranges),n' = initial}
  action init = initWith(3)
  action emptyInit = initWith(0)
  action singletonInit = initWith(1)
  action largerInit = initWith(5)
  action baseStay = all {G::baseStay,G::g' = G::g}
  def proposal(phase,k) = {root:domain,config:configuration,term:n.term,index:n.head,phase:phase,key:k,
    epoch:if (phase == 4) G::g.root.epoch+1 else G::g.root.epoch,image:G::g.root}
  pure def samePosition(a,b) = a.root == b.root and a.config == b.config and a.index == b.index
  def qualified(e) = n.log.contains(e)
  // Deterministic fixture selectors: each fixture has one row of its target phase.
  def logged(phase) = n.log.fold(emptyEntry,(selected,e) => if (e.phase == phase) e else selected)
  def staged(phase) = n.proposals.fold(emptyEntry,(selected,e) => if (e.phase == phase) e else selected)
  action propose(e) = all {baseStay,n' = n.with("proposals",n.proposals.union(Set(e)))}
  action commit(e,durable,barrier) = all {durable,n.proposals.contains(e),e.root == domain,e.config == configuration,
    e.term == n.term,e.index == n.head,e.image == G::g.root,n.log.forall(old => old.index != n.head),
    e.epoch == (if (e.phase == 4) G::g.root.epoch+1 else G::g.root.epoch),
    n.active or e.phase == 3 or e.phase == 4,
    any {
      all {e.phase == 0,G::sealRoot(e.key)},
      all {e.phase == 1,G::grant(e.key)},
      all {e.phase == 2,n.grants.contains(e.key),n.grantRows.get(e.key).epoch == G::g.root.epoch,G::burn(e.key)},
      all {e.phase == 3,G::archive(e.key,G::g.root.burnPermits.get(e.key),true)},
      all {e.phase == 4,n.barrierTerm == n.term,not(n.gateOpen),n.writerTerm == n.term,
        n.writerEpoch == e.epoch,G::fence(barrier)}},
    n' = n.with("log",n.log.union(Set(e))).with("head",n.head+1).with("replies",n.replies.union(Set(e)))
      .with("fencedTerm",if (e.phase == 4) n.term else n.fencedTerm)}
  action acknowledgeGrant(e) = all {n.gateOpen,n.replies.contains(e),qualified(e),e.phase == 1,
    e.term == n.writerTerm,e.epoch == n.writerEpoch,not(n.grants.contains(e.key)),baseStay,
    n' = n.with("grants",n.grants.union(Set(e.key))).with("grantRows",n.grantRows.set(e.key,e))}
  action acknowledgeBurn(e) = all {n.gateOpen,n.replies.contains(e),qualified(e),e.phase == 2,
    e.term == n.writerTerm,e.epoch == n.writerEpoch,not(n.burns.contains(e.key)),baseStay,
    n' = n.with("burns",n.burns.union(Set(e.key))).with("burnRows",n.burnRows.set(e.key,e))}
  action dispatch(k) = {
    val e = n.burnRows.get(k)
    all {n.gateOpen,n.burns.contains(k),qualified(e),e.phase == 2,e.key == k,
      e.term == n.writerTerm,e.epoch == n.writerEpoch,not(n.sent.contains(k)),baseStay,
      n' = n.with("sent",n.sent.union(Set(k))).with("dispatchRows",n.dispatchRows.set(k,
        {entry:e,observedTerm:n.writerTerm,observedEpoch:n.writerEpoch}))
        .with("dispatchCount",n.dispatchCount.set(k,n.dispatchCount.get(k)+1))}
  }
  action complete(k) = all {n.sent.contains(k),G::complete(k),n' = n}
  action changeLeader = all {G::loseJournal(G::g.disk),n' = n.with("term",n.term+1).with("active",false)
    .with("readTerm",-1).with("fencedTerm",-1).with("barrierTerm",-1)}
  action loseJournal = all {G::loseJournal(G::emptyJournal),n' = n.with("active",false)
    .with("readTerm",-1).with("fencedTerm",-1).with("barrierTerm",-1).with("replies",Set())}
  action acceptBarrier(rootId,configId,term,targetEpoch,authentic) = all {authentic,rootId == domain,configId == configuration,
    term == n.term,targetEpoch == G::g.root.epoch+1,n.writerEpoch <= targetEpoch,baseStay,
    n' = n.with("gateOpen",false).with("writerTerm",n.term).with("writerEpoch",targetEpoch).with("barrierTerm",term)}
  action isolateWriter(authentic) = acceptBarrier(domain,configuration,n.term,G::g.root.epoch+1,authentic)
  action readCurrent(rootId,configId,term,position,image,authentic) = all {authentic,rootId == domain,configId == configuration,term == n.term,position == n.head,image == G::g.root,baseStay,
    n' = n.with("readTerm",term).with("readHead",position).with("readImage",image)}
  action activate = all {n.readTerm == n.term,n.readHead == n.head,n.readImage == G::g.root,n.fencedTerm == n.term,
    n.barrierTerm == n.term,n.writerTerm == n.term,n.writerEpoch == G::g.root.epoch,
    G::ready,baseStay,n' = n.with("active",true).with("gateOpen",true)}
  action dropReply(e) = all {baseStay,n' = n.with("replies",n.replies.exclude(Set(e)))}
  action rebuild = all {G::rebuild,n' = n}
  action sourceStep = all {G::sourceStep,n' = n}
  action anchor(k) = all {G::anchor(k),n' = n}
  action confirm(k) = all {G::confirm(k),n' = n}
  action materialize(k) = all {G::materialize(k),n' = n}
  action loseReply = all {baseStay,n' = n}
  val prefixSafety = n.log.forall(a => a.root == domain and a.config == configuration and a.index < n.head and
    a.term <= n.term and n.log.forall(b => samePosition(a,b) implies a == b))
  val bindingSafety = n.grants.forall(k => qualified(n.grantRows.get(k)) and n.grantRows.get(k).phase == 1) and
    n.burns.forall(k => qualified(n.burnRows.get(k)) and n.burnRows.get(k).phase == 2)
  val dispatchSafety = n.sent.forall(k => {
    val d = n.dispatchRows.get(k)
    qualified(d.entry) and d.entry.phase == 2 and d.entry.key == k and d.entry.term == d.observedTerm and
      d.entry.epoch == d.observedEpoch and G::g.root.burns.contains(k) and
      d.entry.image.permits.get(k) == G::g.root.burnPermits.get(k)
  }) and G::messageKeys.forall(k => n.dispatchCount.get(k) <= 1 and (n.sent.contains(k) iff n.dispatchCount.get(k) == 1))
  val safety = G::safety and prefixSafety and bindingSafety and dispatchSafety
  action step = {
    nondet k = G::messageKeys.oneOf()
    nondet phase = 0.to(4).oneOf()
    nondet e = (n.proposals.union(n.replies).union(Set(proposal(phase,k)))).oneOf()
    any {sourceStep,anchor(k),propose(proposal(phase,k)),commit(e,true,true),acknowledgeGrant(e),acknowledgeBurn(e),
      dispatch(k),complete(k),changeLeader,loseJournal,isolateWriter(true),rebuild,readCurrent(domain,configuration,n.term,n.head,G::g.root,true),activate,
      dropReply(e),confirm(k),materialize(k),loseReply}
  }
  action sourceInstall = all {G::sourceInstall,n' = n}
  action sourceDelegate = all {G::sourceDelegate,n' = n}
  action sourceWrite = all {G::sourceWrite,n' = n}
  action sourcePrepare = all {G::sourcePrepare,n' = n}
  action sourceEvidence = all {G::sourceEvidence,n' = n}
  action sourceFinish = all {G::sourceFinish,n' = n}
  action sourcePublish = all {G::sourcePublish,n' = n}
  action sourceRetire = all {G::sourceRetire,n' = n}
  action sourceClose = all {G::sourceClose,n' = n}
  action sourceObserve = all {G::sourceObserve,n' = n}
  action sourceUsage = all {G::sourceUsage,n' = n}
  action sourceSettle = all {G::sourceSettle,n' = n}
  action decision = init.then(rebuild).then(sourceInstall).then(rebuild).then(sourceDelegate).then(rebuild).then(sourceWrite).then(rebuild).then(sourcePrepare).then(rebuild).then(sourceEvidence).then(rebuild).then(sourceFinish).then(rebuild).then(sourcePublish).then(rebuild).then(sourceRetire).then(rebuild).then(sourceClose).then(rebuild).then(sourceObserve).then(rebuild).then(sourceUsage).then(rebuild).then(sourceSettle).then(rebuild)
  action anchored = decision.then(anchor(0)).then(rebuild)
  // Each helper is a sequence of product-complete actions, never nested foreign .then.
  action seal = propose(proposal(0,0)).then(commit(proposal(0,0),true,true)).then(rebuild)
  action grant = propose(proposal(1,0)).then(commit(proposal(1,0),true,true))
  action burn = propose(proposal(2,0)).then(commit(proposal(2,0),true,true))
  action fenceRoot = isolateWriter(true).then(propose(proposal(4,0))).then(commit(proposal(4,0),true,true))
  action archive = propose(proposal(3,0)).then(commit(proposal(3,0),true,true)).then(rebuild)
  action sealed = anchored.then(seal)
  action granted = sealed.then(grant)
  action held = granted.then(acknowledgeGrant(logged(1)))
  action burned = held.then(burn)
  action acknowledged = burned.then(acknowledgeBurn(logged(2)))
  action dispatched = acknowledged.then(dispatch(0))
  action applied = dispatched.then(complete(0))
  action archived = applied.then(archive)
  action reactivated = changeLeader.then(fenceRoot).then(rebuild).then(readCurrent(domain,configuration,n.term,n.head,G::g.root,true)).then(activate)
  run completeOriginalPipelineTest = archived.then(confirm(0)).then(rebuild).then(materialize(0)).then(rebuild).expect(safety)
  run proposalIsNotCommitTest = held.then(propose(proposal(2,0))).then(acknowledgeBurn(proposal(2,0)).fail())
  run localLeaderAckNotDurableTest = held.then(propose(proposal(2,0))).then(commit(proposal(2,0),false,true).fail())
  run burnWithoutOriginalGrantAckRejectedTest = granted.then(propose(proposal(2,0))).then(commit(proposal(2,0),true,true).fail())
  run lostGrantReplyCannotBeReadBackAsCapTest = granted.then(dropReply(logged(1)))
    .then(readCurrent(domain,configuration,n.term,n.head,G::g.root,true)).then(acknowledgeGrant(logged(1)).fail())
  run lostBurnReplyCannotDispatchTest = burned.then(dropReply(logged(2)))
    .then(readCurrent(domain,configuration,n.term,n.head,G::g.root,true)).then(dispatch(0).fail())
  run consumedButUndispatchedCannotCompleteTest = burned.then(complete(0).fail())
  run duplicateDispatchRejectedTest = dispatched.then(dispatch(0).fail())
  run duplicateOriginalReplyRejectedTest = held.then(acknowledgeGrant(n.grantRows.get(0)).fail())
  run oldProposalAfterLeaderChangeRejectedTest = held.then(propose(proposal(2,0))).then(changeLeader)
    .then(commit(staged(2),true,true).fail())
  run oldGrantReplyAfterChangeRejectedTest = granted.then(changeLeader).then(fenceRoot).then(rebuild)
    .then(readCurrent(domain,configuration,n.term,n.head,G::g.root,true)).then(activate)
    .then(acknowledgeGrant(logged(1)).fail())
  run heldOldGrantCannotBurnTest = held.then(reactivated).then(propose(proposal(2,0))).then(commit(proposal(2,0),true,true).fail())
  run lateBurnAckAfterBarrierRejectedTest = burned.then(changeLeader).then(isolateWriter(true)).then(acknowledgeBurn(logged(2)).fail())
  run acknowledgedButUnsentStaysUnknownTest = acknowledged.then(changeLeader).then(fenceRoot).then(dispatch(0).fail())
  run unknownBurnBlocksActivationTest = burned.then(changeLeader).then(fenceRoot).then(rebuild.fail())
  run dispatchedOriginalCompletesAcrossLeaderChangeTest = dispatched.then(changeLeader).then(fenceRoot).then(complete(0)).then(archive)
    .then(readCurrent(domain,configuration,n.term,n.head,G::g.root,true)).then(activate).expect(safety and n.dispatchCount.get(0) == 1)
  run committedResultReplyLossDoesNotReapplyTest = archived.then(dropReply(logged(3)))
    .then(reactivated).then(complete(0).fail())
  run leaderTermAloneCannotActivateTest = held.then(changeLeader).then(readCurrent(domain,configuration,n.term,n.head,G::g.root,true)).then(activate.fail())
  run fakeOwnerBarrierRejectedTest = held.then(changeLeader).then(propose(proposal(4,0))).then(commit(proposal(4,0),true,false).fail())
  run fenceCommitReplyLostCanResolveTest = sealed.then(changeLeader).then(fenceRoot).then(dropReply(logged(4)))
    .then(rebuild).then(readCurrent(domain,configuration,n.term,n.head,G::g.root,true)).then(activate).expect(safety and n.active)
  run staleReadCannotActivateAfterFenceCommitTest = sealed.then(changeLeader).then(readCurrent(domain,configuration,n.term,n.head,G::g.root,true))
    .then(fenceRoot).then(rebuild).then(activate.fail())
  run wrongRootRejectedTest = held.then(propose(proposal(2,0).with("root",999))).then(commit(proposal(2,0).with("root",999),true,true).fail())
  run wrongConfigurationRejectedTest = held.then(propose(proposal(2,0).with("config",999))).then(commit(proposal(2,0).with("config",999),true,true).fail())
  run staleReadResponseRejectedTest = held.then(changeLeader).then(readCurrent(domain,configuration,0,n.head,G::g.root,true).fail())
  run unauthenticatedReadRejectedTest = sealed.then(changeLeader).then(readCurrent(domain,configuration,n.term,n.head,G::g.root,false).fail())
  run oldConfirmedOperationMayDispatchBeforeBarrierTest = acknowledged.then(changeLeader).then(dispatch(0))
    .then(fenceRoot).then(complete(0)).then(archive).then(readCurrent(domain,configuration,n.term,n.head,G::g.root,true)).then(activate).expect(safety)
  run lateOriginalAckMayArriveBeforeBarrierTest = burned.then(changeLeader).then(acknowledgeBurn(logged(2)))
    .then(dispatch(0)).then(fenceRoot).then(complete(0)).then(archive).expect(safety)
  run committedEpochCannotReplacePhysicalBarrierTest = held.then(changeLeader).then(propose(proposal(4,0)))
    .then(commit(proposal(4,0),true,true).fail())
  run unqualifiedPhysicalBarrierRejectedTest = held.then(changeLeader).then(isolateWriter(false).fail())
  run wrongReadRootRejectedTest = sealed.then(changeLeader).then(readCurrent(999,configuration,n.term,n.head,G::g.root,true).fail())
  run wrongReadConfigurationRejectedTest = sealed.then(changeLeader).then(readCurrent(domain,999,n.term,n.head,G::g.root,true).fail())
  run oldBarrierReplyAfterSecondElectionRejectedTest = held.then(changeLeader).then(changeLeader)
    .then(acceptBarrier(domain,configuration,1,G::g.root.epoch+1,true).fail())
  run wrongRootBarrierReplyRejectedTest = held.then(changeLeader)
    .then(acceptBarrier(999,configuration,n.term,G::g.root.epoch+1,true).fail())
  // Deliberately excluded rules preserve observations of the violated boundary.
  action fabricateAck(e) = all {baseStay,n' = n.with("burns",n.burns.union(Set(e.key))).with("burnRows",n.burnRows.set(e.key,e))}
  action forkCertificate(e) = all {baseStay,n' = n.with("log",n.log.union(Set(e.with("config",configuration).with("root",domain).with("key",1))))}
  action staleDispatch(k) = all {baseStay,n.burns.contains(k),
    n' = n.with("sent",n.sent.union(Set(k))).with("dispatchRows",n.dispatchRows.set(k,
      {entry:n.burnRows.get(k),observedTerm:n.writerTerm,observedEpoch:n.writerEpoch}))
      .with("dispatchCount",n.dispatchCount.set(k,n.dispatchCount.get(k)+1))}
  action installFork(k) = all {G::forgetIndependentRoot(k),n' = initial.with("dispatchCount",n.dispatchCount)}
  run localAckAsCommitCounterexampleTest = held.then(propose(proposal(2,0))).then(fabricateAck(proposal(2,0))).expect(not(bindingSafety))
  run twoCertifiedBranchesCounterexampleTest = burned.then(forkCertificate(logged(2))).expect(not(prefixSafety))
  run oldAckUsedAfterBarrierCounterexampleTest = acknowledged.then(changeLeader).then(fenceRoot).then(staleDispatch(0))
    .then(complete(0)).expect(not(dispatchSafety) and not(G::g.pending.contains(0)))
  run forkedRootReplaysApplicationCounterexampleTest = applied.then(installFork(0)).then(rebuild).then(seal).then(grant)
    .then(acknowledgeGrant(logged(1))).then(burn)
    .then(acknowledgeBurn(logged(2))).then(dispatch(0)).then(complete(0)).expect(not(G::safety))
}
