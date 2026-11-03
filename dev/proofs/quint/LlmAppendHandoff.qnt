// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

module LlmAppendHandoff {
  import LlmCheckpointTruncation as C from "./LlmCheckpointTruncation"
  type Segment={id:int,records:List[C::Record]}
  type Manifest={id:int,parent:int,checkpoint:C::Checkpoint,haveCheckpoint:bool,segments:List[Segment]}
  type Cut={id:int,parent:int,rootGeneration:int,appendGeneration:int,records:List[C::Record]}
  type Receipt={root:int,rootGeneration:int,appendGeneration:int,frontier:int,worker:int}
  type Storage={root:Manifest,closed:List[Segment],live:List[Segment],objects:Set[Segment],allocated:Set[Segment],
    rootGeneration:int,appendGeneration:int,frontier:int,sequence:int,cut:Cut,haveCut:bool,candidate:Manifest,haveCandidate:bool,
    observed:Receipt,haveObservation:bool,lastAuthorized:bool,attempted:Receipt}
  var h:Storage
  pure val old={id:10,records:C::cp1.basis.journal}
  pure val tailSegment={id:11,records:List(C::fOther)}
  pure val root0={id:0,parent:0,checkpoint:C::cp1,haveCheckpoint:true,segments:List()}
  pure val replacement=root0.with("id",1)
  pure val withPending=replacement.with("segments",List(tailSegment))
  pure val emptyCut={id:0,parent:0,rootGeneration:0,appendGeneration:0,records:List()}
  pure val initial={root:root0,closed:List(),live:List(),objects:Set(old),allocated:Set(old),rootGeneration:0,appendGeneration:0,frontier:0,sequence:0,
    cut:emptyCut,haveCut:false,candidate:root0,haveCandidate:false,
    observed:{root:0,rootGeneration:0,appendGeneration:0,frontier:0,worker:0},haveObservation:true,lastAuthorized:true,attempted:{root:0,rootGeneration:0,appendGeneration:0,frontier:0,worker:0}}
  pure def flat(xs)=xs.foldl(List(),(rs,seg)=>rs.concat(seg.records))
  pure def manifestReplay(r)=r.checkpoint.basis.journal.concat(flat(r.segments))
  def snapshot=manifestReplay(h.root).concat(flat(h.closed))
  def replay=snapshot.concat(flat(h.live))
  def refs=h.root.segments.concat(h.closed).concat(h.live).concat(if(h.haveCandidate) h.candidate.segments else List())
  def view={root:h.root.id,rootGeneration:h.rootGeneration,appendGeneration:h.appendGeneration,frontier:h.frontier,worker:C::pubView.epoch}
  def confirmed=h.haveObservation and h.observed==view
  def descriptor(worker,generation,frontier)=confirmed and worker==C::pubView.epoch and generation==h.appendGeneration and frontier==h.frontier
  val available=C::c.blobs.contains(h.root.checkpoint) and (not(h.haveCandidate) or C::c.blobs.contains(h.candidate.checkpoint)) and refs.indices().forall(i=>h.objects.contains(refs.nth(i)))
  val represented=replay==C::expanded and h.root.checkpoint==C::c.local and C::c.haveLocal and flat(h.root.segments).concat(flat(h.closed)).concat(flat(h.live))==C::c.suffix
  val aligned=not(h.haveCut) or (h.cut.records==snapshot and h.cut.parent==h.root.id and h.cut.rootGeneration==h.rootGeneration and h.cut.appendGeneration==h.appendGeneration)
  val candidateAligned=not(h.haveCandidate) or (h.haveCut and manifestReplay(h.candidate)==h.cut.records)
  val safety=available and represented and aligned and candidateAligned and h.lastAuthorized and C::safety
  action idle=C::observeFinancial
  action init=all {C::recovered,h'=initial}
  action observe(worker,authentic)=all {authentic,available,worker==C::pubView.epoch,idle,h'=h.with("observed",view).with("haveObservation",true)}
  action prepare=all {C::prepareOther,h'=h}
  action appendFrame(worker,generation,frontier,durable,policy)=all {descriptor(worker,generation,frontier),durable,policy,h.allocated.forall(seg=>seg.id!=tailSegment.id),
    C::flushOther,h'=h.with("live",h.live.append(tailSegment)).with("objects",h.objects.union(Set(tailSegment))).with("allocated",h.allocated.union(Set(tailSegment)))
      .with("frontier",h.frontier+1).with("haveObservation",false)}
  action sealCut(worker,generation,frontier,durable,policy)=all {policy,not(h.haveCut),not(h.haveCandidate),descriptor(worker,generation,frontier),durable,idle,
    h'=h.with("cut",{id:h.sequence+1,parent:h.root.id,rootGeneration:h.rootGeneration,appendGeneration:h.appendGeneration+1,records:replay})
      .with("haveCut",true).with("sequence",h.sequence+1).with("closed",h.closed.concat(h.live)).with("live",List())
      .with("appendGeneration",h.appendGeneration+1).with("haveObservation",false)}
  action stage(r,durable)=all {h.haveCut,manifestReplay(r)==h.cut.records,r.parent==h.cut.parent,durable,
    C::c.blobs.contains(r.checkpoint),r.segments.indices().forall(i=>h.objects.contains(r.segments.nth(i))),idle,h'=h.with("candidate",r).with("haveCandidate",true)}
  action switchRoot(worker,generation,frontier,durable,policy)=all {h.haveCut,h.haveCandidate,aligned,candidateAligned,descriptor(worker,generation,frontier),durable,policy,
    h.candidate.parent==h.root.id,available,C::trim(h.candidate.checkpoint,flat(h.candidate.segments).concat(flat(h.live)),worker,true),
    h'=h.with("root",h.candidate).with("closed",List()).with("rootGeneration",h.rootGeneration+1).with("haveCut",false).with("haveCandidate",false).with("haveObservation",false)}
  action erase(id,worker,generation,frontier,policy)=all {policy,descriptor(worker,generation,frontier),refs.indices().forall(i=>refs.nth(i).id!=id),idle,
    h'=h.with("objects",h.objects.filter(seg=>seg.id!=id))}
  action submit=all {C::submitOther,h'=h}
  action commit=all {C::commitOther,h'=h}
  action rotate=all {C::rotate,h'=h}
  action crash=all {C::loseReply,h'=h.with("haveObservation",false)}
  action refresh=all {C::observe(true),h'=h}
  action install=all {C::install,h'=h}
  action activate=all {confirmed,safety,C::activate(C::pubView.epoch,true),h'=h}
  action prepared=init.then(prepare)
  action cutFirst=prepared.then(sealCut(0,0,0,true,true)).then(observe(0,true)).then(stage(replacement,true))
  action appended=cutFirst.then(appendFrame(0,1,0,true,true))
  action pending=appended.then(submit)
  action switched=pending.then(observe(0,true)).then(switchRoot(0,1,1,true,true))
  action lateCommitted=switched.then(commit)
  action preCutPending=prepared.then(appendFrame(0,0,0,true,true)).then(submit).then(observe(0,true)).then(sealCut(0,0,1,true,true)).then(stage(withPending,true))
  action recovered=lateCommitted.then(crash).then(observe(0,true)).then(refresh).then(install).then(activate)
  action oldOwner=pending.then(crash).then(rotate).then(observe(1,true)).then(refresh)
  action step={nondet r=Set(replacement,withPending).oneOf() nondet id=Set(10,11,99).oneOf()
    any {prepare,appendFrame(C::pubView.epoch,h.appendGeneration,h.frontier,true,true),sealCut(C::pubView.epoch,h.appendGeneration,h.frontier,true,true),
      stage(r,true),switchRoot(C::pubView.epoch,h.appendGeneration,h.frontier,true,true),observe(C::pubView.epoch,true),
      erase(id,C::pubView.epoch,h.appendGeneration,h.frontier,true),submit,commit,rotate,crash,refresh,install,activate}}
  run sealStartsNewGenerationTest=cutFirst.expect(safety and h.appendGeneration==1 and h.cut.records==C::cp1.basis.journal)
  run appendAfterCutRetainsLiveTailTest=appended.expect(safety and h.live==List(tailSegment) and h.cut.records==C::cp1.basis.journal)
  run appendBeforeCutRetainsPendingTailTest=preCutPending.expect(safety and h.closed==List(tailSegment) and h.cut.records==C::cp1.basis.journal.append(C::fOther))
  run switchCarriesCurrentLiveTailTest=switched.expect(safety and h.live==List(tailSegment) and C::c.suffix==List(C::fOther))
  run lateCommitUsesOriginalReservationTest=lateCommitted.expect(safety and h.live==List(tailSegment))
  run restartReplaysCommittedTailTest=recovered.expect(safety and C::c.local.basis.head.holds.get(12)==2 and C::c.suffix==List(C::fOther))
  run pendingTailKeepsOriginalHoldTest=pending.expect(safety and h.live.nth(0).records.nth(0).proposal.transaction.key.reservation==12)
  run oldAppendGenerationRejectedTest=cutFirst.then(appendFrame(0,0,0,true,true).fail())
  run oldFrontierSwitchRejectedTest=pending.then(observe(0,true)).then(switchRoot(0,1,0,true,true).fail())
  run missingSwitchReadbackRejectedTest=appended.then(switchRoot(0,1,1,true,true).fail())
  run oldWorkerAppendRejectedTest=cutFirst.then(rotate).then(observe(1,true)).then(appendFrame(0,1,0,true,true).fail())
  run oldWorkerCommitRejectedTest=oldOwner.then(commit.fail())
  run oldWorkerSwitchRejectedTest=oldOwner.then(switchRoot(0,1,1,true,true).fail())
  run oldWorkerDeleteRejectedTest=oldOwner.then(erase(10,0,1,1,true).fail())
  run liveTailCannotDeleteTest=switched.then(observe(0,true)).then(erase(11,0,1,1,true).fail())
  run closedTailCannotDeleteTest=preCutPending.then(observe(0,true)).then(erase(11,0,1,1,true).fail())
  run missingTailCandidateRejectedTest=preCutPending.then(stage(replacement,true).fail())
  run overlappingCutRejectedTest=cutFirst.then(sealCut(0,1,0,true,true).fail())
  run nondurableHandoffRejectedTest=prepared.then(sealCut(0,0,0,false,true).fail())
  run nondurableAppendRejectedTest=cutFirst.then(appendFrame(0,1,0,false,true).fail())
  run nondurableSwitchRejectedTest=pending.then(observe(0,true)).then(switchRoot(0,1,1,false,true).fail())
  run policyDeniedSwitchRejectedTest=pending.then(observe(0,true)).then(switchRoot(0,1,1,true,false).fail())
  run lostCutResponseQueriesSameGenerationTest=cutFirst.then(crash).then(observe(0,true)).expect(safety and h.sequence==1 and h.appendGeneration==1)
  run oldGarbageMayDeleteAfterSwitchTest=switched.then(observe(0,true)).then(erase(10,0,1,1,true)).expect(safety and h.objects==Set(tailSegment))
  run preCutPendingSurvivesSwitchAndLateCommitTest=preCutPending.then(observe(0,true)).then(switchRoot(0,1,1,true,true)).then(commit).expect(safety and h.root.segments==List(tailSegment))
  run commitBeforeSwitchKeepsTailTest=pending.then(commit).then(observe(0,true)).then(switchRoot(0,1,1,true,true)).expect(safety and h.live==List(tailSegment))
  run repeatOriginalCommitRejectedTest=lateCommitted.then(commit.fail())
  run deniedCutPolicyRejectedTest=prepared.then(sealCut(0,0,0,true,false).fail())
  run deniedAppendPolicyRejectedTest=cutFirst.then(appendFrame(0,1,0,true,false).fail())
  run deniedDeletePolicyRejectedTest=switched.then(observe(0,true)).then(erase(10,0,1,1,false).fail())
  action unsafeDropLive=all {idle,h'=h.with("live",List())}
  action unsafeDropClosed=all {idle,h'=h.with("closed",List()).with("cut",h.cut.with("records",manifestReplay(h.root)))}
  action unsafeEraseTail=all {idle,h'=h.with("objects",h.objects.filter(seg=>seg.id!=11))}
  action unsafeAppend(worker,generation,frontier)=all {C::flushOther,
    h'=h.with("live",h.live.append(tailSegment)).with("objects",h.objects.union(Set(tailSegment))).with("allocated",h.allocated.union(Set(tailSegment)))
      .with("frontier",h.frontier+1).with("lastAuthorized",descriptor(worker,generation,frontier)).with("attempted",view.with("worker",worker).with("appendGeneration",generation).with("frontier",frontier))}
  action unsafeSwitchDescriptor(worker,generation,frontier)=all {idle,h'=h.with("lastAuthorized",descriptor(worker,generation,frontier)).with("attempted",view.with("worker",worker).with("appendGeneration",generation).with("frontier",frontier))}
  action unsafePendingCheckpoint=all {C::unsafePublish(C::cp2),h'=h}
  run droppedLiveAppendCounterexampleTest=switched.then(unsafeDropLive).expect(not(represented))
  run droppedClosedAppendCounterexampleTest=preCutPending.then(unsafeDropClosed).expect(not(represented))
  run tailDeletionAppendCounterexampleTest=switched.then(unsafeEraseTail).expect(not(available))
  run oldGenerationAppendCounterexampleTest=cutFirst.then(unsafeAppend(0,0,0)).expect(not(h.lastAuthorized) and represented)
  run oldFrontierAppendCounterexampleTest=pending.then(observe(0,true)).then(unsafeSwitchDescriptor(0,1,0)).expect(not(h.lastAuthorized))
  run oldOwnerAppendCounterexampleTest=oldOwner.then(unsafeSwitchDescriptor(0,1,1)).expect(not(h.lastAuthorized))
  run pendingAsCommittedAppendCounterexampleTest=pending.then(unsafePendingCheckpoint).expect(not(C::publishedSafe))
  run lostResponseAppendCounterexampleTest=pending.then(crash).then(unsafeSwitchDescriptor(0,1,1)).expect(not(h.lastAuthorized))
}
