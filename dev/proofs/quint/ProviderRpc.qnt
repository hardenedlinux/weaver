module ProviderRpc {
  type S={stage:int,held:int,burned:bool,token:bool,calls:int,route:int,revision:int,fence:int,observedRevision:int,observedFence:int,
    closing:bool,caller:int,credential:bool,allow:bool,modern:int,legacy:int,next:int,queued:Set[int],delivered:Set[int],allowedRows:Set[int],
    releases:List[{rows:Set[int],permitted:Set[int],guardRevision:int,currentRevision:int}],invocations:List[{cancelled:bool,guardRevision:int,currentRevision:int}]}
  var s:S
  val current=s.revision==s.observedRevision and s.fence==s.observedFence and s.allow
  val authenticated=s.caller==1 and s.credential
  // Zero denotes an absent field; a negative value denotes an invalid present value.
  pure def boundedCaps(modern:int,legacy:int):bool=
    (modern>0 and modern<=4096 and legacy==0) or (legacy>0 and legacy<=4096 and modern==0)
  val safe=s.calls<=1 and s.held<=8 and (s.stage>0 implies s.held==4) and
    (s.stage>0 implies boundedCaps(s.modern,s.legacy)) and
    s.releases.indices().forall(i=>s.releases.nth(i).rows.subseteq(s.releases.nth(i).permitted) and s.releases.nth(i).guardRevision==s.releases.nth(i).currentRevision) and
    (s.burned implies s.stage>=2) and (s.token implies s.burned) and s.calls==s.invocations.length() and
    s.invocations.indices().forall(i=>not(s.invocations.nth(i).cancelled) and s.invocations.nth(i).guardRevision==s.invocations.nth(i).currentRevision)
  action init=s'={stage:0,held:0,burned:false,token:false,calls:0,route: -1,revision:0,fence:1,observedRevision:0,observedFence:1,
    closing:false,caller:1,credential:true,allow:true,modern:32,legacy:0,next:0,queued:Set(),delivered:Set(),allowedRows:Set(0,1,2,3),releases:List(),invocations:[]}
  // Proposal fields are immutable after admission; no reconnect action resets them.
  action proposeCaps(modern:int,legacy:int):bool=all {s.stage==0,s'=s.with("modern",modern).with("legacy",legacy)}
  // RPC nonce and reconnect identifiers do not select the canonical task/node key.
  action admit(nonce:int):bool=all {authenticated,not(s.closing),current,s.stage==0,boundedCaps(s.modern,s.legacy),Set(0,1,2).contains(nonce),s'=s.with("stage",1).with("held",4)}
  action unsafePreferredCapAdmission=all {s.stage==0,s.modern>0,s.modern<=4096,s'=s.with("stage",1).with("held",4)}
  action replay=all {authenticated,s.stage>0,s'=s}
  action consume(route:int):bool=all {authenticated,not(s.closing),current,s.stage==1,Set(0,1).contains(route),s'=s.with("stage",2).with("route",route)}
  // A durable burn may finish after cancellation; that does not admit transport.
  action burn=all {s.stage==2,not(s.burned),current,s'=s.with("burned",true).with("token",true)}
  action invoke=all {s.token,current,not(s.closing),s'=s.with("token",false).with("calls",s.calls+1)
    .with("invocations",s.invocations.append({cancelled:s.closing,guardRevision:s.observedRevision,currentRevision:s.revision}))}
  action unsafeLateInvoke=all {s.token,current,s'=s.with("token",false).with("calls",s.calls+1)
    .with("invocations",s.invocations.append({cancelled:s.closing,guardRevision:s.observedRevision,currentRevision:s.revision}))}
  action batch(rows:int,encoding:int):bool=all {s.calls==1,current,not(s.closing),rows>0,rows<=2,s.next+rows<=4,Set(0,1).contains(encoding),
    s.next.to(s.next+rows-1).subseteq(s.allowedRows),
    s'=s.with("queued",s.queued.union(s.next.to(s.next+rows-1))).with("next",s.next+rows)
      .with("releases",s.releases.append({rows:s.next.to(s.next+rows-1),permitted:s.allowedRows,guardRevision:s.observedRevision,currentRevision:s.revision}))}
  // Draining previously admitted gRPC buffers is distinct from granting a fresh release.
  action deliver=all {s.queued!=Set(),s'=s.with("delivered",s.delivered.union(s.queued)).with("queued",Set())}
  action publish=s'=s.with("revision",s.revision+1).with("fence",s.fence+1).with("allow",false)
  action reauthorize=all {s.stage==1,s'=s.with("observedRevision",s.revision).with("observedFence",s.fence).with("allow",true)}
  action cancel=s'=s.with("closing",true)
  action crash=s'=s.with("token",false)
  action badPeer=s'=s.with("caller",2)
  action wrongCredential=s'=s.with("credential",false)
  action complete=all {s.calls==1,current,s.next==4,s'=s.with("stage",3)}
  action unsafeRetryReset=s'=s.with("stage",1).with("burned",false).with("token",false)
  action restrictRows=s'=s.with("allowedRows",Set(0))
  action unsafeEncodingBypass=all {s.allowedRows.contains(s.next),s'=s.with("releases",s.releases.append({rows:s.next.to(s.next+1),permitted:s.allowedRows,guardRevision:s.observedRevision,currentRevision:s.revision}))}
  action unsafeStaleRelease=s'=s.with("releases",s.releases.append({rows:Set(0),permitted:s.allowedRows,guardRevision:s.observedRevision,currentRevision:s.revision}))
  action unsafeRefund=s'=s.with("held",0)
  action step={nondet nonce=Set(0,1,2).oneOf() any {proposeCaps(32,0),proposeCaps(0,4096),proposeCaps(32,5000),proposeCaps(0,0),proposeCaps(-1,0),admit(nonce),replay,consume(0),consume(1),burn,invoke,batch(1,0),batch(2,1),deliver,publish,reauthorize,cancel,crash,badPeer,wrongCredential,complete,restrictRows}}
  action spent=init.then(admit(0)).then(consume(0)).then(burn).then(invoke)
  run defaultRpcCredentialRequiredTest=init.then(wrongCredential).then(admit(0).fail())
  run sameSubjectDifferentKeyRejectedTest=init.then(badPeer).then(admit(1).fail())
  run sourceBoundRouteChosenBeforeConsumptionTest=init.then(admit(0)).then(consume(1)).expect(safe and s.route==1 and s.calls==0)
  run sdkRetryCannotConsumeAgainTest=spent.then(replay).then(consume(1).fail())
  run partialWriteCannotFallbackTest=spent.then(crash).then(consume(1).fail())
  run restartCannotReissueBurnTest=init.then(admit(0)).then(consume(0)).then(burn).then(crash).then(burn.fail())
  run staleReleaseRejectedTest=spent.then(publish).then(batch(1,0).fail())
  run cancelledRpcCannotReleaseTest=spent.then(cancel).then(batch(1,0).fail())
  run arrowAndProtobufShareAuthorityTest=spent.then(batch(1,0)).then(batch(2,1)).expect(safe and s.next==3)
  run previouslyAdmittedBuffersMayDrainTest=spent.then(batch(1,0)).then(publish).then(deliver).expect(safe and s.delivered==Set(0))
  run completeNeverRefundsTest=spent.then(batch(2,1)).then(batch(2,1)).then(complete).expect(safe and s.held==4)
  run nonceResetDuplicatesInvocationCounterexampleTest=spent.then(unsafeRetryReset).then(consume(1)).then(burn).then(invoke).expect(not(safe))
  run arrowCannotHideDeniedSecondRowTest=spent.then(restrictRows).then(batch(2,1).fail())
  run arrowFirstRowOnlyCounterexampleTest=spent.then(restrictRows).then(unsafeEncodingBypass).expect(not(safe))
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
}
