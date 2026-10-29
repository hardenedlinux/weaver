module NativeExitQualification {
  type State={source:int,checks:int,duplicate:bool,complete:bool,returned:bool,opened:Set[int],closed:Set[int],elapsed:int,exited:bool}
  var s:State
  pure val initial:State={source:1,checks:0,duplicate:false,complete:false,returned:false,opened:Set(),closed:Set(),elapsed:0,exited:false}
  action boot:bool=s'=initial
  val audit:bool=s.source==1 and (s.complete implies s.checks==2 and s.duplicate) and (s.returned implies s.complete) and (s.exited implies s.returned and s.opened==s.closed) and s.closed.subseteq(s.opened)
  val qualified:bool=audit and s.exited and s.elapsed<=15
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
  action step:bool=any {check,decoder,finishChecks,acquire(0),acquire(1),close(0),close(1),returnMain,naturalExit,tick}
  run markerAloneIsNotPassTest=checked.expect(audit and not(qualified))
  run nativeReturnAloneIsNotPassTest=checked.then(returnMain).expect(audit and not(qualified))
  run aotStillAllowsNaturalCleanupTest=checked.then(acquire(0)).then(returnMain).then(close(0)).then(naturalExit).expect(qualified)
  run noDynamicSchemeHandlesStillChecksTest=checked.then(returnMain).then(naturalExit).expect(qualified)
  run outstandingHandleBlocksExitTest=checked.then(acquire(0)).then(returnMain).then(naturalExit.fail())
  run missingDecoderCheckRejectedTest=boot.then(check).then(check).then(finishChecks.fail())
  run incompleteChecksRejectedTest=boot.then(check).then(decoder).then(finishChecks.fail())
  run lateNaturalZeroExitStillFailsTest=checked.then(returnMain).then(late).then(naturalExit).expect(audit and not(qualified))
  run repeatedHandleCloseRejectedTest=checked.then(acquire(0)).then(returnMain).then(close(0)).then(close(0).fail())
  action unsafeExit:bool=s'=s.with("exited",true)
  action unsafeWrongSource:bool=s'=s.with("source",2)
  action unsafeSkipDecoder:bool=s'=s.with("complete",true)
  run forcedExitCounterexampleTest=checked.then(acquire(0)).then(returnMain).then(unsafeExit).expect(not(audit))
  run substitutedSourceCounterexampleTest=checked.then(returnMain).then(naturalExit).then(unsafeWrongSource).expect(not(qualified))
  run skippedChecksCounterexampleTest=boot.then(unsafeSkipDecoder).expect(not(audit))
}
