module AuthorityPublication {
  import ProviderRpc as E from "./ProviderRpc"
  import PublicationRecovery as A from "./PublicationRecovery"
  // Go activation composes existing publication and execution models. It does
  // not redeclare their CAS, nonce, budget or Cedar semantics.
  type Control={compiled:int,desired:int,registered:bool,ack:bool,active:bool}
  var c:Control
  val original=A::authority.records.get(0)
  val safe=E::safe and A::safe and
    (c.active implies c.compiled>=0 and c.registered and original.outcome==1 and original.payload==c.compiled and c.ack) and
    (A::authority.head>=0 implies E::s.revision==A::authority.head and E::s.fence==A::authority.fence)
  action init=all {E::init,A::init,c'={compiled:-1,desired:0,registered:false,ack:false,active:false}}
  // Concrete source admission is witnessed by Scheme/FFI/Go tests, not a
  // duplicate Boolean implementation of those validators in this model.
  action compile(accepted:bool):bool=all {accepted,c.compiled<0,c'=c.with("compiled",c.desired),E::observe,A::observe}
  action editSource=all {c'=c.with("desired",1),E::observe,A::observe}
  action register=all {c.compiled>=0,c'=c.with("registered",true),E::observe,A::observe}
  action commit=all {c.registered,
    any {A::publish(0,c.compiled,-1,1),A::replay(0,c.compiled,-1,1)},c'=c,E::observe}
  action acknowledge=all {original.outcome==1,original.payload==c.compiled,c'=c.with("ack",true),E::observe,A::observe}
  action recover(source:int):bool=all {original.outcome==1,source==c.compiled,A::replay(0,source,-1,1),c'=c.with("ack",true),E::observe}
  action activate=all {original.outcome==1,c.ack,original.payload==c.compiled,c'=c.with("active",true),E::observe,A::observe}
  action loseReply=all {c'=c.with("ack",false).with("active",false),E::observe,A::observe}
  action restart=all {c'=c.with("active",false).with("ack",false),E::crash,A::restart}
  action publish={nondet id=Set(1,2).oneOf()
    all {A::authority.head>=0,A::authority.records.get(id).outcome==0,A::publish(id,1,A::authority.head,A::authority.fence+1),c'=c,E::publish}}
  action transport=all {c'=c,E::observe,A::observe}
  action admit=all {c.active,c'=c,E::admit(0),A::observe}
  action consume=all {c.active,c'=c,E::consume(0),A::observe}
  action burn=all {c.active,c'=c,E::burn,A::observe}
  action invoke=all {c.active,c'=c,E::invoke,A::observe}
  action release=all {c.active,c'=c,E::batch(1,0),A::observe}
  action deliver=all {c'=c,E::deliver,A::observe}
  action step=any {compile(true),editSource,register,commit,acknowledge,recover(0),recover(1),activate,loseReply,restart,publish,transport,admit,consume,burn,invoke,release,deliver}
  action prepared=init.then(compile(true)).then(register)
  action ready=prepared.then(commit).then(acknowledge).then(activate)
  action spent=ready.then(admit).then(consume).then(burn).then(invoke)
  action unsafeRecoverDesired=all {original.outcome==1,c'=c.with("compiled",c.desired).with("ack",true).with("active",true),E::observe,A::observe}
  action unsafeActivateWithoutOutcome=all {c'=c.with("active",true),E::observe,A::observe}
  action unsafeRetry=all {c'=c,E::unsafeRetryReset,A::observe}
  run authorityUncompiledSourceCannotRegisterTest=init.then(register.fail())
  run authorityRejectedSourceCannotCompileTest=init.then(compile(false).fail())
  run authoritySourceCommitNeverSendsTest=prepared.then(commit).expect(safe and E::s.calls==0 and E::s.held==0)
  run authorityLostReplyCannotActivateTest=prepared.then(commit).then(loseReply).then(activate.fail())
  run authorityLostReplyAndOwnerRestartPreserveOutcomeTest=prepared.then(commit).then(loseReply).then(restart).then(recover(0)).then(activate).expect(safe and original.payload==0 and E::s.calls==0)
  run authorityChangedCompiledSourceCannotRecoverTest=prepared.then(commit).then(editSource).then(recover(1).fail())
  run authorityEditingFileCannotRewriteFrozenCommandTest=prepared.then(editSource).then(commit).then(acknowledge).then(activate).expect(safe and original.payload==0 and c.desired==1)
  run authorityHistoricalReceiptCannotOverrideRevocationTest=ready.then(publish).then(restart).then(recover(0)).then(activate).then(admit.fail())
  run authorityPartialReleaseRevokeAndDualRestartTest=spent.then(release).then(publish).then(restart).then(recover(0)).then(activate).expect(safe and E::s.held==4 and E::s.calls==1).then(release.fail())
  run authoritySdkRetryDoesNotCreateFreshRootTest=spent.then(transport).then(restart).then(recover(0)).then(activate).then(admit.fail())
  run authorityDesiredSourceRecoveryCounterexampleTest=prepared.then(commit).then(editSource).then(unsafeRecoverDesired).expect(not(safe))
  run authorityActivateWithoutOutcomeCounterexampleTest=prepared.then(unsafeActivateWithoutOutcome).expect(not(safe))
  run authorityRetryResetCounterexampleTest=spent.then(unsafeRetry).then(consume).then(burn).then(invoke).expect(not(safe))
}
