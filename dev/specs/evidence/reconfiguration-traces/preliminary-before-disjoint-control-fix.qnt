// Dynamic membership envelope over the fixed logical execution projection.
module AnchorReconfiguration {
  import AnchorBrokerCommit as A from "./AnchorBrokerCommit"
  type Scope = {joint:bool,old:int,next:int}
  type Record = {index:int,revision:int,scope:Scope,kind:int,entry:A::Entry,oldQ:Set[int],newQ:Set[int]}
  type Image = {history:Set[Record],root:A::Entry,scope:Scope,revision:int}
  type State = {scope:Scope,revision:int,position:int,history:Set[Record],proposals:Set[Record],
    installed:Set[int],copies:int->Image,admitted:bool,barrierRevision:int,fenceRevision:int,readRevision:int,readPosition:int,readTerm:int}
  var r:State
  pure val voterIds = 0.to(8)
  pure def voters(cfg) = Set(3*cfg,3*cfg+1,3*cfg+2)
  pure def majority(cfg,q) = q.subseteq(voters(cfg)) and q.size() >= 2
  pure def accepted(scope,oldQ,newQ) = majority(scope.old,oldQ) and (not(scope.joint) or majority(scope.next,newQ))
  pure val genesisScope = {joint:false,old:0,next:0}
  pure val emptyImage = {history:Set(),root:A::emptyEntry,scope:genesisScope,revision:0}
  pure val initial = {scope:genesisScope,revision:0,position:0,history:Set(),proposals:Set(),installed:Set(),
    copies:voterIds.mapBy(_ => emptyImage),admitted:true,barrierRevision:-1,fenceRevision:-1,readRevision:-1,readPosition:0,readTerm:0}
  action initWith(ranges) = all {A::initWith(ranges),r' = initial}
  action init = initWith(3)
  action emptyInit = initWith(0)
  action singletonInit = initWith(1)
  action largerInit = initWith(5)
  action baseStay = all {A::baseStay,A::n' = A::n}
  def image = {history:r.history,root:A::proposal(0,0),scope:r.scope,revision:r.revision}
  def readyCopies(oldQ,newQ) = oldQ.union(newQ).forall(v => r.installed.contains(v) and r.copies.get(v) == image)
  action install(v,candidate,authentic) = all {authentic,candidate == image,baseStay,
    r' = r.with("installed",r.installed.union(Set(v))).with("copies",r.copies.set(v,candidate))}
  action installAll(authentic) = all {authentic,baseStay,r' = r.with("installed",voterIds).with("copies",voterIds.mapBy(_ => image))}
  action loseReplica(v) = all {baseStay,r' = r.with("installed",r.installed.exclude(Set(v)))}
  def dataRecord(phase,k,oldQ,newQ) = {index:r.position,revision:r.revision,scope:r.scope,kind:0,entry:A::proposal(phase,k),oldQ:oldQ,newQ:newQ}
  def controlRecord(kind,oldQ,newQ) = {index:r.position,revision:r.revision,
    scope:if (kind == 1) {joint:true,old:r.scope.old,next:r.scope.old+1} else r.scope,
    kind:kind,entry:A::proposal(0,0),oldQ:oldQ,newQ:newQ}
  action propose(e) = all {A::propose(e.entry),r' = r.with("proposals",r.proposals.union(Set(e))).with("readRevision",-1)}
  action commit(e,durable,barrier) = all {e.kind == 0,r.proposals.contains(e),e.index == r.position,e.revision == r.revision,
    e.scope == r.scope,accepted(r.scope,e.oldQ,e.newQ),readyCopies(e.oldQ,e.newQ),
    e.entry.phase >= 3 or (r.admitted and not(r.scope.joint)),
    e.entry.phase != 4 or r.barrierRevision == r.revision,
    A::commit(e.entry,durable,barrier),
    r' = r.with("history",r.history.union(Set(e))).with("position",r.position+1).with("readRevision",-1)
      .with("fenceRevision",if (e.entry.phase == 4) r.revision else r.fenceRevision)}
  action enterJoint(e,durable) = all {durable,not(r.scope.joint),r.scope.old < 2,e.kind == 1,e.index == r.position,
    e.revision == r.revision,e.scope == {joint:true,old:r.scope.old,next:r.scope.old+1},e.entry == A::proposal(0,0),
    accepted(e.scope,e.oldQ,e.newQ),readyCopies(e.oldQ,e.newQ),baseStay,
    r' = r.with("scope",e.scope).with("revision",r.revision+1).with("position",r.position+1).with("history",r.history.union(Set(e)))
      .with("admitted",false).with("barrierRevision",-1).with("fenceRevision",-1).with("readRevision",-1)}
  action finishJoint(e,durable) = all {durable,r.scope.joint,e.kind == 2,e.index == r.position,e.revision == r.revision,
    e.scope == r.scope,e.entry == A::proposal(0,0),accepted(r.scope,e.oldQ,e.newQ),readyCopies(e.oldQ,e.newQ),baseStay,
    r' = r.with("scope",{joint:false,old:r.scope.next,next:r.scope.next}).with("revision",r.revision+1)
      .with("position",r.position+1).with("history",r.history.union(Set(e))).with("admitted",false)
      .with("barrierRevision",-1).with("fenceRevision",-1).with("readRevision",-1)}
  action changeLeader = all {A::changeLeader,r' = r.with("admitted",false).with("barrierRevision",-1).with("fenceRevision",-1).with("readRevision",-1)}
  action loseJournal = all {A::loseJournal,r' = r.with("admitted",false).with("barrierRevision",-1).with("fenceRevision",-1).with("readRevision",-1)}
  action acceptBarrier(scope,revision,term,targetEpoch,authentic) = all {scope == r.scope,revision == r.revision,
    A::acceptBarrier(A::domain,A::configuration,term,targetEpoch,authentic),r' = r.with("admitted",false)
      .with("barrierRevision",r.revision).with("fenceRevision",-1).with("readRevision",-1)}
  action isolateWriter = acceptBarrier(r.scope,r.revision,A::n.term,A::proposal(4,0).epoch,true)
  action readCurrent(scope,revision,position,term,candidate,authentic) = all {scope == r.scope,revision == r.revision,position == r.position,
    candidate == image,A::readCurrent(A::domain,A::configuration,term,A::n.head,candidate.root.image,authentic),
    r' = r.with("readRevision",r.revision).with("readPosition",r.position).with("readTerm",A::n.term)}
  action activate = all {not(r.scope.joint),r.barrierRevision == r.revision,r.fenceRevision == r.revision,
    r.readRevision == r.revision,r.readPosition == r.position,r.readTerm == A::n.term,A::activate,r' = r.with("admitted",true)}
  action rebuild = all {A::rebuild,r' = r.with("readRevision",-1)}
  action acknowledgeGrant(e) = all {A::acknowledgeGrant(e),r' = r.with("readRevision",-1)}
  action acknowledgeBurn(e) = all {A::acknowledgeBurn(e),r' = r.with("readRevision",-1)}
  action dispatch(k) = all {A::dispatch(k),r' = r.with("readRevision",-1)}
  action complete(k) = all {A::complete(k),r' = r.with("readRevision",-1)}
  action dropReply(e) = all {A::dropReply(e),r' = r.with("readRevision",-1)}
  action sourceStep = all {A::sourceStep,r' = r.with("readRevision",-1)}
  action anchor(k) = all {A::anchor(k),r' = r.with("readRevision",-1)}
  action confirm(k) = all {A::confirm(k),r' = r.with("readRevision",-1)}
  action materialize(k) = all {A::materialize(k),r' = r.with("readRevision",-1)}
  action loseReply = all {baseStay,r' = r}
  val membershipSafety = (r.admitted implies not(r.scope.joint)) and r.history.forall(e => e.index < r.position and
    e.revision <= r.revision and accepted(e.scope,e.oldQ,e.newQ) and r.history.forall(other => e.index == other.index implies e == other))
  val prefixSafety = A::n.log.forall(e => r.history.exists(full => full.kind == 0 and full.entry == e))
  val safety = A::safety and membershipSafety and prefixSafety
  action step = {
    nondet k = 0.to(3).oneOf()
    nondet phase = 0.to(4).oneOf()
    nondet v = voterIds.oneOf()
    val oldQ = voters(r.scope.old)
    val newQ = if (r.scope.joint) voters(r.scope.next) else Set()
    nondet e = r.proposals.union(Set(dataRecord(phase,k,oldQ,newQ))).oneOf()
    any {sourceStep,anchor(k),installAll(true),loseReplica(v),propose(dataRecord(phase,k,oldQ,newQ)),commit(e,true,true),
      enterJoint(controlRecord(1,oldQ,voters(r.scope.old+1)),true),finishJoint(controlRecord(2,oldQ,newQ),true),
      acknowledgeGrant(A::logged(1)),acknowledgeBurn(A::logged(2)),dispatch(k),complete(k),changeLeader,loseJournal,isolateWriter,
      rebuild,readCurrent(r.scope,r.revision,r.position,A::n.term,image,true),activate,confirm(k),materialize(k),loseReply}
  }
  action sourceInstall = all {A::sourceInstall,r' = r.with("readRevision",-1)}
  action sourceDelegate = all {A::sourceDelegate,r' = r.with("readRevision",-1)}
  action sourceWrite = all {A::sourceWrite,r' = r.with("readRevision",-1)}
  action sourcePrepare = all {A::sourcePrepare,r' = r.with("readRevision",-1)}
  action sourceEvidence = all {A::sourceEvidence,r' = r.with("readRevision",-1)}
  action sourceFinish = all {A::sourceFinish,r' = r.with("readRevision",-1)}
  action sourcePublish = all {A::sourcePublish,r' = r.with("readRevision",-1)}
  action sourceRetire = all {A::sourceRetire,r' = r.with("readRevision",-1)}
  action sourceClose = all {A::sourceClose,r' = r.with("readRevision",-1)}
  action sourceObserve = all {A::sourceObserve,r' = r.with("readRevision",-1)}
  action sourceUsage = all {A::sourceUsage,r' = r.with("readRevision",-1)}
  action sourceSettle = all {A::sourceSettle,r' = r.with("readRevision",-1)}
  action decision = init.then(rebuild).then(sourceInstall).then(rebuild).then(sourceDelegate).then(rebuild).then(sourceWrite).then(rebuild).then(sourcePrepare).then(rebuild).then(sourceEvidence).then(rebuild).then(sourceFinish).then(rebuild).then(sourcePublish).then(rebuild).then(sourceRetire).then(rebuild).then(sourceClose).then(rebuild).then(sourceObserve).then(rebuild).then(sourceUsage).then(rebuild).then(sourceSettle).then(rebuild)
  action anchored = decision.then(anchor(0)).then(rebuild)
  action rootOp(phase) = installAll(true).then(propose(dataRecord(phase,0,voters(r.scope.old),if (r.scope.joint) voters(r.scope.next) else Set())))
    .then(commit(dataRecord(phase,0,voters(r.scope.old),if (r.scope.joint) voters(r.scope.next) else Set()),true,true))
  action sealed = anchored.then(rootOp(0)).then(rebuild)
  action held = sealed.then(rootOp(1)).then(acknowledgeGrant(A::logged(1)))
  action burned = held.then(rootOp(2))
  action acknowledged = burned.then(acknowledgeBurn(A::logged(2)))
  action dispatched = acknowledged.then(dispatch(0))
  action applied = dispatched.then(complete(0))
  action archived = applied.then(rootOp(3)).then(rebuild)
  action joint = installAll(true).then(enterJoint(controlRecord(1,voters(r.scope.old),voters(r.scope.old+1)),true))
  action finish = installAll(true).then(finishJoint(controlRecord(2,voters(r.scope.old),voters(r.scope.next)),true))
  action fence = isolateWriter.then(rootOp(4)).then(rebuild)
  action read = readCurrent(r.scope,r.revision,r.position,A::n.term,image,true)
  action newStable = sealed.then(joint).then(finish).then(fence).then(read).then(activate)
  action jointPending = held.then(joint)
  action moving = dispatched.then(joint)
  pure val oldMajorities = Set(Set(0,1),Set(0,2),Set(1,2),Set(0,1,2))
  pure val newMajorities = Set(Set(3,4),Set(3,5),Set(4,5),Set(3,4,5))
  run majorityBridgeIntersectionTest = init.expect(oldMajorities.forall(left => oldMajorities.forall(right => left.intersect(right).size() > 0)) and
    newMajorities.forall(left => newMajorities.forall(right => left.intersect(right).size() > 0)) and voters(0).intersect(voters(1)).size() == 0)
  run reconfigurationAndFreshOriginalApplicationTest = newStable.then(rootOp(1)).then(acknowledgeGrant(A::logged(1)))
    .then(rootOp(2)).then(acknowledgeBurn(A::logged(2))).then(dispatch(0)).then(complete(0)).then(rootOp(3)).then(rebuild).expect(safety)
  run oldOnlyCannotEnterJointTest = sealed.then(installAll(true)).then(enterJoint(controlRecord(1,voters(0),Set()),true).fail())
  run newOnlyCannotFinalizeJointTest = sealed.then(joint).then(installAll(true)).then(finishJoint(controlRecord(2,Set(),voters(1)),true).fail())
  run independentOldQuorumCannotCommitDuringJointTest = sealed.then(joint).then(isolateWriter).then(installAll(true))
    .then(propose(dataRecord(4,0,voters(0),Set()))).then(commit(dataRecord(4,0,voters(0),Set()),true,true).fail())
  run independentNewQuorumCannotCommitDuringJointTest = sealed.then(joint).then(isolateWriter).then(installAll(true))
    .then(propose(dataRecord(4,0,Set(),voters(1)))).then(commit(dataRecord(4,0,Set(),voters(1)),true,true).fail())
  run staleCopiedPrefixCannotFinalizeTest = sealed.then(joint).then(finishJoint(controlRecord(2,voters(0),voters(1)),true).fail())
  run missingNewReplicaCopyRejectedTest = sealed.then(installAll(true)).then(loseReplica(3))
    .then(enterJoint(controlRecord(1,voters(0),voters(1)),true).fail())
  run matchingPositionWrongHistoryRejectedTest = sealed.then(install(3,image.with("history",Set()),true).fail())
  run omittedSpentRecordImageRejectedTest = burned.then(install(3,image.with("root",image.root.with("image",image.root.image.with("burns",Set()))),true).fail())
  run unauthenticatedReplicaCopyRejectedTest = sealed.then(install(3,image,false).fail())
  run staleProposalCannotUseNewScopeTest = held.then(propose(dataRecord(2,0,voters(0),Set()))).then(joint)
    .then(commit(r.proposals.fold(dataRecord(2,0,voters(0),Set()),(acc,e) => e),true,true).fail())
  run lateCommittedBurnAckBeforePhysicalBarrierTest = burned.then(joint).then(acknowledgeBurn(A::logged(2))).then(dispatch(0))
    .then(finish).then(isolateWriter).then(complete(0)).then(rootOp(3)).then(fence).then(read).then(activate).expect(safety)
  run oldAckAfterPhysicalBarrierRejectedTest = burned.then(joint).then(isolateWriter).then(acknowledgeBurn(A::logged(2)).fail())
  run unknownBurnSurvivesFinalizationTest = burned.then(joint).then(finish).then(isolateWriter).then(rootOp(4)).then(rebuild.fail())
  run oldHeldGrantDoesNotBecomeNewPermitTest = held.then(joint).then(finish).then(fence).then(read).then(activate)
    .then(installAll(true)).then(propose(dataRecord(2,0,voters(1),Set())))
    .then(commit(dataRecord(2,0,voters(1),Set()),true,true).fail())
  run oldQuorumRetiredAfterFinalizationTest = sealed.then(joint).then(finish).then(fence).then(read).then(activate).then(installAll(true))
    .then(propose(dataRecord(1,0,voters(0),Set()))).then(commit(dataRecord(1,0,voters(0),Set()),true,true).fail())
  run jointFenceCannotActivateNewConfigurationTest = sealed.then(joint).then(fence).then(finish).then(rebuild).then(read).then(activate.fail())
  run leaderChangePreservesJointScopeTest = sealed.then(joint).then(changeLeader).expect(safety and r.scope.joint and r.history.size() == 2)
  run leaderChangeBetweenJointAndFinalizeTest = sealed.then(joint).then(changeLeader).then(finish).then(fence).then(read).then(activate).expect(safety)
  run secondReconfigurationPreservesPrefixTest = newStable.then(joint).then(finish).then(fence).then(read).then(activate)
    .expect(safety and r.scope.old == 2 and r.revision == 4)
  run oldBarrierCannotBeRelabeledAsNewScopeTest = sealed.then(joint).then(isolateWriter).then(finish)
    .then(acceptBarrier({joint:true,old:0,next:1},1,A::n.term,A::proposal(4,0).epoch,true).fail())
  run lostJointCommitReplyCannotReenterTest = sealed.then(joint).then(loseReply).then(enterJoint(controlRecord(1,voters(0),voters(1)),true).fail())
  run savedReadBeforeMembershipChangeRejectedTest = sealed.then(changeLeader).then(fence).then(read).then(joint).then(finish).then(activate.fail())
  run lateOriginalResultAcrossElectionAndConfigurationTest = dispatched.then(joint).then(changeLeader).then(finish).then(isolateWriter)
    .then(complete(0)).then(rootOp(3)).then(fence).then(read).then(activate).expect(safety and A::n.dispatchCount.get(0) == 1)
  // Explicitly excluded publication rules. Actual parent write history is retained.
  action oldOnlyJointRecord = {
    val e = controlRecord(1,voters(0),Set())
    all {baseStay,r' = r.with("history",r.history.union(Set(e))).with("position",r.position+1)}
  }
  action dropInheritedPrefix = all {baseStay,r' = r.with("history",Set())}
  action unsafeJointActivation = all {baseStay,r' = r.with("admitted",true)}
  action forkedReplacement = all {A::installFork(0),r' = initial}
  run oldOnlyJointCertificateCounterexampleTest = sealed.then(oldOnlyJointRecord).expect(not(membershipSafety))
  run loseInheritedDecidingPrefixCounterexampleTest = held.then(joint).then(finish).then(dropInheritedPrefix).expect(not(prefixSafety))
  run activateJointWithoutNewScopeFenceCounterexampleTest = sealed.then(joint).then(unsafeJointActivation).expect(not(membershipSafety))
  run disjointReplacementReplaysActualApplicationCounterexampleTest = applied.then(forkedReplacement).then(rebuild).then(rootOp(0)).then(rebuild)
    .then(rootOp(1)).then(acknowledgeGrant(A::logged(1))).then(rootOp(2)).then(acknowledgeBurn(A::logged(2)))
    .then(dispatch(0)).then(complete(0)).expect(not(A::safety))
}
