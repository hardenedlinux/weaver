module DynamicImageCustody {
  type State={opened:Set[int],closed:Set[int],unloaded:Set[int],initialized:List[int],stopping:bool,pure:bool,distinctEntries:bool,admitted:bool}
  var s:State
  pure def owner(ref:int):int=if (ref<2) 0 else 1
  pure val initial:State={opened:Set(),closed:Set(),unloaded:Set(),initialized:List(),stopping:false,pure:true,distinctEntries:true,admitted:false}
  action boot:bool=s'=initial
  val custody:bool=s.unloaded.forall(image=>s.opened.forall(ref=>owner(ref)==image implies s.closed.contains(ref)))
  val safe:bool=custody and (s.admitted implies s.pure and s.distinctEntries)
  action admit:bool=all {s.pure,s.distinctEntries,s'=s.with("admitted",true)}
  action acquire(ref:int):bool=all {s.admitted,not(s.stopping),not(s.opened.contains(ref)),not(s.unloaded.contains(owner(ref))),s'=s.with("opened",s.opened.union(Set(ref)))}
  action initialize(ref:int):bool=all {s.opened.contains(ref),not(s.initialized.contains(ref)),s'=s.with("initialized",s.initialized.append(ref))}
  action stop:bool=s'=s.with("stopping",true)
  action close(ref:int):bool=all {s.opened.contains(ref),not(s.closed.contains(ref)),s'=s.with("closed",s.closed.union(Set(ref)))}
  action unload(image:int):bool=all {s.stopping,s.opened.forall(ref=>owner(ref)==image implies s.closed.contains(ref)),s'=s.with("unloaded",s.unloaded.union(Set(image)))}
  action step:bool=any {admit,acquire(0),acquire(1),acquire(2),initialize(0),initialize(1),initialize(2),stop,close(0),close(1),close(2),unload(0),unload(1)}
  action aliases:bool=boot.then(admit).then(acquire(0)).then(acquire(1))
  run twoLogicalRefsOneImageTest=aliases.expect(s.opened==Set(0,1) and owner(0)==owner(1))
  run oneCloseCannotUnmapTest=aliases.then(stop).then(close(0)).then(unload(0).fail())
  run finalCloseAllowsUnmapTest=aliases.then(stop).then(close(0)).then(close(1)).then(unload(0)).expect(safe)
  run duplicateAcquisitionRejectedTest=aliases.then(acquire(0).fail())
  run duplicateCloseRejectedTest=aliases.then(stop).then(close(0)).then(close(0).fail())
  run shutdownRejectsAcquisitionTest=aliases.then(stop).then(acquire(2).fail())
  run mappingDoesNotInitializeTest=aliases.expect(s.initialized==List())
  run requestedEntriesStayLazyTest=aliases.then(initialize(1)).expect(s.initialized==List(1))
  action foreignCtor:bool=s'=s.with("pure",false)
  action collapsedEntry:bool=s'=s.with("distinctEntries",false)
  action unsafeAdmit:bool=s'=s.with("admitted",true)
  action unsafeUnload:bool=s'=s.with("unloaded",s.unloaded.union(Set(0)))
  action unsafeForgetRef:bool=s'=s.with("opened",Set())
  run foreignInitializerRejectedTest=boot.then(foreignCtor).then(admit.fail())
  run duplicateEntryRejectedTest=boot.then(collapsedEntry).then(admit.fail())
  run independentImageCanReleaseTest=aliases.then(acquire(2)).then(stop).then(close(2)).then(unload(1)).expect(safe and not(s.unloaded.contains(0)))
  run earlyUnmapCounterexampleTest=aliases.then(stop).then(close(0)).then(unsafeUnload).expect(not(custody))
  run forgottenReferenceCounterexampleTest=aliases.then(stop).then(unsafeForgetRef).then(unload(0)).expect(safe and s.closed!=Set(0,1))
  run eagerForeignCtorCounterexampleTest=boot.then(foreignCtor).then(unsafeAdmit).expect(not(safe))
  run collapsedEntryCounterexampleTest=boot.then(collapsedEntry).then(unsafeAdmit).expect(not(safe))
}
