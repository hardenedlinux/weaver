// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

module GerbilExitQualification {
  // Entry 0 is gerbil test; entry 1 is a diagnostic invocation. Even the same
  // cases and cleanup through another entry do not qualify the package tool.
  // Open references cover FFI-loaded libraries. No executable build target is
  // required: the public package test exercises the library consumer directly.
  // source denotes the complete project input closure. Go SourceInputs and its
  // plan-derived tests refine that identity; filename labels alone do not.
  // Before/after inventory equality is conditional on stable filesystem input,
  // hash integrity and separately qualified dependency/toolchain caches.
  type Trial={id:int,study:int,artifact:int,firstUse:bool,profiled:bool,natural:bool,complete:bool,clean:bool,elapsed:int}
  pure def trialPass(t:Trial):bool=not(t.profiled) and t.natural and t.complete and t.clean and t.elapsed>=0 and t.elapsed<=15
  type State={entry:int,source:int,checks:int,duplicate:bool,complete:bool,returned:bool,opened:Set[int],closed:Set[int],elapsed:int,exited:bool,trials:List[Trial],failed:Set[int]}
  var s:State
  pure val initial:State={entry:0,source:1,checks:0,duplicate:false,complete:false,returned:false,opened:Set(),closed:Set(),elapsed:0,exited:false,trials:List(),failed:Set()}
  action boot:bool=s'=initial
  val historyAudit:bool=s.trials.indices().forall(i=>s.trials.indices().forall(j=>i==j or s.trials.nth(i).id!=s.trials.nth(j).id)) and s.failed.forall(id=>s.trials.indices().exists(i=>s.trials.nth(i).id==id and not(trialPass(s.trials.nth(i)))))
  val audit:bool=historyAudit and s.source==1 and (s.complete implies s.checks==2 and s.duplicate) and (s.returned implies s.complete) and (s.exited implies s.returned and s.opened==s.closed) and s.closed.subseteq(s.opened)
  val qualified:bool=audit and s.entry==0 and s.exited and s.elapsed<=15
  action check:bool=all {not(s.complete),not(s.returned),s'=s.with("checks",s.checks+1)}
  action decoder:bool=all {not(s.returned),s'=s.with("duplicate",true)}
  action finishChecks:bool=all {s.checks==2,s.duplicate,not(s.returned),s'=s.with("complete",true)}
  action acquire(h:int):bool=all {not(s.returned),not(s.opened.contains(h)),s'=s.with("opened",s.opened.union(Set(h)))}
  action close(h:int):bool=all {not(s.exited),s.opened.contains(h),not(s.closed.contains(h)),s'=s.with("closed",s.closed.union(Set(h)))}
  action returnMain:bool=all {s.complete,s'=s.with("returned",true)}
  action naturalExit:bool=all {s.returned,s.opened==s.closed,s'=s.with("exited",true)}
  action tick:bool=all {not(s.exited),s'=s.with("elapsed",s.elapsed+1)}
  action late:bool=all {not(s.exited),s'=s.with("elapsed",16)}
  action checked:bool=boot.then(check).then(check).then(decoder).then(finishChecks)
  pure val failedTrial:Trial={id:0,study:0,artifact:10,firstUse:true,profiled:false,natural:false,complete:true,clean:false,elapsed:16}
  pure val passedTrial:Trial={id:1,study:0,artifact:11,firstUse:true,profiled:false,natural:true,complete:true,clean:true,elapsed:10}
  pure def matched(a:Trial,b:Trial):bool=a.study==b.study and a.study==0 and a.firstUse and b.firstUse and a.artifact!=b.artifact and not(a.profiled) and not(b.profiled)
  action recordTrial(t:Trial):bool=all {s.trials.indices().forall(i=>s.trials.nth(i).id!=t.id),s'=s.with("trials",s.trials.append(t)).with("failed",if (not(trialPass(t))) s.failed.union(Set(t.id)) else s.failed)}
  action step:bool=any {check,decoder,finishChecks,acquire(0),acquire(1),close(0),close(1),returnMain,naturalExit,tick,recordTrial(failedTrial),recordTrial(passedTrial)}
  run markerAloneIsNotPassTest=checked.expect(audit and not(qualified))
  run packageReturnAloneIsNotPassTest=checked.then(returnMain).expect(audit and not(qualified))
  run aotStillAllowsNaturalCleanupTest=checked.then(acquire(0)).then(returnMain).then(close(0)).then(naturalExit).expect(qualified)
  run noDynamicSchemeHandlesStillChecksTest=checked.then(returnMain).then(naturalExit).expect(qualified)
  run outstandingHandleBlocksExitTest=checked.then(acquire(0)).then(returnMain).then(naturalExit.fail())
  run ffiLibraryReferencesMustCloseTest=checked.then(acquire(0)).then(acquire(1)).then(returnMain).then(close(0)).then(naturalExit.fail())
  run missingDecoderCheckRejectedTest=boot.then(check).then(check).then(finishChecks.fail())
  run incompleteChecksRejectedTest=boot.then(check).then(decoder).then(finishChecks.fail())
  run lateNaturalZeroExitStillFailsTest=checked.then(returnMain).then(late).then(naturalExit).expect(audit and not(qualified))
  action diagnosticEntry:bool=s'=s.with("entry",1)
  run diagnosticEntryCannotQualifyPackageTest=checked.then(returnMain).then(naturalExit).then(diagnosticEntry).expect(audit and not(qualified))
  run repeatedHandleCloseRejectedTest=checked.then(acquire(0)).then(returnMain).then(close(0)).then(close(0).fail())
  action unsafeExit:bool=s'=s.with("exited",true)
  action unsafeWrongSource:bool=s'=s.with("source",2)
  action unsafeSkipDecoder:bool=s'=s.with("complete",true)
  run forcedExitCounterexampleTest=checked.then(acquire(0)).then(returnMain).then(unsafeExit).expect(not(audit))
  run substitutedSourceCounterexampleTest=checked.then(returnMain).then(naturalExit).then(unsafeWrongSource).expect(not(qualified))
  run skippedChecksCounterexampleTest=boot.then(unsafeSkipDecoder).expect(not(audit))
  action profiledPublicEntry:bool=s'=s.with("entry",2)
  run instrumentedSdkIsDiagnosticTest=checked.then(returnMain).then(naturalExit).then(profiledPublicEntry).expect(audit and not(qualified))
  run replayCannotEraseFailedTrialTest=boot.then(recordTrial(failedTrial)).then(recordTrial(passedTrial)).expect(audit and s.failed.contains(0))
  run sameSlotReplayRejectedTest=boot.then(recordTrial(failedTrial)).then(recordTrial(passedTrial.with("id",0)).fail())
  action unsafeReplaceFailure:bool=s'=s.with("trials",List(passedTrial.with("id",0)))
  run replacingFailureCounterexampleTest=boot.then(recordTrial(failedTrial)).then(unsafeReplaceFailure).expect(not(historyAudit))
  run warmReplayIsNotColdPairTest=boot.expect(not(matched(failedTrial,passedTrial.with("firstUse",false))))
  run changedSourceIsNotMatchedPairTest=boot.expect(not(matched(failedTrial,passedTrial.with("study",1))))
  run reusedArtifactIsNotIndependentColdPairTest=boot.expect(not(matched(failedTrial,passedTrial.with("artifact",10))))
  run profiledTrialCannotQualifyTest=boot.expect(not(trialPass(passedTrial.with("profiled",true))))
  run negativeElapsedCannotQualifyTest=boot.expect(not(trialPass(passedTrial.with("elapsed",-1))))
  // A small cleanup interval does not bound the sum of startup, discovery,
  // imports, execution and cleanup. Native clocks/mechanisms are Host premises.
  run shortCleanupStillMissesDeadlineTest=boot.expect(2+0+11+2+1>15 and 1<15)
}
