module TursoMvcc {
  // Four logical messages, two original shared-budget families. Hash collisions
  // may serialize more families; they never create a different budget identity.
  val logicalKeys=Set(0,1,2,3)
  def family(k:int):int=k/2
  type State={pending:Set[int],queued:Set[int],spent:Set[int],permits:Set[int],
    held:int->int,calls:int->int,authorized:int->int,owner:int,permitOwner:int->int,
    fence:int,active:Set[int],recorded:Set[int],stale:bool}
  var s:State
  val initial:State={pending:Set(),queued:Set(),spent:Set(),permits:Set(),held:Map(0->0,1->0,2->0,3->0),
    calls:Map(0->0,1->0,2->0,3->0),authorized:Map(0->1,1->1,2->1,3->1),owner:1,
    permitOwner:Map(0->0,1->0,2->0,3->0),fence:1,active:Set(),recorded:Set(),stale:false}
  val safety=not(s.stale) and logicalKeys.forall(k=>s.calls.get(k)<=1 and
    (s.spent.contains(k) implies s.held.get(k)==3) and
    (s.calls.get(k)>0 implies s.spent.contains(k))) and
    Set(0,1).forall(d=>logicalKeys.filter(k=>family(k)==d).fold(0,(n,k)=>n+s.held.get(k))<=6 and
      s.active.filter(k=>family(k)==d).size()<=1 and s.pending.filter(k=>family(k)==d).size()<=1 and
      not(s.active.exists(k=>family(k)==d) and s.pending.exists(k=>family(k)==d))) and
    s.recorded.forall(k=>s.spent.contains(k) and s.calls.get(k)==1)
  action init=s'=initial
  action begin(k:int):bool=all{not(s.active.exists(p=>family(p)==family(k))),not(s.pending.exists(p=>family(p)==family(k))),s'=s.with("pending",s.pending.union(Set(k)))}
  action reserve(k:int):bool=all{s.pending.contains(k),not(s.queued.contains(k)),
    s'=s.with("pending",s.pending.exclude(Set(k))).with("queued",s.queued.union(Set(k)))
      .with("held",s.held.set(k,3)).with("authorized",s.authorized.set(k,s.fence))}
  action consume(k:int):bool=all{s.pending.contains(k),s.queued.contains(k),not(s.spent.contains(k)),s.authorized.get(k)==s.fence,
    s'=s.with("pending",s.pending.exclude(Set(k))).with("spent",s.spent.union(Set(k)))
      .with("permits",s.permits.union(Set(k))).with("permitOwner",s.permitOwner.set(k,s.owner))}
  action conflict(k:int):bool=all{s.pending.contains(k),s'=s.with("pending",s.pending.exclude(Set(k)))}
  action publish=all{s.pending==Set(),s.active==Set(),s'=s.with("fence",s.fence+1)}
  action finalGuard(k:int):bool=all{not(s.pending.exists(p=>family(p)==family(k))),not(s.active.exists(p=>family(p)==family(k))),s.permits.contains(k),
    s.permitOwner.get(k)==s.owner,s.authorized.get(k)==s.fence,s'=s.with("active",s.active.union(Set(k)))}
  action send(k:int):bool=all{s.active.contains(k),s.spent.contains(k),s.calls.get(k)==0,s.permits.contains(k),
    s'=s.with("calls",s.calls.set(k,1)).with("permits",s.permits.exclude(Set(k)))}
  action finish(k:int):bool=all{s.active.contains(k),s.calls.get(k)==1,s'=s.with("active",s.active.exclude(Set(k))).with("recorded",s.recorded.union(Set(k)))}
  action failUse(k:int):bool=all{s.active.contains(k),s'=s.with("active",s.active.exclude(Set(k))).with("permits",s.permits.exclude(Set(k)))}
  // Partial bytes and lost completion both leave the original hold untouched.
  action replyLoss=s'=s
  action restart=s'=s.with("pending",Set()).with("permits",Set()).with("active",Set()).with("owner",s.owner+1)
  action unsafePublish= s'=s.with("fence",s.fence+1)
  action unsafeSnapshotSend(k:int):bool=s'=s.with("calls",s.calls.set(k,s.calls.get(k)+1)).with("stale",s.authorized.get(k)!=s.fence)
  action unsafeRefund(k:int):bool=s'=s.with("held",s.held.set(k,0))
  action unsafeClaimOnlyLock(k:int):bool=s'=s.with("active",s.active.union(Set(k)))
  action accepted=init.then(begin(0)).then(reserve(0)).then(begin(0)).then(consume(0))
  action step={nondet k=logicalKeys.oneOf() any{begin(k),reserve(k),consume(k),conflict(k),publish,finalGuard(k),send(k),finish(k),failUse(k),replyLoss,restart}}
  run independentFamiliesOverlapTest=init.then(begin(0)).then(begin(2)).then(reserve(0)).then(reserve(2)).expect(safety and s.held.get(0)==3 and s.held.get(2)==3)
  run sharedFamilySerializesTest=init.then(begin(0)).then(begin(1).fail())
  run publishWaitsForAdmissionTest=init.then(begin(0)).then(publish.fail())
  run finalWaitsForSameFamilyAdmissionTest=accepted.then(begin(1)).then(finalGuard(0).fail())
  run finalOverlapsOtherFamilyAdmissionTest=accepted.then(begin(2)).then(finalGuard(0)).expect(safety and s.pending.contains(2) and s.active.contains(0))
  action twoFamilies=accepted.then(begin(2)).then(reserve(2)).then(begin(2)).then(consume(2))
  run independentFinalSendsOverlapTest=twoFamilies.then(finalGuard(0)).then(finalGuard(2)).then(send(0)).then(send(2)).expect(safety and s.active.size()==2).then(finish(0)).then(finish(2)).expect(safety)
  run publicationWaitsForAllFinalDomainsTest=twoFamilies.then(finalGuard(0)).then(finalGuard(2)).then(send(0)).then(finish(0)).then(publish.fail())
  run postSendCommitConflictKeepsPhysicalEffectTest=accepted.then(finalGuard(0)).then(send(0)).then(failUse(0)).then(restart).expect(safety and s.calls.get(0)==1 and s.held.get(0)==3 and not(s.recorded.contains(0))).then(begin(0)).then(consume(0).fail())
  run lostFinalCommitReplyKeepsPhysicalEffectTest=accepted.then(finalGuard(0)).then(send(0)).then(finish(0)).then(replyLoss).then(restart).expect(safety and s.calls.get(0)==1 and s.recorded.contains(0))
  run sameFamilyClaimOnlyLockCounterexampleTest=accepted.then(finalGuard(0)).then(unsafeClaimOnlyLock(1)).expect(not(safety))
  run conflictCannotSendTest=init.then(begin(0)).then(conflict(0)).then(finalGuard(0).fail())
  run conflictRetainsOtherCommittedHoldTest=accepted.then(begin(2)).then(conflict(2)).expect(safety and s.held.get(0)==3)
  run revokeBeforeGuardBlocksSendTest=accepted.then(publish).then(finalGuard(0).fail())
  run finalExcludesPublicationTest=accepted.then(finalGuard(0)).then(publish.fail())
  run partialWriteReplyLossRestartTest=accepted.then(finalGuard(0)).then(send(0)).then(replyLoss).then(restart).expect(safety and s.calls.get(0)==1 and s.held.get(0)==3).then(begin(0)).then(consume(0).fail())
  run restartRejectsOldPermitTest=accepted.then(restart).then(finalGuard(0).fail())
  run lostConsumeReplyCannotRemintTest=accepted.then(replyLoss).then(begin(0)).then(consume(0).fail())
  run snapshotWriteSkewCounterexampleTest=accepted.then(finalGuard(0)).then(unsafePublish).then(unsafeSnapshotSend(0)).expect(not(safety))
  run retryAfterPartialWriteCounterexampleTest=accepted.then(finalGuard(0)).then(send(0)).then(unsafeSnapshotSend(0)).expect(not(safety))
  run unknownRefundCounterexampleTest=accepted.then(restart).then(unsafeRefund(0)).expect(not(safety))
}
