// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

module DynamicImportBoundary {
  type State={active:Set[int],needed:Set[int],bindings:List[int],bodyDigest:int,abi:int,published:bool,loaded:Set[int],closed:Set[int],checks:int,decoder:bool,returned:bool,exited:bool,elapsed:int}
  var s:State
  pure val initial:State={active:Set(0,1,2,3,4),needed:Set(0,1,2),bindings:List(0,1,2),bodyDigest:7,abi:4,published:false,loaded:Set(),closed:Set(),checks:0,decoder:false,returned:false,exited:false,elapsed:0}
  action boot:bool=s'=initial
  val contract:bool=s.needed.subseteq(s.active) and s.bindings==List(0,1,2) and s.bodyDigest==7 and s.abi==4
  val safe:bool=(s.published implies contract) and (s.exited implies s.returned and s.loaded==s.closed and s.checks==2 and s.decoder)
  val qualified:bool=safe and s.published and s.exited and s.elapsed<=15
  action prune(m:int):bool=all {not(s.published),not(s.needed.contains(m)),s'=s.with("active",s.active.exclude(Set(m)))}
  action publish:bool=all {contract,s'=s.with("published",true)}
  action load(m:int):bool=all {s.published,s.active.contains(m),not(s.returned),s'=s.with("loaded",s.loaded.union(Set(m)))}
  action check:bool=all {s.published,not(s.returned),s'=s.with("checks",s.checks+1)}
  action decoder:bool=all {not(s.returned),s'=s.with("decoder",true)}
  action returnMain:bool=all {s.checks==2,s.decoder,s'=s.with("returned",true)}
  action close(m:int):bool=all {s.loaded.contains(m),not(s.closed.contains(m)),s'=s.with("closed",s.closed.union(Set(m)))}
  action naturalExit:bool=all {s.returned,s.loaded==s.closed,s'=s.with("exited",true)}
  action late:bool=s'=s.with("elapsed",16)
  action step:bool=any {prune(3),prune(4),publish,load(0),load(1),load(2),check,decoder,returnMain,close(0),close(1),close(2),naturalExit,late}
  action narrowed:bool=boot.then(prune(3)).then(prune(4)).then(publish)
  action ready:bool=narrowed.then(load(0)).then(load(1)).then(check).then(check).then(decoder).then(returnMain)
  run narrowedDynamicCleanupTest=ready.then(close(0)).then(close(1)).then(naturalExit).expect(qualified)
  run allRequiredBodiesRemainTest=narrowed.expect(s.active==s.needed)
  run duplicateImportIdempotentTest=narrowed.then(load(1)).then(load(1)).expect(s.loaded==Set(1))
  run requiredInitializerCannotBePrunedTest=boot.then(prune(1).fail())
  run publicationFreezesClosureTest=narrowed.then(prune(3).fail())
  run outstandingHandleRejectsExitTest=ready.then(naturalExit.fail())
  run lateNaturalExitRejectedTest=ready.then(close(0)).then(close(1)).then(late).then(naturalExit).expect(safe and not(qualified))
  run missingDecoderRejectsReturnTest=narrowed.then(check).then(check).then(returnMain.fail())
  action missingBody:bool=s'=s.with("active",s.active.exclude(Set(1)))
  action changedBinding:bool=s'=s.with("bindings",List(2,1,0))
  action changedInterface:bool=s'=s.with("abi",5)
  action changedBody:bool=s'=s.with("bodyDigest",8)
  action unsafePublish:bool=s'=s.with("published",true)
  run missingRequiredBodyRejectedTest=boot.then(missingBody).then(publish.fail())
  run bindingSubstitutionRejectedTest=boot.then(changedBinding).then(publish.fail())
  run interfaceSubstitutionRejectedTest=boot.then(changedInterface).then(publish.fail())
  run omittedInitializerCounterexampleTest=boot.then(missingBody).then(unsafePublish).expect(not(safe))
  run substitutedBindingCounterexampleTest=boot.then(changedBinding).then(unsafePublish).expect(not(safe))
  run interfaceDriftCounterexampleTest=boot.then(changedInterface).then(unsafePublish).expect(not(safe))
  run executableMutationCounterexampleTest=boot.then(changedBody).then(unsafePublish).expect(not(safe))
}
