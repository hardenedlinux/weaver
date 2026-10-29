module ReleaseBinding {
  // Three already consumed original plans share a held budget. Their response
  // batches intentionally have identical payload digests and sequence intervals.
  // The separate plan commitment, encoding and owner session bind each token.
  type Token = {owner:int,encoding:int,session:int}
  type Emission = {owner:int,operation:int,preparedEncoding:int,requestedEncoding:int,tokenSession:int,currentSession:int,current:bool}
  type State = {session:int,current:bool,held:int,reserved:Set[int],pending:Set[int],used:Set[int],tokens:List[Token],emissions:List[Emission]}
  var s:State
  val operations=Set(0,1,2)
  val safe=s.held==12 and s.emissions.length()<=s.used.size() and
    s.tokens.indices().forall(i=>s.tokens.nth(i).session==0) and
    s.emissions.indices().forall(i=>{
      val e=s.emissions.nth(i)
      e.owner==e.operation and e.preparedEncoding==e.requestedEncoding and
        e.tokenSession==e.currentSession and e.current
    })
  action init=s'={session:0,current:true,held:12,reserved:Set(),pending:Set(),used:Set(),tokens:[],emissions:[]}
  action prepare(operation:int,encoding:int):bool=all {
    operations.contains(operation),Set(0,1).contains(encoding),not(s.reserved.contains(operation)),s.current,
    // All original dispatch handles were consumed in owner session zero.
    s.session==0,
    s'=s.with("reserved",s.reserved.union(Set(operation))).with("pending",s.pending.union(Set(operation)))
      .with("tokens",s.tokens.append({owner:operation,encoding:encoding,session:s.session}))
  }
  action emit(index:int,operation:int,encoding:int,checkBinding:bool):bool=all {
    s.tokens.indices().contains(index),not(s.used.contains(index)),s.pending.contains(operation),s.current,
    s.tokens.nth(index).session==s.session,
    (checkBinding implies (s.tokens.nth(index).owner==operation and s.tokens.nth(index).encoding==encoding)),
    s'=s.with("used",s.used.union(Set(index))).with("pending",s.pending.exclude(Set(operation)))
      .with("emissions",s.emissions.append({owner:s.tokens.nth(index).owner,operation:operation,
        preparedEncoding:s.tokens.nth(index).encoding,requestedEncoding:encoding,
        tokenSession:s.tokens.nth(index).session,currentSession:s.session,current:s.current}))
  }
  // Moving/dropping a native token never clears its durable unknown release.
  action discard(index:int):bool=all {s.tokens.indices().contains(index),s'=s.with("used",s.used.union(Set(index)))}
  action restart=s'=s.with("session",s.session+1)
  action revoke=s'=s.with("current",false)
  action observe=s'=s
  action unsafeRefreshDispatch=all {s.session>0,
    s'=s.with("tokens",s.tokens.append({owner:0,encoding:1,session:s.session}))
      .with("reserved",s.reserved.union(Set(0))).with("pending",s.pending.union(Set(0)))}
  action step={
    nondet operation=operations.oneOf()
    nondet encoding=Set(0,1).oneOf()
    nondet index=operations.oneOf()
    any {prepare(operation,encoding),emit(index,operation,encoding,true),discard(index),restart,revoke,observe}
  }
  action pair=init.then(prepare(0,1)).then(prepare(1,1))
  run matchingOriginalReleaseTest=pair.then(emit(1,1,1,true)).expect(safe and s.pending==Set(0))
  run equalBatchCannotTransferPlanTest=pair.then(emit(0,1,1,true).fail())
  run encodingCannotChangeTest=pair.then(emit(0,0,0,true).fail())
  run originalOtherPlanStillWorksTest=pair.then(discard(0)).then(emit(1,1,1,true)).expect(safe and s.pending==Set(0))
  run restartCannotReconstituteTokenTest=pair.then(restart).then(emit(0,0,1,true).fail())
  run originalPendingCannotReprepareTest=pair.then(discard(0)).then(restart).expect(safe and s.held==12).then(prepare(0,1).fail())
  run duplicateReleaseRejectedTest=pair.then(emit(0,0,1,true)).then(emit(0,0,1,true).fail())
  run revokedOriginalRejectedTest=pair.then(revoke).then(emit(0,0,1,true).fail())
  run crossPlanCounterexampleTest=pair.then(emit(0,1,1,false)).expect(not(safe))
  run changedEncodingCounterexampleTest=pair.then(emit(0,0,0,false)).expect(not(safe))
  run restartBeforePreparationRejectsOldDispatchTest=init.then(restart).then(prepare(0,1).fail())
  run discardedPendingCannotReprepareTest=pair.then(discard(0)).then(prepare(0,1).fail())
  run refreshedOriginalDispatchCounterexampleTest=init.then(restart).then(unsafeRefreshDispatch).expect(not(safe))
}
