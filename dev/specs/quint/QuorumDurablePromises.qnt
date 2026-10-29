// Conservative sticky-prefix voting profile. No implementation or liveness claim.
module QuorumDurablePromises {
  type History = {size:int,rows:int->int}
  type Ack = {voter:int,incarnation:int,scope:int,revision:int,term:int,prior:History,candidate:History}
  type Certificate = {scope:int,revision:int,term:int,prior:History,candidate:History,quorum:Set[int]}
  type State = {stage:int,revision:int,term:int,history:History,locks:int->History,replicas:int->History,
    generation:int->int,ready:Set[int],retired:Set[int],acks:Set[Ack],certificates:Set[Certificate]}
  var s:State
  pure val nodes = 0.to(5)
  pure val slots = 0.to(3)
  pure val empty = {size:0,rows:slots.mapBy(_ => 0)}
  pure def extends(a,b) = a.size <= b.size and slots.forall(i => i >= a.size or a.rows.get(i) == b.rows.get(i))
  pure def comparable(a,b) = extends(a,b) or extends(b,a)
  pure def extendHistory(h,value) = h.with("size",h.size+1).with("rows",h.rows.set(h.size,value))
  pure def majority(group,q) = q.subseteq(group) and q.size() >= 2
  pure val oldNodes = Set(0,1,2)
  pure val newNodes = Set(3,4,5)
  pure def quorum(scope,q) = if (scope == 0) majority(oldNodes,q) else if (scope == 2) majority(newNodes,q)
    else majority(oldNodes,q.intersect(oldNodes)) and majority(newNodes,q.intersect(newNodes))
  pure def eligible(stage,v) = stage == 1 or (stage == 0 and oldNodes.contains(v)) or (stage == 2 and newNodes.contains(v))
  pure def targetScope(stage,value) = if (value == 7) 1 else stage
  pure def allowed(stage,value) = if (value == 7) stage == 0 else if (value == 8) stage == 1 else stage != 1
  action init = s' = {stage:0,revision:0,term:0,history:empty,locks:nodes.mapBy(_ => empty),replicas:nodes.mapBy(_ => empty),
    generation:nodes.mapBy(_ => 0),ready:nodes,retired:Set(),acks:Set(),certificates:Set()}
  action prepare(v,value,token,scope,revision,term) = {
    val candidate = extendHistory(s.history,value)
    all {s.history.size < 4,allowed(s.stage,value),scope == targetScope(s.stage,value),revision == s.revision,term == s.term,
      token == s.generation.get(v),not(s.retired.contains(v)),s.ready.contains(v),eligible(scope,v),
      s.replicas.get(v) == s.locks.get(v),extends(s.locks.get(v),candidate),
      s' = s.with("locks",s.locks.set(v,candidate)).with("replicas",s.replicas.set(v,candidate)).with("acks",s.acks.union(Set(
        {voter:v,incarnation:token,scope:scope,revision:revision,term:term,prior:s.history,candidate:candidate})))}
  }
  action vote(v,value) = prepare(v,value,s.generation.get(v),targetScope(s.stage,value),s.revision,s.term)
  action certify(value,q) = {
    val scope = targetScope(s.stage,value)
    val candidate = extendHistory(s.history,value)
    all {s.history.size < 4,allowed(s.stage,value),quorum(scope,q),q.forall(v => s.acks.exists(a => a.voter == v and
      a.scope == scope and a.revision == s.revision and a.term == s.term and a.prior == s.history and a.candidate == candidate)),
      s' = s.with("history",candidate).with("stage",if (value == 7) 1 else if (value == 8) 2 else s.stage)
        .with("revision",s.revision + (if (value == 7 or value == 8) 1 else 0))
        .with("certificates",s.certificates.union(Set({scope:scope,revision:s.revision,term:s.term,prior:s.history,candidate:candidate,quorum:q})))}
  }
  action restore(v,snapshot) = s' = s.with("replicas",s.replicas.set(v,snapshot)).with("ready",s.ready.exclude(Set(v)))
    .with("generation",s.generation.set(v,s.generation.get(v)+1))
  action recover(v,authentic) = all {authentic,eligible(s.stage,v),not(s.retired.contains(v)),s.history == s.locks.get(v),
    s' = s.with("replicas",s.replicas.set(v,s.locks.get(v))).with("ready",s.ready.union(Set(v)))}
  action retire(v) = s' = s.with("retired",s.retired.union(Set(v))).with("ready",s.ready.exclude(Set(v)))
    .with("generation",s.generation.set(v,s.generation.get(v)+1))
  action election = s' = s.with("term",s.term+1)
  action loseResponse = s' = s
  val ackPersistence = s.acks.forall(a => extends(a.candidate,s.locks.get(a.voter)))
  val certificateWitnesses = s.certificates.forall(c => quorum(c.scope,c.quorum) and c.quorum.forall(v => extends(c.candidate,s.locks.get(v))))
  val prefixAgreement = s.certificates.forall(c => comparable(c.candidate,s.history))
  val safety = ackPersistence and certificateWitnesses and prefixAgreement
  action step = {
    nondet v = nodes.oneOf()
    nondet value = Set(1,2,7,8).oneOf()
    val scope = targetScope(s.stage,value)
    val q = if (scope == 0) oldNodes else if (scope == 2) newNodes else nodes
    any {vote(v,value),certify(value,q),restore(v,empty),recover(v,true),retire(v),election,loseResponse}
  }
  action oldVotes(value) = vote(0,value).then(vote(1,value))
  action allVotes(value) = oldVotes(value).then(vote(3,value)).then(vote(4,value))
  action committed = init.then(oldVotes(1)).then(certify(1,Set(0,1)))
  action joint = init.then(allVotes(7)).then(certify(7,Set(0,1,3,4)))
  action replacement = joint.then(allVotes(8)).then(certify(8,Set(0,1,3,4)))
  run durableBeforeReplyTest = init.then(vote(0,1)).then(loseResponse).expect(safety and s.locks.get(0).size == 1)
  run restoredReplicaCannotErasePromiseTest = committed.then(restore(0,empty)).expect(safety and s.locks.get(0).size == 1)
  run restoredNodeQuarantinedTest = committed.then(restore(0,empty)).then(vote(0,2).fail())
  run staleHandleRejectedTest = committed.then(restore(0,empty)).then(recover(0,true))
    .then(prepare(0,2,0,0,0,0).fail())
  run sameIdentityConflictRejectedTest = init.then(vote(0,1)).then(vote(0,2).fail())
  run exactOriginalAckCanCompleteAfterRestoreTest = init.then(oldVotes(1)).then(restore(0,empty)).then(certify(1,Set(0,1))).expect(safety)
  run lostCommitReplyCannotDuplicateAppendTest = committed.then(loseResponse).then(certify(1,Set(0,1)).fail())
  run pendingPromiseCanBlockRecoveryTest = init.then(vote(0,1)).then(restore(0,empty)).then(recover(0,true).fail())
  run unauthenticatedRecoveryRejectedTest = committed.then(restore(0,empty)).then(recover(0,false).fail())
  run retiredSignerRejectedTest = init.then(retire(0)).then(vote(0,1).fail())
  run retirementDoesNotEraseHistoricalAckTest = init.then(oldVotes(1)).then(retire(0)).then(certify(1,Set(0,1))).expect(safety)
  run oldMemberCannotRecoverAsCurrentNewVoterTest = replacement.then(restore(0,empty)).then(recover(0,true).fail())
  run staleScopeRejectedTest = replacement.then(prepare(3,1,s.generation.get(3),0,0,0).fail())
  run electionInvalidatesPendingTermAcksTest = init.then(oldVotes(1)).then(election).then(certify(1,Set(0,1)).fail())
  run electionCannotErasePendingPromiseTest = init.then(vote(0,1)).then(election).then(vote(0,2).fail())
  run jointElectionAndFinalizationTest = joint.then(election).then(allVotes(8)).then(certify(8,Set(0,1,3,4))).expect(safety and s.stage == 2)
  run newOnlyCannotEnterJointTest = init.then(allVotes(7)).then(certify(7,Set(3,4)).fail())
  run oldOnlyCannotFinalizeTest = joint.then(allVotes(8)).then(certify(8,Set(0,1)).fail())
  run recoveredNewMemberKeepsInheritedPrefixTest = replacement.then(restore(3,empty)).then(recover(3,true))
    .then(vote(3,1)).then(vote(4,1)).then(certify(1,Set(3,4))).expect(safety and s.history.size == 3)
  run lateOldAckCannotBecomeNewCertificateTest = replacement.then(certify(1,Set(0,1)).fail())
  // Fault injection stays outside step. External ack/certificate history is retained.
  action erasePromise(v) = s' = s.with("locks",s.locks.set(v,empty)).with("replicas",s.replicas.set(v,empty))
    .with("ready",s.ready.union(Set(v)))
  action forgetCommit = s' = s.with("history",empty)
  action resurrectOldMember = s' = s.with("stage",0).with("revision",0).with("history",empty)
    .with("locks",nodes.mapBy(_ => empty)).with("replicas",nodes.mapBy(_ => empty)).with("ready",nodes)
  run rollbackSharedWitnessCounterexampleTest = init.then(oldVotes(1)).then(certify(1,Set(0,1))).then(forgetCommit)
    .then(erasePromise(1)).then(vote(1,2)).then(vote(2,2)).then(certify(2,Set(1,2))).expect(not(safety))
  run reEnrollSameSignerCounterexampleTest = init.then(vote(1,1)).then(erasePromise(1)).then(vote(1,2)).expect(not(ackPersistence))
  run oldRosterResurrectionCounterexampleTest = replacement.then(resurrectOldMember).then(oldVotes(2))
    .then(certify(2,Set(0,1))).expect(not(prefixAgreement))
  run allRollbackRootsLostCounterexampleTest = committed.then(forgetCommit).then(erasePromise(0)).then(erasePromise(1))
    .then(oldVotes(2)).then(certify(2,Set(0,1))).expect(not(safety))
}
