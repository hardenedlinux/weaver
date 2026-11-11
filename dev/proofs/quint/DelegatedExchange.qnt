// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

module DelegatedExchange {
  type Release = {token:int,approved:bool,current:bool,peer:bool,operation:bool,policy:bool,at:int,expiry:int}
  type Session = {generation:int,parent:bool,parentExpiry:int,actorExpiry:int,child:bool,
    serial:int,expiry:int,busy:bool,unknown:bool,cut:int,posts:int,clock:int,
    grant:int,grantPeer:int,revoked:Set[int],inflight:bool,peer:int,operation:bool,
    policy:bool,releases:List[Release]}
  var s:Session
  pure val initial = {generation:0,parent:false,parentExpiry:0,actorExpiry:100,child:false,
    serial:0,expiry:0,busy:false,unknown:false,cut:-1,posts:0,clock:0,
    grant:0,grantPeer:0,revoked:Set(),inflight:false,peer:0,operation:false,policy:true,releases:[]}
  action init = s'=initial
  pure def cap(a:int,b:int):int = if (a<b) a else b
  action shortActor = all {s.generation==0,s'=s.with("actorExpiry",2)}
  val parentReady = s.parent and s.clock<s.parentExpiry and s.clock<s.actorExpiry
  val childReady = s.child and parentReady and s.clock<s.expiry
  action login = all {not(s.busy),s'=s.with("generation",s.generation+1).with("parent",true)
    .with("parentExpiry",s.clock+8).with("child",false).with("unknown",false)}
  action beginExchange(resource:int,audience:int):bool = all {parentReady,not(childReady),not(s.busy),not(s.unknown),resource==0,audience==0,
    s'=s.with("unknown",true).with("busy",true).with("child",false).with("cut",s.generation).with("posts",s.posts+1)}
  action activate(scope:bool,accessType:bool):bool = all {s.busy,s.cut==s.generation,parentReady,scope,accessType,
    s'=s.with("unknown",false).with("busy",false).with("child",true).with("serial",s.serial+1)
      .with("expiry",cap(s.clock+4,cap(s.parentExpiry,s.actorExpiry)))}
  action cancel = s'=s.with("busy",false).with("cut",-1)
  // All authority/uncertainty fields are durable; only in-flight execution is volatile.
  action restart = s'=s.with("busy",false).with("cut",-1).with("inflight",false)
  action logout = s'=s.with("generation",s.generation+1).with("parent",false)
    .with("child",false).with("busy",false).with("cut",-1)
  action tick = s'=s.with("clock",s.clock+1)
  action publish(source:bool,approved:bool,peer:int):bool = all {source,approved,childReady,
    not(s.revoked.contains(s.serial)),s'=s.with("grant",s.serial).with("grantPeer",peer)}
  action revoke(source:bool):bool = all {source,s.grant>0,s'=s.with("revoked",s.revoked.union(Set(s.grant)))}
  action changePolicy = s'=s.with("policy",false)
  val grantCurrent = s.grant>0 and s.grant==s.serial and not(s.revoked.contains(s.grant))
  action beginRpc(peer:int,operation:bool):bool = all {childReady,grantCurrent,peer==1,s.grantPeer==peer,operation,s.policy,
    s'=s.with("inflight",true).with("peer",peer).with("operation",operation)}
  val receipt = {token:s.serial,approved:s.grant==s.serial and s.grant>0,current:grantCurrent,
    peer:s.peer==1 and s.grantPeer==s.peer,operation:s.operation,policy:s.policy,at:s.clock,expiry:s.expiry}
  action release = all {s.inflight,grantCurrent,s.peer==1,s.grantPeer==s.peer,s.operation,s.policy,s.clock<s.expiry,
    s'=s.with("inflight",false).with("releases",s.releases.append(receipt))}
  action unsafeRelease = s'=s.with("releases",s.releases.append(receipt))
  action unsafeRpcWithoutOperation = s'=s.with("inflight",true).with("peer",1).with("operation",false)
  val safety = s.releases.indices().forall(i=>{
    val r=s.releases.nth(i)
    r.token>0 and r.approved and r.current and r.peer and r.operation and r.policy and r.at<r.expiry
  }) and (s.child implies s.expiry<=s.parentExpiry and s.expiry<=s.actorExpiry)
  action step = any {shortActor,login,beginExchange(0,0),beginExchange(1,0),beginExchange(0,1),activate(true,true),
    activate(false,true),activate(true,false),cancel,restart,logout,tick,publish(true,true,1),publish(true,true,2),
    publish(false,true,1),revoke(true),revoke(false),changePolicy,beginRpc(1,true),beginRpc(2,true),
    beginRpc(1,false),release}
  action ready = init.then(login).then(beginExchange(0,0)).then(activate(true,true))
  action approved = ready.then(publish(true,true,1))
  run fourCallersOnlyStartOnePostTest = init.then(login).then(beginExchange(0,0)).then(beginExchange(0,0).fail())
  run wrongResourceCannotExchangeTest = init.then(login).then(beginExchange(1,0).fail())
  run wrongAudienceCannotExchangeTest = init.then(login).then(beginExchange(0,1).fail())
  run wrongScopeCannotActivateTest = init.then(login).then(beginExchange(0,0)).then(activate(false,true).fail())
  run identityTokenCannotBecomeBearerTest = init.then(login).then(beginExchange(0,0)).then(activate(true,false).fail())
  run cancelledExchangeCannotReplayAfterRestartTest = init.then(login).then(beginExchange(0,0)).then(cancel)
    .then(restart).then(beginExchange(0,0).fail())
  run freshParentResolvesUnknownExchangeTest = init.then(login).then(beginExchange(0,0)).then(cancel)
    .then(login).then(beginExchange(0,0)).then(activate(true,true)).expect(s.posts==2 and safety)
  run logoutRejectsLateExchangeTest = init.then(login).then(beginExchange(0,0)).then(logout)
    .then(activate(true,true).fail())
  run exchangeAloneCannotAuthorizeOperationTest = ready.then(beginRpc(1,true).fail())
  run operationLaneCannotPublishItsOwnGrantTest = ready.then(publish(false,true,1).fail())
  run wrongPeerCannotUseApprovedGrantTest = approved.then(beginRpc(2,true).fail())
  run operationBearerStillRequiredTest = approved.then(beginRpc(1,false).fail())
  run positiveCompleteReleaseTest = approved.then(beginRpc(1,true)).then(release).expect(safety)
  run revokeWhileProviderWaitsBlocksReleaseTest = approved.then(beginRpc(1,true)).then(revoke(true)).then(release.fail())
  run policyChangeWhileProviderWaitsBlocksReleaseTest = approved.then(beginRpc(1,true)).then(changePolicy).then(release.fail())
  run revokedGrantStaysRevokedAcrossRestartTest = approved.then(revoke(true)).then(restart).then(beginRpc(1,true).fail())
  run unsafeRevokedReleaseCounterexampleTest = approved.then(beginRpc(1,true)).then(revoke(true))
    .then(unsafeRelease).expect(not(safety))
  run exchangeAsGrantCounterexampleTest = ready.then(unsafeRelease).expect(not(safety))
  run freshChildCannotRepeatExchangeTest = ready.then(beginExchange(0,0).fail())
  run actorExpiryCapsInflightReleaseTest = init.then(shortActor).then(login).then(beginExchange(0,0))
    .then(activate(true,true)).then(publish(true,true,1)).then(beginRpc(1,true))
    .then(tick).then(tick).then(release.fail())
  run restartReusesCurrentChildWithoutExchangeTest = approved.then(restart)
    .then(beginRpc(1,true)).then(release).expect(s.posts==1 and safety)
  run missingOperationBearerCounterexampleTest = approved.then(unsafeRpcWithoutOperation)
    .then(unsafeRelease).expect(not(safety))
}
