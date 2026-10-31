module ProviderRpc {
  type S={stage:int,held:int,burned:bool,token:bool,calls:int,route:int,revision:int,fence:int,observedRevision:int,observedFence:int,
    closing:bool,caller:int,credential:bool,allow:bool,modern:int,legacy:int,next:int,queued:Set[int],delivered:Set[int],allowedRows:Set[int],
    domainCut:int,observedCut:int,encoding:int,frames:int,slot:bool,session:int,pending:bool,releaseToken:bool,commitPending:bool,
    preparedFirst:int,preparedRows:int,preparedEncoding:int,preparedSession:int,dropped:Set[int],
    releases:List[{rows:Set[int],permitted:Set[int],guardRevision:int,currentRevision:int,guardCut:int,currentCut:int,encoding:int,requested:int,cancelled:bool}],invocations:List[{cancelled:bool,guardRevision:int,currentRevision:int}]}
  var s:S
  // domainCut denotes the authenticated original profile/shared-budget/history
  // deciding context. Its concrete mapping is an existing floor-owner premise;
  // it is not another budget evaluator or an informer-cache version.
  val current=s.revision==s.observedRevision and s.fence==s.observedFence and s.allow and s.domainCut==s.observedCut
  val authenticated=s.caller==1 and s.credential
  // Zero denotes an absent field; a negative value denotes an invalid present value.
  pure def boundedCaps(modern:int,legacy:int):bool=
    (modern>0 and modern<=4096 and legacy==0) or (legacy>0 and legacy<=4096 and modern==0)
  val safe=s.calls<=1 and s.held<=8 and (s.stage>0 implies s.held==4) and
    (s.stage>0 implies boundedCaps(s.modern,s.legacy)) and
    s.frames>=0 and s.frames+(if(s.slot)1 else 0)<=2 and s.next<=4 and
    (s.releaseToken implies s.pending and s.preparedSession==s.session) and
    s.releases.indices().forall(i=>{val r=s.releases.nth(i)
      r.rows.subseteq(r.permitted) and r.guardRevision==r.currentRevision and r.guardCut==r.currentCut and
      r.encoding==r.requested and not(r.cancelled) and (r.encoding==0 implies r.rows.size()==1)}) and
    s.releases.indices().forall(i=>s.releases.indices().forall(j=>i==j or s.releases.nth(i).rows.intersect(s.releases.nth(j).rows)==Set())) and
    (s.burned implies s.stage>=2) and (s.token implies s.burned) and s.calls==s.invocations.length() and
    s.invocations.indices().forall(i=>not(s.invocations.nth(i).cancelled) and s.invocations.nth(i).guardRevision==s.invocations.nth(i).currentRevision)
  action init=s'={stage:0,held:0,burned:false,token:false,calls:0,route: -1,revision:0,fence:1,observedRevision:0,observedFence:1,
    closing:false,caller:1,credential:true,allow:true,modern:32,legacy:0,next:0,queued:Set(),delivered:Set(),allowedRows:Set(0,1,2,3),
    domainCut:0,observedCut:0,encoding:0,frames:0,slot:false,session:0,pending:false,releaseToken:false,commitPending:false,
    preparedFirst:0,preparedRows:0,preparedEncoding:0,preparedSession:0,dropped:Set(),releases:List(),invocations:[]}
  // Proposal fields are immutable after admission; no reconnect action resets them.
  action proposeCaps(modern:int,legacy:int):bool=all {s.stage==0,s'=s.with("modern",modern).with("legacy",legacy)}
  action selectEncoding(encoding:int):bool=all {s.stage==0,Set(0,1).contains(encoding),s'=s.with("encoding",encoding)}
  // RPC nonce and reconnect identifiers do not select the canonical task/node key.
  action admit(nonce:int):bool=all {authenticated,not(s.closing),current,s.stage==0,boundedCaps(s.modern,s.legacy),Set(0,1,2).contains(nonce),s'=s.with("stage",1).with("held",4)}
  action unsafePreferredCapAdmission=all {s.stage==0,s.modern>0,s.modern<=4096,s'=s.with("stage",1).with("held",4)}
  action replay=all {authenticated,s.stage>0,s'=s}
  // Transport setup emits no application RPC and cannot select another root.
  action observe=s'=s
  action consume(route:int):bool=all {authenticated,not(s.closing),current,s.stage==1,Set(0,1).contains(route),s'=s.with("stage",2).with("route",route)}
  // A durable burn may finish after cancellation; that does not admit transport.
  action burn=all {s.stage==2,not(s.burned),current,s'=s.with("burned",true).with("token",true)}
  action invoke=all {s.token,current,not(s.closing),s'=s.with("token",false).with("calls",s.calls+1)
    .with("invocations",s.invocations.append({cancelled:s.closing,guardRevision:s.observedRevision,currentRevision:s.revision}))}
  action unsafeLateInvoke=all {s.token,current,s'=s.with("token",false).with("calls",s.calls+1)
    .with("invocations",s.invocations.append({cancelled:s.closing,guardRevision:s.observedRevision,currentRevision:s.revision}))}
  pure def rowGate(t:S,first:int,rows:int,encoding:int):bool=t.calls==1 and t.revision==t.observedRevision and t.fence==t.observedFence and t.allow and t.domainCut==t.observedCut and
    not(t.closing) and rows>0 and rows<=2 and first+rows<=4 and encoding==t.encoding and Set(0,1).contains(encoding) and (encoding==0 implies rows==1) and
    first.to(first+rows-1).subseteq(t.allowedRows)
  pure def appendFrame(t:S,first:int,rows:int,encoding:int):S=t.with("queued",t.queued.union(first.to(first+rows-1))).with("frames",t.frames+1).with("slot",false)
    .with("releases",t.releases.append({rows:first.to(first+rows-1),permitted:t.allowedRows,guardRevision:t.observedRevision,currentRevision:t.revision,
      guardCut:t.observedCut,currentCut:t.domainCut,encoding:encoding,requested:t.encoding,cancelled:t.closing}))
  // Successful prepare/emit/commit abstraction retained for existing composed
  // owners. The microsteps below expose its waits, failures and uncertain cut.
  action batch(rows:int,encoding:int):bool=all {not(s.pending),s.slot or s.frames<2,rowGate(s,s.next,rows,encoding),
    s'=appendFrame(s,s.next,rows,encoding).with("next",s.next+rows)}
  action reserveSlot=all {s.calls==1,not(s.closing),not(s.slot),s.frames<2,s'=s.with("slot",true)}
  action dropSlot=s'=s.with("slot",false)
  action prepareBatch(rows:int,encoding:int):bool=all {s.slot,not(s.pending),rowGate(s,s.next,rows,encoding),
    s'=s.with("preparedFirst",s.next).with("preparedRows",rows).with("preparedEncoding",encoding).with("preparedSession",s.session)
      .with("next",s.next+rows).with("pending",true).with("releaseToken",true)}
  action emitPrepared(encoding:int):bool=all {s.slot,s.pending,s.releaseToken,s.preparedSession==s.session,encoding==s.preparedEncoding,
    rowGate(s,s.preparedFirst,s.preparedRows,encoding),
    s'=appendFrame(s,s.preparedFirst,s.preparedRows,encoding).with("releaseToken",false).with("commitPending",true)}
  action commitRelease=all {s.commitPending,s'=s.with("pending",false).with("commitPending",false)}
  // Draining previously admitted gRPC buffers is distinct from granting a fresh release.
  action deliver=all {s.queued!=Set(),s'=s.with("delivered",s.delivered.union(s.queued)).with("queued",Set()).with("frames",0)}
  action discardQueued=s'=s.with("dropped",s.dropped.union(s.queued)).with("queued",Set()).with("frames",0)
  action publish=s'=s.with("revision",s.revision+1).with("fence",s.fence+1).with("allow",false)
  action advanceDomainCut=s'=s.with("domainCut",s.domainCut+1)
  action reauthorize=all {s.stage==1,s'=s.with("observedRevision",s.revision).with("observedFence",s.fence).with("observedCut",s.domainCut).with("allow",true)}
  action cancel=s'=s.with("closing",true)
  action crash=s'=s.with("token",false).with("slot",false).with("releaseToken",false).with("commitPending",false).with("session",s.session+1)
  // Reconnection sets up a channel only; it cannot un-cancel the original RPC,
  // clear its pending interval or transfer its affine release continuation.
  action reconnect=s'=s
  action badPeer=s'=s.with("caller",2)
  action wrongCredential=s'=s.with("credential",false)
  action complete=all {s.calls==1,current,s.next==4,not(s.pending),s'=s.with("stage",3)}
  action unsafeRetryReset=s'=s.with("stage",1).with("burned",false).with("token",false)
  // Restore a pre-consumption queued image while the publication stays current.
  // This unsafe action is excluded from the ordinary durable-restart relation.
  action unsafeRestoreQueuedImage=all {s.stage>=2,s'=s.with("stage",1).with("burned",false).with("token",false)
    .with("calls",0).with("route",-1).with("next",0).with("queued",Set()).with("delivered",Set()).with("frames",0).with("slot",false)
    .with("pending",false).with("releaseToken",false).with("commitPending",false).with("releases",List()).with("invocations",List())}
  action restrictRows=s'=s.with("allowedRows",Set(0))
  action unsafeEncodingBypass=all {s.allowedRows.contains(s.next),s'=appendFrame(s,s.next,2,s.encoding)}
  action unsafeStaleRelease=s'=appendFrame(s,0,1,s.encoding)
  action unsafeCreditAsAuthority=s'=appendFrame(s,s.next,1,s.encoding).with("next",s.next+1)
  action unsafeReplayPrepared=s'=appendFrame(s,s.preparedFirst,s.preparedRows,s.preparedEncoding)
  action unsafeRefund=s'=s.with("held",0)
  action step={nondet nonce=Set(0,1,2).oneOf() any {proposeCaps(32,0),proposeCaps(0,4096),proposeCaps(32,5000),proposeCaps(0,0),proposeCaps(-1,0),selectEncoding(0),selectEncoding(1),admit(nonce),replay,consume(0),consume(1),burn,invoke,batch(1,0),batch(2,1),reserveSlot,dropSlot,prepareBatch(1,0),prepareBatch(2,1),emitPrepared(0),emitPrepared(1),commitRelease,deliver,discardQueued,publish,advanceDomainCut,reauthorize,cancel,crash,reconnect,badPeer,wrongCredential,complete,restrictRows}}
  action spent=init.then(admit(0)).then(consume(0)).then(burn).then(invoke)
  run defaultRpcCredentialRequiredTest=init.then(wrongCredential).then(admit(0).fail())
  run sameSubjectDifferentKeyRejectedTest=init.then(badPeer).then(admit(1).fail())
  run sourceBoundRouteChosenBeforeConsumptionTest=init.then(admit(0)).then(consume(1)).expect(safe and s.route==1 and s.calls==0)
  run sdkRetryCannotConsumeAgainTest=spent.then(replay).then(consume(1).fail())
  run partialWriteCannotFallbackTest=spent.then(crash).then(consume(1).fail())
  run restartCannotReissueBurnTest=init.then(admit(0)).then(consume(0)).then(burn).then(crash).then(burn.fail())
  run staleReleaseRejectedTest=spent.then(publish).then(batch(1,0).fail())
  run cancelledRpcCannotReleaseTest=spent.then(cancel).then(batch(1,0).fail())
  action arrowSpent=init.then(selectEncoding(1)).then(admit(0)).then(consume(0)).then(burn).then(invoke)
  run protobufUsesRowAuthorityTest=spent.then(batch(1,0)).expect(safe and s.next==1)
  run arrowUsesSameRowAuthorityTest=arrowSpent.then(batch(2,1)).expect(safe and s.next==2)
  run previouslyAdmittedBuffersMayDrainTest=spent.then(batch(1,0)).then(publish).then(deliver).expect(safe and s.delivered==Set(0))
  run completeNeverRefundsTest=arrowSpent.then(batch(2,1)).then(batch(2,1)).then(complete).expect(safe and s.held==4)
  run nonceResetDuplicatesInvocationCounterexampleTest=spent.then(unsafeRetryReset).then(consume(1)).then(burn).then(invoke).expect(not(safe))
  run arrowCannotHideDeniedSecondRowTest=arrowSpent.then(restrictRows).then(batch(2,1).fail())
  run arrowFirstRowOnlyCounterexampleTest=arrowSpent.then(restrictRows).then(unsafeEncodingBypass).expect(not(safe))
  run staleGrantReleaseCounterexampleTest=spent.then(publish).then(unsafeStaleRelease).expect(not(safe))
  run unknownRefundCounterexampleTest=spent.then(crash).then(unsafeRefund).expect(not(safe))
  run cancellationAfterBurnCannotInvokeTest=init.then(admit(0)).then(consume(0)).then(burn).then(cancel).then(invoke.fail())
  run burnAfterCancellationStillCannotInvokeTest=init.then(admit(0)).then(consume(0)).then(cancel).then(burn).then(invoke.fail())
  run earlierAdmittedTransportMayFinishTest=spent.then(cancel).expect(safe and s.calls==1)
  run missingFinalCancellationCheckCounterexampleTest=init.then(admit(0)).then(consume(0)).then(burn).then(cancel).then(unsafeLateInvoke).expect(not(safe))
  run legacySingleCapAdmittedTest=init.then(proposeCaps(0,4096)).then(admit(0)).expect(safe)
  run competingCapsRejectedBeforeHoldTest=init.then(proposeCaps(32,5000)).expect(safe and s.held==0).then(admit(0).fail())
  run absentCapsRejectedTest=init.then(proposeCaps(0,0)).then(admit(0).fail())
  run invalidPresentCapRejectedTest=init.then(proposeCaps(-1,0)).then(admit(0).fail())
  run admittedCapsCannotChangeTest=init.then(admit(0)).expect(safe).then(proposeCaps(32,5000).fail())
  run preferredCapPrecedenceCounterexampleTest=init.then(proposeCaps(32,5000)).then(unsafePreferredCapAdmission).expect(not(safe))
  run boundedPrivateQueueCannotGrowTest=spent.then(batch(1,0)).then(batch(1,0)).expect(safe).then(reserveSlot.fail())
  run returnedCapacityDoesNotAuthorizeStaleReleaseTest=spent.then(batch(1,0)).then(deliver).then(reserveSlot).then(publish).expect(safe).then(prepareBatch(1,0).fail())
  run reservedSlotDoesNotAuthorizeChangedDomainTest=arrowSpent.then(reserveSlot).then(advanceDomainCut).expect(safe).then(prepareBatch(2,1).fail())
  run cancelAfterPrepareRetainsUnknownRangeTest=arrowSpent.then(reserveSlot).then(prepareBatch(2,1)).then(cancel).expect(safe and s.pending and s.held==4).then(emitPrepared(1).fail())
  run policyChangeAfterPrepareRejectsAllRowsTest=arrowSpent.then(reserveSlot).then(prepareBatch(2,1)).then(publish).expect(safe).then(emitPrepared(1).fail())
  run domainChangeAfterPrepareRejectsAllRowsTest=arrowSpent.then(reserveSlot).then(prepareBatch(2,1)).then(advanceDomainCut).expect(safe).then(emitPrepared(1).fail())
  run preparedEncodingCannotSwitchTest=arrowSpent.then(reserveSlot).then(prepareBatch(2,1)).expect(safe).then(emitPrepared(0).fail())
  run reconnectCannotUncancelOriginalStreamTest=arrowSpent.then(cancel).then(reconnect).expect(safe).then(batch(2,1).fail())
  run restartCannotReconstituteUnknownReleaseTest=arrowSpent.then(reserveSlot).then(prepareBatch(2,1)).then(crash).then(reconnect).then(reserveSlot)
    .expect(safe and s.pending and s.next==2 and s.held==4).then(emitPrepared(1).fail())
  run enqueueThenLostCommitRetainsUnknownTest=arrowSpent.then(reserveSlot).then(prepareBatch(2,1)).then(emitPrepared(1)).then(crash).then(deliver)
    .expect(safe and s.pending and s.delivered==Set(0,1) and s.held==4).then(commitRelease.fail())
  run droppedFramesCannotRefundOrResetTest=arrowSpent.then(batch(2,1)).then(cancel).then(discardQueued).then(reconnect).expect(safe and s.next==2 and s.dropped==Set(0,1) and s.held==4)
  run creditAsAuthorizationCounterexampleTest=spent.then(reserveSlot).then(advanceDomainCut).then(unsafeCreditAsAuthority).expect(not(safe))
  run replayAfterEnqueueCounterexampleTest=arrowSpent.then(reserveSlot).then(prepareBatch(2,1)).then(emitPrepared(1)).then(crash).then(unsafeReplayPrepared).expect(not(safe))
  run negotiatedEncodingCannotChangeTest=spent.expect(safe).then(selectEncoding(1).fail())
}
