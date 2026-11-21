// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

// Three canonical positions: text, private tool, text. The source codec owns
// final-content authenticity. Projection only controls prefix/tail publication.
module StreamProjection {
  type Emission={index:int,complete:bool}
  type S={observed:int,barrier:bool,complete:bool,cancelled:bool,failed:bool,closed:bool,out:List[Emission]}
  var s:S
  val safe=s.out.indices().forall(i=>s.out.nth(i).index==i and
    (s.out.nth(i).index!=1 or s.out.nth(i).complete))
  action init=s'={observed:0,barrier:false,complete:false,cancelled:false,failed:false,closed:false,out:List()}
  val live=not(s.closed) and not(s.cancelled) and not(s.failed)
  action observeFirst=all {live,s.observed==0,s'=s.with("observed",1).with("out",s.out.append({index:0,complete:false}))}
  action observeTool=all {live,s.observed==1,s'=s.with("observed",2).with("barrier",true)}
  action observeTail=all {live,s.observed==2,s'=s.with("observed",3)}
  action terminal=all {live,s.observed==3,not(s.complete),s'=s.with("complete",true)}
  // Reuse canonical final positions from the first withheld item. There is no
  // second accumulation of tail fragments, and no replay of an emitted prefix.
  action drain=all {live,s.complete,s.out.length()<3,
    s'=s.with("out",s.out.append({index:s.out.length(),complete:true}))}
  action finish=all {live,s.complete,s.out.length()==3,s'=s.with("closed",true)}
  action cancel=s'=s.with("cancelled",true)
  action truncate=s'=s.with("failed",true)
  action observe=s'=s
  action step=any {observeFirst,observeTool,observeTail,terminal,drain,finish,cancel,truncate,observe}
  action forwardEveryText=all {live,s.observed==2,
    s'=s.with("observed",3).with("out",s.out.append({index:2,complete:false}))}
  action replayFromZero=all {live,s.complete,s'=s.with("out",s.out.append({index:0,complete:true}))}
  action immediateStep=any {observeFirst,observeTool,forwardEveryText,terminal,drain,finish,observe}
  action replayStep=any {observeFirst,observeTool,observeTail,terminal,replayFromZero,observe}
  action blocked=init.then(observeFirst).then(observeTool).then(observeTail)
  run prefixStreamsWithoutWaitingTest=init.then(observeFirst).expect(s.out.length()==1 and not(s.complete) and safe)
  run withheldToolBlocksLaterTextTest=blocked.expect(s.out.length()==1 and safe).then(drain.fail())
  run finalTailDoesNotRepeatPrefixTest=blocked.then(terminal).then(drain).then(drain).then(finish)
    .expect(safe and s.out.length()==3)
  run duplicateTerminalCannotReplayTest=blocked.then(terminal).then(drain).then(drain).then(finish).then(terminal.fail())
  run closedTailCannotReplayTest=blocked.then(terminal).then(drain).then(drain).then(finish).then(drain.fail())
  run cancellationBeforeTailCannotReleaseToolsTest=blocked.then(terminal).then(cancel).expect(safe).then(drain.fail())
  run truncationCannotCompleteTest=blocked.then(truncate).expect(safe).then(terminal.fail())
  run immediateTextCounterexampleTest=init.then(observeFirst).then(observeTool).then(forwardEveryText).expect(not(safe))
  run fullReplayCounterexampleTest=blocked.then(terminal).then(replayFromZero).expect(not(safe))
}
