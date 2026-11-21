// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

// Two abstract text parts. Base-10 transcript fingerprints make the same
// aggregate 12 insufficient when tokens 1 and 2 are assigned to wrong parts.
// Rust checks actual item ids, index bounds, SHA-256 and fragmented bytes.
module StreamCoordinates {
  type S={started:bool,parts:int,received:int,swap:bool,foreign:bool,
    failed:bool,complete:bool,aggregate:int,first:int,second:int,tools:int}
  var s:S
  val live=not(s.failed) and not(s.complete)
  val bound=s.aggregate==12 and s.first==1 and s.second==2 and not(s.foreign)
  val safe=s.tools==0 or (s.complete and bound and not(s.failed))
  action init=s'={started:false,parts:0,received:0,swap:false,foreign:false,
    failed:false,complete:false,aggregate:0,first:0,second:0,tools:0}
  action start=all {live,not(s.started),s'=s.with("started",true)}
  action registerPart=all {live,s.started,s.parts<2,s'=s.with("parts",s.parts+1)}
  action swapAssignments=all {live,s.received==0,s'=s.with("swap",true)}
  action foreignIdentity=all {live,s'=s.with("foreign",true)}
  action delta=all {live,s.started,s.parts==2,s.received<2,
    if (s.foreign) s'=s.with("failed",true)
    else {
      val token=s.received+1
      val target=if (s.swap) 1-s.received else s.received
      s'=s.with("aggregate",s.aggregate*10+token).with("received",s.received+1)
        .with("first",if (target==0) s.first*10+token else s.first)
        .with("second",if (target==1) s.second*10+token else s.second)
    }}
  action finish=all {live,
    if (s.started and s.parts==2 and s.received==2 and bound)
      s'=s.with("complete",true).with("tools",1)
    else s'=s.with("failed",true)}
  action abort=s'=s.with("failed",true)
  action observe=s'=s
  action step=any {start,registerPart,swapAssignments,foreignIdentity,delta,finish,observe}
  action prepared=init.then(start).then(registerPart).then(registerPart)
  action unsafeAggregateFinish=all {live,s.aggregate==12,
    s'=s.with("complete",true).with("tools",1)}
  action aggregateOnlyStep=any {start,registerPart,swapAssignments,foreignIdentity,delta,unsafeAggregateFinish,observe}
  run exactCoordinatesCompleteTest=prepared.then(delta).then(delta).then(finish).expect(safe and s.tools==1)
  run metadataAloneCannotExecuteToolsTest=prepared.expect(safe and s.tools==0)
  run aggregateDoesNotBindPartsTest=prepared.then(swapAssignments).then(delta).then(delta)
    .expect(s.aggregate==12 and not(bound)).then(finish).expect(s.failed and s.tools==0 and safe)
  run foreignIdentityClosesTest=prepared.then(foreignIdentity).then(delta).expect(s.failed and safe).then(delta.fail())
  run missingPartRefusesCompletionTest=init.then(start).then(registerPart).then(finish).expect(s.failed and s.tools==0 and safe)
  run truncatedTurnCannotCompleteTest=prepared.then(delta).then(abort).then(finish.fail())
  run duplicateTerminalRefusesTest=prepared.then(delta).then(delta).then(finish).then(finish.fail())
  run droppedPartBindingCounterexampleTest=prepared.then(swapAssignments).then(delta).then(delta)
    .then(unsafeAggregateFinish).expect(not(safe))
}
