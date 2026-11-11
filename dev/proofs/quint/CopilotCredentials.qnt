// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

module CopilotCredentials {
  type Send = {api:bool,parent:bool,kind:int,target:int,at:int,expiry:int,refreshAt:int,parentExpiry:int}
  type Credentials = {generation:int,attempt:bool,device:bool,unknown:bool,
    parent:bool,durableParent:bool,parentExpiry:int,lease:bool,durableLease:bool,
    expiry:int,refreshAt:int,busy:bool,cut:int,clock:int,posts:int,gets:int,
    refreshable:bool,refreshUntil:int,refreshPosts:int,sends:List[Send]}
  var c:Credentials
  pure val initial = {generation:0,attempt:false,device:false,unknown:false,
    parent:false,durableParent:false,parentExpiry:-1,lease:false,durableLease:false,
    expiry:0,refreshAt:0,busy:false,cut:-1,clock:0,posts:0,gets:0,
    refreshable:false,refreshUntil:0,refreshPosts:0,sends:[]}
  action init = c'=initial
  val parentReady = c.parent and (c.parentExpiry == -1 or c.clock<c.parentExpiry)
  val apiReady = c.lease and c.clock<c.expiry and c.clock<c.refreshAt
  action beginDevice = all {not(c.busy),
    c'=c.with("generation",c.generation+1).with("attempt",true)}
  action postDevice = all {c.attempt,not(c.busy),
    c'=c.with("attempt",false).with("device",true).with("unknown",true)
      .with("busy",true).with("cut",c.generation).with("posts",c.posts+1)
      .with("parent",false).with("durableParent",false).with("lease",false).with("durableLease",false)}
  action completeDevice(scope:bool,rotating:bool):bool = all {c.busy,c.device,c.cut==c.generation,scope,
    c'=c.with("parent",true).with("durableParent",true).with("unknown",false)
      .with("parentExpiry",if (rotating) c.clock+3 else -1)
      .with("refreshable",rotating).with("refreshUntil",if (rotating) c.clock+8 else 0)
      .with("device",false).with("busy",false)}
  action beginGet = all {not(c.busy),not(c.unknown),parentReady,
    c'=c.with("busy",true).with("cut",c.generation).with("gets",c.gets+1)
      .with("lease",false).with("durableLease",false)}
  action refreshParent = all {not(c.busy),not(c.unknown),c.parent,not(parentReady),
    c.refreshable,c.clock<c.refreshUntil,
    c'=c.with("parent",false).with("durableParent",false).with("lease",false)
      .with("durableLease",false).with("unknown",true).with("device",true)
      .with("busy",true).with("cut",c.generation).with("refreshPosts",c.refreshPosts+1)}
  action completeGet(target:int,hint:int):bool = all {c.busy,not(c.device),c.cut==c.generation,
    parentReady,target==0,hint>0,
    c'=c.with("lease",true).with("durableLease",true).with("busy",false)
      .with("expiry",c.clock+3).with("refreshAt",c.clock+hint)}
  action cancel = c'=c.with("busy",false).with("device",false).with("cut",-1)
  action parentDenied = all {c.busy,not(c.device),
    c'=c.with("parent",false).with("durableParent",false).with("lease",false)
      .with("durableLease",false).with("busy",false).with("unknown",true)}
  action model401 = c'=c.with("lease",false).with("durableLease",false)
  action expireParent = c'=c.with("parentExpiry",c.clock)
  action logout = c'=c.with("generation",c.generation+1).with("attempt",false)
    .with("parent",false).with("durableParent",false).with("lease",false)
    .with("durableLease",false).with("busy",false).with("device",false).with("unknown",true)
  action restart = c'=c.with("parent",c.durableParent).with("lease",c.durableLease)
    .with("busy",false).with("device",false).with("attempt",false).with("cut",-1)
  action tick = c'=c.with("clock",c.clock+1)
  val receipt = {api:apiReady,parent:parentReady,kind:1,target:0,at:c.clock,
    expiry:c.expiry,refreshAt:c.refreshAt,parentExpiry:c.parentExpiry}
  action send = all {apiReady,parentReady,c'=c.with("sends",c.sends.append(receipt))}
  action unsafeSendParent = c'=c.with("sends",c.sends.append(receipt.with("kind",0)))
  action unsafeSend = c'=c.with("sends",c.sends.append(receipt))
  val safety = (c.lease implies c.parent) and c.sends.indices().forall(i => {
    val s=c.sends.nth(i)
    s.api and s.parent and s.kind==1 and s.target==0 and s.at<s.expiry and s.at<s.refreshAt
      and (s.parentExpiry == -1 or s.at<s.parentExpiry)
  })
  action step = any {beginDevice,postDevice,completeDevice(true,false),completeDevice(true,true),completeDevice(false,false),
    beginGet,completeGet(0,2),completeGet(1,2),completeGet(0,0),cancel,parentDenied,
    model401,expireParent,logout,restart,tick,send,refreshParent}
  action login = init.then(beginDevice).then(postDevice).then(completeDevice(true,false))
  action ready = login.then(beginGet).then(completeGet(0,2))
  action readyRotating = init.then(beginDevice).then(postDevice).then(completeDevice(true,true))
    .then(beginGet).then(completeGet(0,2))
  run parentAloneCannotInvokeModelTest = login.then(send.fail())
  run deviceWrongScopeCannotCreateParentTest = init.then(beginDevice).then(postDevice)
    .then(completeDevice(false,false).fail())
  run cancelledDeviceCannotReplayTest = init.then(beginDevice).then(postDevice).then(cancel)
    .then(restart).then(postDevice.fail())
  run restartAfterParentCommitSkipsDeviceGrantTest = login.then(restart).then(beginGet)
    .then(completeGet(0,2)).then(send).expect(c.posts==1 and c.gets==1 and safety)
  run cancelledGetRetainsParentForExplicitRetryTest = login.then(beginGet).then(cancel)
    .then(restart).then(beginGet).then(completeGet(0,2)).then(send)
    .expect(c.posts==1 and c.gets==2 and safety)
  run sharedRefreshOnlyStartsOneGetTest = ready.then(tick).then(tick).then(beginGet)
    .then(beginGet.fail())
  run wrongApiDestinationCannotActivateTest = login.then(beginGet).then(completeGet(1,2).fail())
  run zeroRefreshHintCannotActivateTest = login.then(beginGet).then(completeGet(0,0).fail())
  run refreshHintPrecedesAbsoluteExpiryTest = ready.then(tick).then(tick).then(send.fail())
  run parentExpiryBlocksFreshApiLeaseTest = ready.then(expireParent).then(send.fail())
  run deniedParentCannotRetryGetTest = ready.then(beginGet).then(parentDenied).then(restart)
    .then(beginGet.fail())
  run model401RetainsParentWithoutReplayingModelTest = ready.then(model401).then(send.fail())
  run model401AllowsExplicitNewLeaseTest = ready.then(model401).then(beginGet)
    .then(completeGet(0,2)).then(send).expect(c.posts==1 and c.gets==2 and safety)
  run logoutRejectsLateGetAndRestartTest = ready.then(beginGet).then(logout).then(restart)
    .then(completeGet(0,2).fail())
  run warmedCallsDoNotAcquireCredentialsTest = ready.then(send).then(send)
    .expect(c.posts==1 and c.gets==1 and safety)
  run parentCredentialLeakCounterexampleTest = ready.then(unsafeSendParent).expect(not(safety))
  run expiredApiSendCounterexampleTest = ready.then(tick).then(tick)
    .then(unsafeSend).expect(not(safety))
  run expiredParentSendCounterexampleTest = ready.then(expireParent)
    .then(unsafeSend).expect(not(safety))
  run parentRefreshIsSingleFlightTest = readyRotating.then(expireParent)
    .then(refreshParent).then(refreshParent.fail())
  run parentRefreshResumesBothStagesTest = readyRotating.then(expireParent)
    .then(refreshParent).then(completeDevice(true,true)).then(beginGet).then(completeGet(0,2))
    .then(send).expect(c.posts==1 and c.refreshPosts==1 and c.gets==2 and safety)
  run cancelledParentRefreshCannotReplayTest = readyRotating.then(expireParent)
    .then(refreshParent).then(cancel).then(restart).then(refreshParent.fail())
  run expiredRefreshCredentialCannotPostTest = readyRotating.then(expireParent)
    .then(tick).then(tick).then(tick).then(tick).then(tick).then(tick).then(tick).then(tick)
    .then(refreshParent.fail())
}
