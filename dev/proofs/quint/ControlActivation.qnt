module ControlActivation {
  import ProviderRpc as P from "./ProviderRpc"
  type Gate={typed:bool,semantic:bool,open:bool,ffi:bool,registered:bool,committed:bool,ack:bool,active:bool}
  var g:Gate
  // Refinement premise: actual Record/Function and Go/Rust decoders establish
  // this fact. The Boolean model does not prove those implementations correct.
  action decode(valid:bool):bool=all {not(g.registered),g'=g.with("typed",valid),P::observe}
  val safe=P::safe and (g.active implies g.typed and g.semantic and g.open and g.ffi and g.registered and g.committed and g.ack)
  action init=all {P::init,g'={typed:false,semantic:false,open:false,ffi:false,registered:false,committed:false,ack:false,active:false}}
  action assess(ready:bool):bool=all {not(g.registered),g'=g.with("semantic",ready),P::observe}
  // Only native open-patterns, after denylist/conflict/clipping, qualify here.
  // Actionable candidates and a passing C ABI preflight are not send permits.
  action nativeProjection(admitted:bool):bool=all {not(g.registered),g'=g.with("open",admitted),P::observe}
  action preflight=all {not(g.registered),g'=g.with("ffi",true),P::observe}
  action register=all {g.typed,g.semantic,g.open,g'=g.with("registered",true),P::observe}
  action commit=all {g.registered,g.ffi,not(g.committed),g'=g.with("committed",true),P::observe}
  action ack=all {g.committed,g'=g.with("ack",true),P::observe}
  action activate=all {g.typed,g.ack,g.semantic,g.open,g.ffi,g.registered,g'=g.with("active",true),P::observe}
  action stop=all {g'=g.with("active",false),P::observe}
  action transport=all {g'=g,P::observe}
  action admit=all {g.active,g'=g,P::admit(0)}
  action consume=all {g.active,g'=g,P::consume(0)}
  action burn=all {g.active,g'=g,P::burn}
  action invoke=all {g.active,g'=g,P::invoke}
  action release=all {g.active,g'=g,P::batch(1,0)}
  action publish=all {g'=g,P::publish}
  action crash=all {g'=g.with("active",false),P::crash}
  action deliver=all {g'=g,P::deliver}
  action step=any {decode(true),decode(false),assess(true),assess(false),nativeProjection(true),nativeProjection(false),preflight,register,commit,ack,activate,stop,transport,admit,consume,burn,invoke,release,publish,crash,deliver}
  action compiled=init.then(decode(true)).then(assess(true)).then(nativeProjection(true)).then(preflight)
  action ready=compiled.then(register).then(commit).then(ack).then(activate)
  action spent=ready.then(admit).then(consume).then(burn).then(invoke)
  action unsafeActivateFromPreflight=all {g.ffi,g'=g.with("active",true),P::observe}
  action unsafeRetry=all {g'=g,P::unsafeRetryReset}
  run nativeDenylistCannotBecomeRegistrationTest=init.then(decode(true)).then(assess(true)).then(nativeProjection(false)).then(preflight).then(register.fail())
  run unresolvedGovernanceCannotRegisterTest=init.then(decode(true)).then(assess(false)).then(nativeProjection(true)).then(preflight).then(register.fail())
  run ffiPreflightCannotSendTest=compiled.expect(safe and P::s.calls==0 and P::s.held==0).then(admit.fail())
  run unknownCommitCannotActivateTest=compiled.then(register).then(commit).expect(safe).then(activate.fail())
  run lostReplyRecoveryPreservesOriginalCommitTest=compiled.then(register).then(commit).then(stop).then(ack).then(activate).expect(safe and P::s.calls==0)
  run activationIsNotFreshCedarTest=ready.then(publish).expect(safe).then(admit.fail())
  run partialReleaseRevokeAndDualRestartTest=spent.then(release).then(publish).then(crash).then(ack).then(activate).expect(safe and P::s.held==4 and P::s.calls==1).then(release.fail())
  run sdkRetryDoesNotCreateFreshRootTest=spent.then(transport).then(crash).then(activate).expect(safe).then(admit.fail())
  run sourceCommitNeverSendsTest=compiled.then(register).then(commit).expect(safe and P::s.calls==0 and P::s.held==0)
  run malformedContractCannotRegisterTest=init.then(decode(false)).then(assess(true)).then(nativeProjection(true)).then(preflight).then(register.fail())
  run jsonRegistrationWithoutTypedPolicyCannotActivateTest=init.then(decode(true)).then(assess(true)).then(nativeProjection(true)).then(register).expect(safe and P::s.calls==0 and P::s.held==0).then(commit.fail())
  run preflightAsAuthorityCounterexampleTest=compiled.then(unsafeActivateFromPreflight).expect(not(safe))
  run retryResetCounterexampleTest=spent.then(unsafeRetry).then(consume).then(burn).then(invoke).expect(not(safe))
}
