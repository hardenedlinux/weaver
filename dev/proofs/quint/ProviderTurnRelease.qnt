// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

// Terminal handoff only. Nonterminal coordinates convey no terminal/tool
// authority (StreamCoordinates). Receipt history is the independent oracle;
// changing later state cannot retroactively invalidate an earlier safe release.
module ProviderTurnRelease {
  type Payload={tools:int,continuation:int,usage:int,coordinate:int}
  type Cut={complete:bool,failed:bool,cancelled:bool,version:int,bytes:int,revision:int}
  type Receipt={actual:Payload,sealed:Payload,cut:Cut,preparedRevision:int}
  type S={version:int,bytes:int,complete:bool,failed:bool,cancelled:bool,
    tools:int,continuation:int,usage:int,coordinate:int,prepared:bool,
    revision:int,preparedRevision:int,sealed:Payload,history:List[Receipt]}
  var s:S
  val actual={tools:s.tools,continuation:s.continuation,usage:s.usage,coordinate:s.coordinate}
  val cut={complete:s.complete,failed:s.failed,cancelled:s.cancelled,
    version:s.version,bytes:s.bytes,revision:s.revision}
  val safe=s.history.length()<=1 and s.history.indices().forall(i=>{
    val r=s.history.nth(i)
    r.cut.complete and not(r.cut.failed) and not(r.cut.cancelled) and
      r.cut.version==1 and r.cut.bytes<=3 and r.preparedRevision==r.cut.revision and r.actual==r.sealed
  })
  action init=s'={version:1,bytes:0,complete:false,failed:false,cancelled:false,
    tools:0,continuation:0,usage: -1,coordinate:0,prepared:false,revision:0,
    preparedRevision:0,sealed:{tools:0,continuation:0,usage: -1,coordinate:0},history:List()}
  action partial=all {not(s.complete),not(s.failed),s.bytes<3,
    s'=s.with("bytes",s.bytes+1).with("tools",1)}
  action terminal=all {not(s.complete),not(s.failed),s.bytes<3,
    s'=s.with("bytes",s.bytes+1).with("complete",true).with("continuation",1)}
  action abortTurn=s'=s.with("failed",true).with("tools",0)
  action cancel=s'=s.with("cancelled",true)
  action revoke=s'=s.with("revision",s.revision+1)
  action prepare=all {s.complete,not(s.failed),s.version==1,s.bytes<=3,
    s'=s.with("prepared",true).with("sealed",actual).with("preparedRevision",s.revision)}
  val admitted=s.prepared and s.complete and not(s.failed) and not(s.cancelled) and
    s.version==1 and s.bytes<=3 and s.revision==s.preparedRevision and actual==s.sealed
  action record=s'=s.with("history",s.history.append({actual:actual,sealed:s.sealed,cut:cut,preparedRevision:s.preparedRevision}))
  action release=all {admitted,s.history.length()==0,record}
  action changeContinuation=s'=s.with("continuation",s.continuation+1)
  // Missing usage stays unknown; actual arithmetic and bytes are runtime tests.
  action observeUsage=all {not(s.complete),not(s.failed),s'=s.with("usage",1)}
  action changeUsage=s'=s.with("usage",s.usage+1)
  action changeCoordinate=s'=s.with("coordinate",s.coordinate+1)
  action wrongVersion=s'=s.with("version",2)
  action oversized=s'=s.with("bytes",4)
  action unsafeDropPayloadBinding=all {s.prepared,s.history.length()==0,record}
  action observe=s'=s
  action changes=any {partial,terminal,abortTurn,cancel,revoke,prepare,
    changeContinuation,observeUsage,changeUsage,changeCoordinate,wrongVersion,oversized,observe}
  action step=any {changes,release}
  action payloadUnboundStep=any {changes,unsafeDropPayloadBinding}
  action ready=init.then(partial).then(terminal).then(prepare)
  run partialToolsCannotReleaseTest=init.then(partial).then(prepare.fail())
  run completePayloadReleasesOnceTest=ready.then(release).expect(safe).then(release.fail())
  run truncatedTurnCannotPrepareTest=init.then(partial).then(abortTurn).then(prepare.fail())
  run cancelledHandoffCannotReleaseTest=ready.then(cancel).then(release.fail())
  run revokedHandoffCannotReleaseTest=ready.then(revoke).then(release.fail())
  run changedContinuationCannotReleaseTest=ready.then(changeContinuation).then(release.fail())
  run changedUsageCannotReleaseTest=ready.then(changeUsage).then(release.fail())
  run changedCoordinateCannotReleaseTest=ready.then(changeCoordinate).then(release.fail())
  run prematureUsageCannotPrepareTest=init.then(observeUsage).then(prepare.fail())
  run missingUsageRemainsUnknownTest=ready.then(release).expect(safe and s.usage == -1)
  run wrongVersionCannotPrepareTest=init.then(terminal).then(wrongVersion).then(prepare.fail())
  run oversizedCannotPrepareTest=init.then(terminal).then(oversized).then(prepare.fail())
  run droppedBindingCounterexampleTest=ready.then(changeContinuation).then(unsafeDropPayloadBinding).expect(not(safe))
  run coordinateBindingCounterexampleTest=ready.then(changeCoordinate).then(unsafeDropPayloadBinding).expect(not(safe))
  run historicalReceiptSurvivesLaterWithdrawalTest=ready.then(release).then(revoke).then(cancel).expect(safe)
}
