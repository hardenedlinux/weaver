// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

module OAuthCredentials {
  type Send = {generation:int,credential:int,target:int,scope:bool,at:int,expiry:int,ready:bool}
  type Credentials = {generation:int,status:int,durable:int,busy:bool,
    attempt:int,inflight:int,activeGeneration:int,credential:int,clock:int,expiry:int,target:int,scope:bool,posts:int,sends:List[Send]}
  var c:Credentials
  // 0 requires login, 1 ready, 2 uncertain, 3 revoked.
  pure val initial = {generation:0,status:0,durable:0,busy:false,attempt:-1,inflight:-1,activeGeneration:-1,
    credential:0,clock:0,expiry:0,target:0,scope:false,posts:0,sends:[]}
  action init = c'=initial
  action beginLogin = all {not(c.busy),
    c'=c.with("generation",c.generation+1).with("attempt",c.generation+1)}
  action beginGrant = all {not(c.busy),c.attempt==c.generation,
    c'=c.with("status",2).with("durable",2).with("busy",true).with("posts",c.posts+1)
      .with("inflight",c.generation).with("attempt",-1)}
  action completeGrant(g:int,target:int,scope:bool):bool = all {
    c.busy,g==c.generation,g==c.inflight,target==0,scope,
    c'=c.with("status",1).with("durable",1).with("busy",false)
      .with("expiry",c.clock+2).with("target",target).with("scope",scope).with("activeGeneration",g)
      .with("credential",c.credential+1)}
  action refresh = all {not(c.busy),c.status==1,c.clock>=c.expiry,
    c'=c.with("status",2).with("durable",2).with("busy",true)
      .with("inflight",c.generation).with("posts",c.posts+1)}
  action cancel = c'=c.with("busy",false)
  action logout = c'=c.with("generation",c.generation+1).with("status",3)
    .with("durable",3).with("scope",false).with("busy",false)
  action restart = c'=c.with("status",c.durable).with("busy",false).with("attempt",-1).with("inflight",-1)
  action tick = c'=c.with("clock",c.clock+1)
  action rejectToken(token:int):bool = if (c.status==1 and token==c.credential)
    c'=c.with("status",2).with("durable",2).with("scope",false) else c'=c
  val receipt = {generation:c.activeGeneration,credential:c.credential,target:c.target,scope:c.scope,
    at:c.clock,expiry:c.expiry,ready:c.status==1}
  action send = all {c.status==1,c.clock<c.expiry,c.target==0,c.scope,
    c'=c.with("sends",c.sends.append(receipt))}
  action unsafeSend = c'=c.with("sends",c.sends.append(receipt))
  val safety = c.sends.indices().forall(i => {
    val sent=c.sends.nth(i)
    sent.ready and sent.generation>=0 and sent.credential>0 and
      sent.target==0 and sent.scope and sent.at<sent.expiry
  }) and (c.status==2 implies c.durable==2) and
    (c.status==1 implies c.target==0 and c.scope)
  action step = any {beginLogin,beginGrant,completeGrant(c.inflight,0,true),
    refresh,cancel,logout,restart,tick,send,rejectToken(c.credential),rejectToken(c.credential-1)}
  run concurrentRefreshOnlyPostsOnceTest = init.then(beginLogin).then(beginGrant)
    .then(completeGrant(1,0,true)).then(tick).then(tick).then(refresh)
    .expect(c.posts==2 and safety).then(refresh.fail())
  run cancellationCannotReplayRefreshTest = init.then(beginLogin).then(beginGrant)
    .then(cancel).expect(c.status==2 and safety).then(refresh.fail())
  run restartCannotReplayUnknownGrantTest = init.then(beginLogin).then(beginGrant)
    .then(restart).expect(c.status==2 and safety).then(refresh.fail())
  run logoutRejectsLateLoginTest = init.then(beginLogin).then(beginGrant).then(logout)
    .expect(c.status==3 and safety).then(completeGrant(1,0,true).fail())
  run wrongDestinationCannotActivateTest = init.then(beginLogin).then(beginGrant)
    .expect(safety).then(completeGrant(1,1,true).fail())
  run wrongScopeCannotActivateTest = init.then(beginLogin).then(beginGrant)
    .expect(safety).then(completeGrant(1,0,false).fail())
  run expiredTokenCannotSendTest = init.then(beginLogin).then(beginGrant)
    .then(completeGrant(1,0,true)).then(tick).then(tick).expect(safety).then(send.fail())
  run cancelledCodeCannotBeResubmittedTest = init.then(beginLogin).then(beginGrant)
    .then(cancel).then(beginGrant.fail())
  run restartedCodeCannotBeResubmittedTest = init.then(beginLogin).then(beginGrant)
    .then(restart).then(beginGrant.fail())
  run revokedSendCounterexampleTest = init.then(beginLogin).then(beginGrant)
    .then(completeGrant(1,0,true)).then(logout).then(unsafeSend).expect(not(safety))
  run uncertainSendCounterexampleTest = init.then(beginLogin).then(beginGrant)
    .then(unsafeSend).expect(not(safety))
  run rejectedTokenCannotSendTest = init.then(beginLogin).then(beginGrant)
    .then(completeGrant(1,0,true)).then(rejectToken(1)).then(send.fail())
  run staleRejectionPreservesNewCredentialTest = init.then(beginLogin).then(beginGrant)
    .then(completeGrant(1,0,true)).then(beginLogin).then(beginGrant)
    .then(completeGrant(2,0,true)).then(rejectToken(1)).then(send).expect(safety)
  run staleRejectionPreservesRefreshedCredentialTest = init.then(beginLogin).then(beginGrant)
    .then(completeGrant(1,0,true)).then(tick).then(tick).then(refresh)
    .then(completeGrant(1,0,true)).then(rejectToken(1)).then(send)
    .expect(c.activeGeneration==1 and c.credential==2 and safety)
}
