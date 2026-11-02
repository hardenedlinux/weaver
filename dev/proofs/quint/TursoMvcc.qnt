module TursoMvcc {
  // Four logical messages, two original shared-budget families. Hash collisions
  // may serialize more families; they never create a different budget identity.
  val logicalKeys=Set(0,1,2,3)
  def family(k:int):int=k/2
  type State={pending:Set[int],queued:Set[int],spent:Set[int],permits:Set[int],
    held:int->int,calls:int->int,authorized:int->int,owner:int,permitOwner:int->int,
    fence:int,finalKey:int,stale:bool}
  var s:State
  val initial:State={pending:Set(),queued:Set(),spent:Set(),permits:Set(),held:Map(0->0,1->0,2->0,3->0),
    calls:Map(0->0,1->0,2->0,3->0),authorized:Map(0->1,1->1,2->1,3->1),owner:1,
    permitOwner:Map(0->0,1->0,2->0,3->0),fence:1,finalKey: -1,stale:false}
  val safety=not(s.stale) and logicalKeys.forall(k=>s.calls.get(k)<=1 and
    (s.spent.contains(k) implies s.held.get(k)==3) and
    (s.calls.get(k)>0 implies s.spent.contains(k))) and
    Set(0,1).forall(d=>logicalKeys.filter(k=>family(k)==d).fold(0,(n,k)=>n+s.held.get(k))<=6)
  action init=s'=initial
  action begin(k:int):bool=all{s.finalKey== -1,not(s.pending.exists(p=>family(p)==family(k))),s'=s.with("pending",s.pending.union(Set(k)))}
  action reserve(k:int):bool=all{s.pending.contains(k),not(s.queued.contains(k)),
    s'=s.with("pending",s.pending.exclude(Set(k))).with("queued",s.queued.union(Set(k)))
      .with("held",s.held.set(k,3)).with("authorized",s.authorized.set(k,s.fence))}
  action consume(k:int):bool=all{s.pending.contains(k),s.queued.contains(k),not(s.spent.contains(k)),s.authorized.get(k)==s.fence,
    s'=s.with("pending",s.pending.exclude(Set(k))).with("spent",s.spent.union(Set(k)))
      .with("permits",s.permits.union(Set(k))).with("permitOwner",s.permitOwner.set(k,s.owner))}
  action conflict(k:int):bool=all{s.pending.contains(k),s'=s.with("pending",s.pending.exclude(Set(k)))}
  action publish=all{s.pending==Set(),s.finalKey== -1,s'=s.with("fence",s.fence+1)}
  action finalGuard(k:int):bool=all{s.pending==Set(),s.finalKey== -1,s.permits.contains(k),
    s.permitOwner.get(k)==s.owner,s.authorized.get(k)==s.fence,s'=s.with("finalKey",k)}
  action send(k:int):bool=all{s.finalKey==k,s.spent.contains(k),s.calls.get(k)==0,
    s'=s.with("calls",s.calls.set(k,1)).with("permits",s.permits.exclude(Set(k))).with("finalKey",-1)}
  // Partial bytes and lost completion both leave the original hold untouched.
  action replyLoss=s'=s
  action restart=s'=s.with("pending",Set()).with("permits",Set()).with("finalKey",-1).with("owner",s.owner+1)
  action unsafePublish= s'=s.with("fence",s.fence+1)
  action unsafeSnapshotSend(k:int):bool=s'=s.with("calls",s.calls.set(k,s.calls.get(k)+1)).with("stale",s.authorized.get(k)!=s.fence)
  action unsafeRefund(k:int):bool=s'=s.with("held",s.held.set(k,0))
  action accepted=init.then(begin(0)).then(reserve(0)).then(begin(0)).then(consume(0))
  action step={nondet k=logicalKeys.oneOf() any{begin(k),reserve(k),consume(k),conflict(k),publish,finalGuard(k),send(k),replyLoss,restart}}
  run independentFamiliesOverlapTest=init.then(begin(0)).then(begin(2)).then(reserve(0)).then(reserve(2)).expect(safety and s.held.get(0)==3 and s.held.get(2)==3)
  run sharedFamilySerializesTest=init.then(begin(0)).then(begin(1).fail())
  run publishWaitsForAdmissionTest=init.then(begin(0)).then(publish.fail())
  run finalWaitsForAdmissionTest=accepted.then(begin(2)).then(finalGuard(0).fail())
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
