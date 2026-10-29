module LlmManifestSwitch {
  import LlmCheckpointTruncation as C from "./LlmCheckpointTruncation"
  type Segment={id:int,records:List[C::Record]}
  type Manifest={id:int,parent:int,checkpoint:C::Checkpoint,haveCheckpoint:bool,segments:List[Segment]}
  type Receipt={id:int,generation:int,worker:int}
  type Storage={root:Manifest,generation:int,objects:Set[Segment],manifests:Set[Manifest],allocated:Set[Segment],
    observed:Receipt,haveObservation:bool,lastDeleteAuthorized:bool}
  var m:Storage
  pure val oldSegment={id:10,records:List(C::cp1.basis.journal.nth(0))}
  pure val laterSegment={id:11,records:List(C::fOther)}
  pure val oldRoot={id:0,parent:0,checkpoint:C::empty,haveCheckpoint:false,segments:List(oldSegment)}
  pure val newRoot={id:1,parent:0,checkpoint:C::cp1,haveCheckpoint:true,segments:List()}
  pure val tailRoot=newRoot.with("segments",List(laterSegment))
  pure val initial={root:oldRoot,generation:0,objects:Set(oldSegment),manifests:Set(oldRoot),allocated:Set(oldSegment),
    observed:{id:0,generation:0,worker:0},haveObservation:true,lastDeleteAuthorized:true}
  pure def frames(r)=r.segments.foldl(List(),(xs,seg)=>xs.concat(seg.records))
  pure def replay(r)=(if (r.haveCheckpoint) r.checkpoint.basis.journal else List()).concat(frames(r))
  def view={id:m.root.id,generation:m.generation,worker:C::pubView.epoch}
  def confirmed=m.haveObservation and m.observed==view
  def available(r)=m.manifests.contains(r) and r.segments.indices().forall(i=>m.objects.contains(r.segments.nth(i))) and
    (if(r.haveCheckpoint) C::c.blobs.contains(r.checkpoint) else true)
  val safeCopy=available(m.root) and replay(m.root)==C::expanded and
    m.root.haveCheckpoint==C::c.haveLocal and (not(m.root.haveCheckpoint) or m.root.checkpoint==C::c.local) and frames(m.root)==C::c.suffix
  val safety=safeCopy and C::safety and m.lastDeleteAuthorized
  // The authenticated read projects to a parent authority step followed by a storage stutter.
  action idle=C::observeFinancial
  action init=all {C::confirmed,m'=initial}
  action segment(seg,durable)=all {durable,m.allocated.forall(old=>old.id!=seg.id),idle,
    m'=m.with("objects",m.objects.union(Set(seg))).with("allocated",m.allocated.union(Set(seg)))}
  action manifest(r,durable)=all {durable,m.manifests.forall(old=>old.id!=r.id),idle,m'=m.with("manifests",m.manifests.union(Set(r)))}
  action switchRoot(r,worker,generation,durable,policy)=all {r.haveCheckpoint,r.parent==m.root.id,generation==m.generation,
    available(r),replay(r)==C::expanded,durable,policy,worker==C::pubView.epoch,
    C::trim(r.checkpoint,frames(r),worker,true),
    m'=m.with("root",r).with("generation",m.generation+1).with("haveObservation",false)}
  action observe(worker,authentic)=all {authentic,available(m.root),worker==C::pubView.epoch,idle,
    m'=m.with("observed",view).with("haveObservation",true)}
  action erase(id,worker,generation)=all {confirmed,worker==C::pubView.epoch,generation==m.generation,
    m.root.segments.indices().forall(i=>m.root.segments.nth(i).id!=id),idle,m'=m.with("objects",m.objects.filter(seg=>seg.id!=id))}
  action crash=all {C::loseReply,m'=m.with("haveObservation",false)}
  action rotate=all {C::rotate,m'=m}
  action refresh=all {C::observe(true),m'=m}
  action activate(worker)=all {confirmed,safeCopy,C::activate(worker,true),m'=m}
  action staged=init.then(manifest(newRoot,true))
  action switched=staged.then(switchRoot(newRoot,0,0,true,true))
  action acknowledged=switched.then(observe(0,true))
  action deleted=acknowledged.then(erase(10,0,1))
  action restarted=deleted.then(crash).then(rotate).then(observe(1,true)).then(refresh)
  action twoRecords={
    all {C::twoRecords,m'=initial.with("root",oldRoot.with("checkpoint",C::cp1).with("haveCheckpoint",true).with("segments",List(laterSegment)))
      .with("objects",Set(oldSegment,laterSegment)).with("allocated",Set(oldSegment,laterSegment))
      .with("manifests",Set(oldRoot.with("checkpoint",C::cp1).with("haveCheckpoint",true).with("segments",List(laterSegment))))}
  }
  action step={nondet r=Set(newRoot,tailRoot).oneOf() nondet seg=Set(oldSegment,laterSegment).oneOf()
    nondet id=Set(10,11,99).oneOf()
    any {segment(seg,true),manifest(r,true),switchRoot(r,C::pubView.epoch,m.generation,true,true),observe(C::pubView.epoch,true),
      erase(id,C::pubView.epoch,m.generation),crash,rotate,refresh,activate(C::pubView.epoch)}}
  run stagePreservesOldCopyTest=staged.expect(safety and m.objects.contains(oldSegment) and m.root==oldRoot)
  run switchRetainsBothRepresentationsTest=switched.expect(safety and m.root==newRoot and m.objects.contains(oldSegment) and not(m.haveObservation))
  run lostSwitchReplyRequiresReadbackTest=switched.then(erase(10,0,1).fail())
  run sameSwitchRetryRejectedTest=switched.then(switchRoot(newRoot,0,0,true,true).fail())
  run sameSwitchRetryUsesOriginalResultTest=switched.then(observe(0,true)).expect(safety and m.generation==1)
  run readbackThenDeleteTest=deleted.expect(safety and m.objects==Set() and C::c.local==C::cp1)
  run deletionInterruptionIsIdempotentTest=deleted.then(crash).then(observe(0,true)).then(erase(10,0,1)).expect(safety)
  run crashBeforeSwitchRetainsOldCopyTest=staged.then(crash).then(observe(0,true)).expect(safety and m.root==oldRoot and m.objects.contains(oldSegment))
  run currentSegmentCannotDeleteTest=init.then(erase(10,0,0).fail())
  run staleOwnerCannotDeleteTest=acknowledged.then(rotate).then(observe(1,true)).then(erase(10,0,1).fail())
  run staleGenerationCannotDeleteTest=acknowledged.then(erase(10,0,0).fail())
  run staleParentCannotSwitchTest=acknowledged.then(refresh).then(switchRoot(newRoot,0,1,true,true).fail())
  run missingManifestCannotSwitchTest=init.then(switchRoot(newRoot,0,0,true,true).fail())
  run missingSegmentCannotSwitchTest=init.then(manifest(tailRoot,true)).then(switchRoot(tailRoot,0,0,true,true).fail())
  run nondurableSegmentRejectedTest=init.then(segment(laterSegment,false).fail())
  run nondurableManifestRejectedTest=init.then(manifest(newRoot,false).fail())
  run nondurableSwitchRejectedTest=staged.then(switchRoot(newRoot,0,0,false,true).fail())
  run policyDenialBlocksSwitchTest=staged.then(switchRoot(newRoot,0,0,true,false).fail())
  run segmentIdCannotRebindTest=init.then(segment(oldSegment.with("records",List(C::fOther)),true).fail())
  run manifestIdCannotRebindTest=staged.then(manifest(newRoot.with("segments",List(oldSegment)),true).fail())
  run unauthenticatedReadbackRejectedTest=switched.then(observe(0,false).fail())
  run restartRetainsUnknownHoldTest=restarted.expect(safety and C::c.local.basis.head.holds.get(12)==2 and C::c.local.basis.head.used==Set(11))
  run pendingAckCannotActivateTest=switched.then(refresh).then(activate(0).fail())
  run deleteCurrentCommittedTailRejectedTest=twoRecords.then(manifest(tailRoot,true)).then(refresh).then(switchRoot(tailRoot,0,0,true,true))
    .then(observe(0,true)).then(erase(10,0,1)).then(erase(11,0,1).fail())
  run committedTailCannotDisappearTest=twoRecords.then(manifest(newRoot,true)).then(refresh).then(switchRoot(newRoot,0,0,true,true).fail())
  action unsafeErase(id)=all {idle,m'=m.with("objects",m.objects.filter(seg=>seg.id!=id))}
  action unsafePermit(id,worker,generation)=all {idle,m'=m.with("objects",m.objects.filter(seg=>seg.id!=id))
    .with("lastDeleteAuthorized",confirmed and worker==C::pubView.epoch and generation==m.generation and m.root.segments.indices().forall(i=>m.root.segments.nth(i).id!=id))}
  action unsafeRoot(r)=all {idle,m'=m.with("root",r)}
  action unsafeRebind=all {idle,m'=m.with("objects",m.objects.exclude(Set(oldSegment)).union(Set(oldSegment.with("records",List(C::fOther)))))}
  run beforeSwitchManifestCounterexampleTest=staged.then(unsafeErase(10)).expect(not(safeCopy))
  run interruptedDeleteManifestCounterexampleTest=twoRecords.then(manifest(tailRoot,true)).then(refresh).then(switchRoot(tailRoot,0,0,true,true))
    .then(observe(0,true)).then(erase(10,0,1)).then(unsafeErase(11)).expect(not(safeCopy))
  run lostAckManifestCounterexampleTest=switched.then(unsafePermit(10,0,1)).expect(not(m.lastDeleteAuthorized) and safeCopy)
  run staleOwnerManifestCounterexampleTest=acknowledged.then(rotate).then(observe(1,true)).then(unsafePermit(10,0,1)).expect(not(m.lastDeleteAuthorized) and safeCopy)
  run staleGenerationManifestCounterexampleTest=acknowledged.then(unsafePermit(10,0,0)).expect(not(m.lastDeleteAuthorized) and safeCopy)
  run rootRollbackManifestCounterexampleTest=deleted.then(crash).then(unsafeRoot(oldRoot)).expect(not(safeCopy))
  run suffixLossManifestCounterexampleTest=twoRecords.then(manifest(newRoot,true)).then(unsafeRoot(newRoot)).expect(not(safeCopy))
  run pathnameRebindManifestCounterexampleTest=init.then(unsafeRebind).expect(not(safeCopy))
}
