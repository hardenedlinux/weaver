// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

module DispatchCancellation {
  type Event={cancelled:bool,owner:int,revision:int,currentRevision:int}
  type Dispatch={phase:int,locked:bool,burned:bool,token:bool,tokenOwner:int,context:int,stopped:Set[int],revision:int,permitRevision:int,calls:int,held:int,events:List[Event]}
  var s:Dispatch
  val safe=s.calls<=1 and s.held==4 and s.calls==s.events.length() and (s.token implies s.tokenOwner==0) and
    s.events.indices().forall(i=>not(s.events.nth(i).cancelled) and s.events.nth(i).owner==0 and s.events.nth(i).revision==s.events.nth(i).currentRevision)
  action init=s'={phase:0,locked:true,burned:false,token:false,tokenOwner:0,context:0,stopped:Set(),revision:0,permitRevision:0,calls:0,held:4,events:[]}
  action preflight=all {s.phase==0,s.context==0,not(s.stopped.contains(0)),s'=s.with("phase",1)}
  action waitSql=all {s.phase==1,s.locked,s'=s.with("phase",2)}
  action unlock=s'=s.with("locked",false)
  action cancel= s'=s.with("stopped",s.stopped.union(Set(0)))
  action shutdown=s'=s.with("stopped",Set(0,1,2))
  action burn=all {Set(1,2).contains(s.phase),not(s.locked),not(s.burned),s.revision==s.permitRevision,
    s'=s.with("burned",true).with("token",true).with("phase",3)}
  action invoke=all {s.phase==3,s.token,s.revision==s.permitRevision,not(s.stopped.contains(s.tokenOwner)),
    s'=s.with("token",false).with("phase",4).with("calls",s.calls+1)
      .with("events",s.events.append({cancelled:s.stopped.contains(s.tokenOwner),owner:s.tokenOwner,revision:s.permitRevision,currentRevision:s.revision}))}
  action denyCancelled=all {s.phase==3,s.token,s.stopped.contains(s.tokenOwner),s'=s.with("token",false).with("phase",5)}
  action newRpc=all {s.context<2,s'=s.with("context",s.context+1)}
  action publish=s'=s.with("revision",s.revision+1)
  action observe=s'=s
  action unsafeSkipRecheck=all {s.phase==3,s.token,s.revision==s.permitRevision,
    s'=s.with("token",false).with("phase",4).with("calls",s.calls+1)
      .with("events",s.events.append({cancelled:s.stopped.contains(s.tokenOwner),owner:s.tokenOwner,revision:s.permitRevision,currentRevision:s.revision}))}
  action unsafeAdoptNewContext=all {s.token,s.context!=0,s'=s.with("tokenOwner",s.context)}
  action step=any {preflight,waitSql,unlock,cancel,shutdown,burn,invoke,denyCancelled,newRpc,publish,observe}
  action waiting=init.then(preflight).then(waitSql)
  run cancellationWhileLockedCannotInvokeTest=waiting.then(cancel).then(unlock).then(burn).then(invoke.fail())
  run shutdownWhileLockedCannotInvokeTest=waiting.then(shutdown).then(unlock).then(burn).then(invoke.fail())
  run uncancelledWaitInvokesOnceTest=waiting.then(unlock).then(burn).then(invoke).expect(safe and s.calls==1)
  run cancellationAfterAdmissionKeepsHistoryTest=waiting.then(unlock).then(burn).then(invoke).then(cancel).expect(safe and s.calls==1)
  run newRpcCannotTransferCallbackTest=waiting.then(cancel).then(newRpc).then(unlock).then(burn).then(invoke.fail())
  run deniedCallbackCannotReburnTest=waiting.then(cancel).then(unlock).then(burn).then(denyCancelled).then(newRpc).then(burn.fail())
  run publicationDuringWaitRejectsOldViewTest=waiting.then(publish).then(unlock).then(burn.fail())
  run lateObservationRetainsHoldTest=waiting.then(cancel).then(unlock).then(burn).then(denyCancelled).then(observe).expect(safe and s.held==4)
  run skippedRecheckCounterexampleTest=waiting.then(cancel).then(unlock).then(burn).then(unsafeSkipRecheck).expect(not(safe))
  run newContextAdoptionCounterexampleTest=waiting.then(cancel).then(newRpc).then(unlock).then(burn).then(unsafeAdoptNewContext).expect(not(safe))
}
