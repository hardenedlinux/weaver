module StreamingExecution {
  type S = {status:int->int, cursor:int->int, hold:int->int, authRev:int->int, authFence:int->int,
    calls:int->int, revision:int, fence:int, generation:int, ownerFence:int,
    permit:int, permitOffset:int, permitGen:int, lock:bool, observed:bool,
    allowed:bool, stale:bool, burned:int, invoked:int, cachedRevision:int}
  var s:S
  val ids=Set(0,1,2)
  val held=s.hold.get(0)+s.hold.get(1)+s.hold.get(2)
  val safe=not(s.stale) and held<=3 and s.invoked<=s.burned and
    0.to(5).forall(k=>s.calls.get(k)<=1) and ids.forall(m=>
      s.cursor.get(m)<=2 and (s.status.get(m)!=0 implies s.hold.get(m)>0) and
      (s.status.get(m)==4 implies s.cursor.get(m)==2))
  val current=s.permit>=0 and s.permitGen==s.generation and s.ownerFence==s.fence and
    s.authRev.get(s.permit)==s.revision and s.authFence.get(s.permit)==s.fence and s.allowed
  action init=s'={status:Map(0->0,1->0,2->0),cursor:Map(0->0,1->0,2->0),hold:Map(0->0,1->0,2->0),
    authRev:Map(0->0,1->0,2->0),authFence:Map(0->1,1->1,2->1),calls:Map(0->0,1->0,2->0,3->0,4->0,5->0),
    revision:0,fence:1,generation:0,ownerFence:1,permit: -1,permitOffset:0,permitGen:0,lock:false,observed:false,
    allowed:true,stale:false,burned:0,invoked:0,cachedRevision: -1}
  action queue(m:int,original:bool):bool=all {
    original,ids.contains(m),s.status.get(m)==0,held+1<=3,s.allowed,
    s'=s.with("status",s.status.set(m,1)).with("hold",s.hold.set(m,1))
      .with("authRev",s.authRev.set(m,s.revision)).with("authFence",s.authFence.set(m,s.fence))
  }
  action claim=all {
    not(s.lock),ids.exists(m=>s.status.get(m)==1),
    ids.forall(m=>not(Set(3,5).contains(s.status.get(m))) and not(s.status.get(m)==2 and s.cursor.get(m)>0)),
    s.allowed,s'=s.with("generation",s.generation+1).with("ownerFence",s.fence)
  }
  action resume(m:int):bool=all {
    s.status.get(m)==1,s.cursor.get(m)==0,s.ownerFence==s.fence,s.allowed,
    s'=s.with("authRev",s.authRev.set(m,s.revision)).with("authFence",s.authFence.set(m,s.fence))
  }
  action burn(m:int,cap:int):bool=all {
    not(s.lock),s.permit == -1,cap==s.generation,cap>0,s.ownerFence==s.fence,s.allowed,
    Set(1,2).contains(s.status.get(m)),s.authRev.get(m)==s.revision,s.authFence.get(m)==s.fence,
    ids.forall(i=>i>=m or s.status.get(i)==4),
    s'=s.with("status",s.status.set(m,3)).with("permit",m).with("permitOffset",s.cursor.get(m))
      .with("permitGen",cap).with("burned",s.burned+1)
  }
  action finalGuard=all {not(s.lock),current,s'=s.with("lock",true)}
  action fullWrite=all {s.lock,current,not(s.observed),
    s'=s.with("calls",s.calls.set(s.permit*2+s.permitOffset,s.calls.get(s.permit*2+s.permitOffset)+1))
      .with("invoked",s.invoked+1).with("observed",true)}
  action commit=all {s.lock,s.observed,s.permit>=0,
    s'=s.with("cursor",s.cursor.set(s.permit,s.permitOffset+1))
      .with("status",s.status.set(s.permit,if(s.permitOffset+1==2)4 else 2))
      .with("permit", -1).with("lock",false).with("observed",false)}
  action partial=all {s.lock,current,not(s.observed),
    s'=s.with("calls",s.calls.set(s.permit*2+s.permitOffset,s.calls.get(s.permit*2+s.permitOffset)+1))
      .with("status",s.status.set(s.permit,5)).with("invoked",s.invoked+1).with("permit", -1).with("lock",false)}
  action noSend=all {not(s.lock),s.permit>=0,not(current),
    s'=s.with("status",s.status.set(s.permit,if(s.permitOffset==0)1 else 2)).with("permit", -1)}
  action publish(allow:bool):bool=all {not(s.lock),s'=s.with("revision",s.revision+1).with("fence",s.fence+1).with("allowed",allow)}
  action crash=s'=s.with("lock",false).with("permit", -1).with("observed",false)
  action lostReply=s'=s
  action warmOldCompilation=s'=s.with("cachedRevision",s.revision-1)
  action unsafeRefund(m:int):bool=s'=s.with("hold",s.hold.set(m,0))
  action unsafeCachedGuard=all {s.permit>=0,s'=s.with("stale",true)}
  action unsafeResetUnknown=s'=s.with("status",s.status.set(0,1))
  action step={nondet m=ids.oneOf() any{queue(m,true),claim,resume(m),burn(m,s.generation),finalGuard,fullWrite,commit,partial,noSend,publish(true),publish(false),crash,lostReply,warmOldCompilation}}
  action queued=init.then(queue(0,true)).then(claim)
  action consumed=queued.then(burn(0,1))
  action first=consumed.then(finalGuard).then(fullWrite).then(commit)
  action complete=first.then(burn(0,1)).then(finalGuard).then(fullWrite).then(commit)
  run queueHasNoWireTest=queued.expect(safe and s.invoked==0 and held==1)
  run sourceIdentityRequiredTest=init.then(queue(0,false).fail())
  run messageOrderRequiredTest=init.then(queue(1,true)).then(claim).then(burn(1,1).fail())
  run wholeMessageKeepsHoldTest=complete.expect(safe and held==1 and s.cursor.get(0)==2)
  run completedKeyCannotRetryTest=complete.then(burn(0,1).fail())
  run revokedBetweenBurnAndWriteTest=consumed.then(publish(false)).then(finalGuard.fail())
  run zeroCallCanReauthorizeOriginalTest=consumed.then(publish(false)).then(noSend).then(publish(true)).then(claim).then(resume(0)).then(burn(0,2)).then(finalGuard).then(fullWrite).then(commit).expect(safe and held==1)
  run crashBeforeWriteCannotReissueTest=consumed.then(crash).then(claim.fail())
  run lostCompletionBeforeCommitCannotReissueTest=consumed.then(finalGuard).then(fullWrite).then(crash).then(claim.fail())
  run partialCannotReconnectTest=consumed.then(finalGuard).then(partial).then(claim.fail())
  run incompleteKnownPrefixCannotReconnectTest=first.then(publish(true)).then(claim.fail())
  run oldWorkerCapabilityRejectedTest=queued.then(claim).then(burn(0,1).fail())
  run effectivePublicationSerializedTest=consumed.then(finalGuard).then(publish(false).fail())
  run warmCompilationIsNotPermissionTest=consumed.then(publish(false)).then(warmOldCompilation).then(finalGuard.fail())
  run duplicateRefundCounterexampleTest=consumed.then(crash).then(unsafeRefund(0)).expect(not(safe))
  run cachedGrantCounterexampleTest=consumed.then(publish(false)).then(unsafeCachedGuard).expect(not(safe))
  run unknownResetDuplicatesRangeCounterexampleTest=consumed.then(finalGuard).then(fullWrite).then(crash).then(unsafeResetUnknown).then(claim).then(burn(0,2)).then(finalGuard).then(fullWrite).expect(not(safe))
}
