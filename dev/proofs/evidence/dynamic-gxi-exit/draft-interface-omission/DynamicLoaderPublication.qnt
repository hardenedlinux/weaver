module DynamicLoaderPublication {
  type State={compiled:List[int],source:List[int],bodyDigest:int,originalDigest:int,recognized:bool,published:bool,loaded:Set[int],open:Set[int],closed:Set[int],checks:int,decoder:bool,returned:bool,exited:bool,elapsed:int}
  var s:State
  pure val initial:State={compiled:List(0,1,2),source:List(0,1,2),bodyDigest:7,originalDigest:7,recognized:true,published:false,loaded:Set(),open:Set(),closed:Set(),checks:0,decoder:false,returned:false,exited:false,elapsed:0}
  action boot:bool=s'=initial
  val faithful:bool=s.recognized and s.source==s.compiled and s.bodyDigest==s.originalDigest
  val safe:bool=(s.published implies faithful) and (s.exited implies s.returned and s.checks==2 and s.decoder and s.open==s.closed)
  val qualified:bool=safe and s.published and s.exited and s.elapsed<=15
  action publish:bool=all {faithful,s'=s.with("published",true)}
  action load(m:int):bool=all {s.published,not(s.returned),s'=s.with("loaded",s.loaded.union(Set(m))).with("open",s.open.union(Set(m)))}
  action check:bool=all {s.published,not(s.returned),s'=s.with("checks",s.checks+1)}
  action decoder:bool=all {not(s.returned),s'=s.with("decoder",true)}
  action returnMain:bool=all {s.checks==2,s.decoder,s'=s.with("returned",true)}
  action close(m:int):bool=all {s.open.contains(m),not(s.closed.contains(m)),s'=s.with("closed",s.closed.union(Set(m)))}
  action naturalExit:bool=all {s.returned,s.open==s.closed,s'=s.with("exited",true)}
  action late:bool=s'=s.with("elapsed",16)
  action step:bool=any {publish,load(0),load(1),load(2),check,decoder,returnMain,close(0),close(1),close(2),naturalExit,late}
  action ready:bool=boot.then(publish).then(load(0)).then(load(1)).then(check).then(check).then(decoder).then(returnMain)
  run ordinaryDynamicCleanupTest=ready.then(close(0)).then(close(1)).then(naturalExit).expect(qualified)
  run bodyRemainsDynamicTest=boot.then(publish).then(load(1)).expect(s.loaded==Set(1) and s.open==Set(1))
  run duplicateImportIsIdempotentTest=boot.then(publish).then(load(1)).then(load(1)).expect(s.loaded==Set(1) and s.open==Set(1))
  run liveHandleRejectsExitTest=ready.then(naturalExit.fail())
  run missingDecoderRejectsReturnTest=boot.then(publish).then(check).then(check).then(returnMain.fail())
  run lateNaturalExitRejectedTest=ready.then(close(0)).then(close(1)).then(late).then(naturalExit).expect(safe and not(qualified))
  action reorder:bool=s'=s.with("source",List(2,1,0))
  action mutateBody:bool=s'=s.with("bodyDigest",8)
  action arbitraryStub:bool=s'=s.with("recognized",false)
  action unsafePublish:bool=s'=s.with("published",true)
  run reorderedCallsRejectedTest=boot.then(reorder).then(publish.fail())
  run substitutedBodyRejectedTest=boot.then(mutateBody).then(publish.fail())
  run arbitraryCodeRejectedTest=boot.then(arbitraryStub).then(publish.fail())
  run reorderedPublicationCounterexampleTest=boot.then(reorder).then(unsafePublish).expect(not(safe))
  run bodySubstitutionCounterexampleTest=boot.then(mutateBody).then(unsafePublish).expect(not(safe))
  run arbitraryStubCounterexampleTest=boot.then(arbitraryStub).then(unsafePublish).expect(not(safe))
}
