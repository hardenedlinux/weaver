// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

// Split persistence / observation / signing. Unsafe counterexample rules are not in step.
module ProtectedSignerRelease {
  type Cell = {value:int,term:int,revision:int}
  type History = {size:int,rows:int->Cell}
  type Request = {id:int,voter:int,candidate:History,expected:History,epoch:int,incarnation:int,term:int,revision:int}
  type State = {epoch:int,qualified:bool,qualifiedEpoch:int,readEpoch:int,term:int,revision:int,history:History,
    locks:int->History,incarnation:int->int,retired:Set[int],staged:Set[int],requests:int->Request,
    committed:Set[int],entries:int->Request,observed:Set[int],released:Set[Request],delivered:Set[Request],releaseCount:int}
  var s:State
  pure val voters = 0.to(2)
  pure val ids = 0.to(5)
  pure val slots = 0.to(2)
  pure val empty = {size:0,rows:slots.mapBy(_ => {value:0,term:0,revision:0})}
  pure val absent = {id:-1,voter:0,candidate:empty,expected:empty,epoch:-1,incarnation:-1,term:-1,revision:-1}
  pure def extends(a,b) = a.size <= b.size and slots.forall(i => i >= a.size or a.rows.get(i) == b.rows.get(i))
  pure def comparable(a,b) = extends(a,b) or extends(b,a)
  def proposal(value) = s.history.with("size",s.history.size+1).with("rows",s.history.rows.set(s.history.size,
    {value:value,term:s.term,revision:s.revision}))
  def request(id,v,value) = {id:id,voter:v,candidate:proposal(value),expected:s.locks.get(v),epoch:s.epoch,
    incarnation:s.incarnation.get(v),term:s.term,revision:s.revision}
  def current(q) = q.epoch == s.epoch and q.incarnation == s.incarnation.get(q.voter) and q.term == s.term and q.revision == s.revision
  action init = s' = {epoch:0,qualified:false,qualifiedEpoch:-1,readEpoch:-1,term:0,revision:0,history:empty,locks:voters.mapBy(_ => empty),
    incarnation:voters.mapBy(_ => 0),retired:Set(),staged:Set(),requests:ids.mapBy(_ => absent),committed:Set(),
    entries:ids.mapBy(_ => absent),observed:Set(),released:Set(),delivered:Set(),releaseCount:0}
  action readProtected(epoch,locks,entries,authentic) = all {authentic,epoch == s.epoch,locks == s.locks,entries == s.entries,
    s' = s.with("readEpoch",s.epoch)}
  action readCurrent = readProtected(s.epoch,s.locks,s.entries,true)
  action qualify = all {s.readEpoch == s.epoch,s' = s.with("qualified",true).with("qualifiedEpoch",s.epoch)}
  action begin(id,v,value) = all {s.qualified,s.history.size < 3,not(s.staged.contains(id)),not(s.committed.contains(id)),
    not(s.retired.contains(v)),s' = s.with("staged",s.staged.union(Set(id))).with("requests",s.requests.set(id,request(id,v,value)))}
  action commit(id) = {
    val q = s.requests.get(id)
    all {s.qualified,s.staged.contains(id),not(s.committed.contains(id)),current(q),not(s.retired.contains(q.voter)),
      q.expected == s.locks.get(q.voter),extends(s.locks.get(q.voter),q.candidate),
      s' = s.with("locks",s.locks.set(q.voter,q.candidate)).with("entries",s.entries.set(id,q))
        .with("committed",s.committed.union(Set(id))).with("readEpoch",-1)}
  }
  action observe(id,expected,authentic) = all {authentic,s.committed.contains(id),s.entries.get(id) == expected,
    s' = s.with("observed",s.observed.union(Set(id)))}
  action resolve(id) = observe(id,s.entries.get(id),true)
  action release(id) = {
    val q = s.entries.get(id)
    all {s.qualified,s.committed.contains(id),s.observed.contains(id),current(q),not(s.retired.contains(q.voter)),
      extends(q.candidate,s.locks.get(q.voter)),
      s' = s.with("released",s.released.union(Set(q))).with("releaseCount",s.releaseCount+1)}
  }
  action deliver(id) = {
    val q = s.entries.get(id)
    all {s.released.contains(q),s' = s.with("delivered",s.delivered.union(Set(q)))}
  }
  action rootCommit(value,quorum) = all {quorum.subseteq(voters),quorum.size() >= 2,s.history.size < 3,
    quorum.forall(v => s.delivered.exists(q => q.voter == v and q.candidate == proposal(value) and q.term == s.term and q.revision == s.revision)),
    s' = s.with("history",proposal(value)).with("readEpoch",-1)}
  action restart = s' = s.with("epoch",s.epoch+1).with("qualified",false).with("qualifiedEpoch",-1).with("readEpoch",-1)
    .with("staged",Set()).with("observed",Set()).with("requests",ids.mapBy(_ => absent))
  action retire(v) = s' = s.with("retired",s.retired.union(Set(v))).with("incarnation",s.incarnation.set(v,s.incarnation.get(v)+1)).with("readEpoch",-1)
  action election = s' = s.with("term",s.term+1).with("readEpoch",-1)
  action loseResponse = s' = s
  val durableBeforeRelease = s.released.forall(q => s.committed.contains(q.id) and s.entries.get(q.id) == q and extends(q.candidate,s.locks.get(q.voter)))
  val noConflictingRelease = s.released.forall(a => s.released.forall(b => a.voter != b.voter or comparable(a.candidate,b.candidate)))
  val prefixCovered = s.history.size == 0 or s.released.exists(q => extends(s.history,q.candidate))
  val qualificationSafety = s.qualified implies s.qualifiedEpoch == s.epoch
  val deliveredOriginal = s.delivered.subseteq(s.released)
  val safety = deliveredOriginal and qualificationSafety and durableBeforeRelease and noConflictingRelease and prefixCovered
  action step = {
    nondet id = ids.oneOf()
    nondet v = voters.oneOf()
    nondet value = Set(1,2).oneOf()
    any {readCurrent,qualify,begin(id,v,value),commit(id),resolve(id),release(id),deliver(id),rootCommit(value,Set(0,1)),
      restart,retire(v),election,loseResponse}
  }
  action ready = init.then(readCurrent).then(qualify)
  action pending = ready.then(begin(0,0,1))
  action durable = pending.then(commit(0))
  action signed = durable.then(resolve(0)).then(release(0))
  run lostCommitReplyRemainsDurableTest = durable.then(loseResponse).expect(safety and s.committed.contains(0) and not(s.observed.contains(0)))
  run unknownCommitCannotReleaseTest = durable.then(loseResponse).then(release(0).fail())
  run exactLookupEnablesOriginalReleaseTest = durable.then(loseResponse).then(resolve(0)).then(release(0)).expect(safety)
  run forgedLookupRejectedTest = durable.then(observe(0,s.entries.get(0),false).fail())
  run wrongLookupBodyRejectedTest = durable.then(observe(0,absent,true).fail())
  run duplicateRequestIdCannotChangeBodyTest = durable.then(begin(0,0,2).fail())
  run concurrentConflictFailsCASTest = ready.then(begin(0,0,1)).then(begin(1,0,2)).then(commit(0)).then(commit(1).fail())
  run concurrentSameBodyMustResolveFirstTest = ready.then(begin(0,0,1)).then(begin(1,0,1)).then(commit(0)).then(commit(1).fail())
  run reobservedSameBodyMayBeSignedAgainTest = signed.then(resolve(0)).then(release(0)).expect(safety and s.releaseCount == 2)
  run serviceRestartPreservesCommitTest = signed.then(restart).expect(safety and s.committed.contains(0) and s.locks.get(0).size == 1)
  run restartCannotQualifyFromCachedReadTest = ready.then(restart).then(qualify.fail())
  run oldServiceEpochReleaseRejectedTest = durable.then(restart).then(readCurrent).then(qualify).then(resolve(0)).then(release(0).fail())
  run restoreOldOwnerReadRejectedTest = durable.then(restart).then(readProtected(0,voters.mapBy(_ => empty),ids.mapBy(_ => absent),true).fail())
  run falseRecoveryReadRejectedTest = durable.then(restart).then(readProtected(s.epoch,s.locks,s.entries,false).fail())
  run exactCandidateCanResumeUnderFreshServiceTest = signed.then(restart).then(readCurrent).then(qualify)
    .then(begin(1,0,1)).then(commit(1)).then(resolve(1)).then(release(1)).expect(safety)
  run freshServiceCannotChangeOriginalChoiceTest = signed.then(restart).then(readCurrent).then(qualify)
    .then(begin(1,0,2)).then(commit(1).fail())
  run retiredHandleCannotReleaseTest = durable.then(resolve(0)).then(retire(0)).then(release(0).fail())
  run retiredIdentityCannotReenrollTest = ready.then(retire(0)).then(begin(0,0,1).fail())
  run oldRootTermCannotReleaseTest = durable.then(resolve(0)).then(election).then(release(0).fail())
  run newTermCannotRewriteStickyRecordTest = signed.then(election).then(begin(1,0,1)).then(commit(1).fail())
  run quorumNeedsReleasedSignaturesTest = durable.then(rootCommit(1,Set(0,1)).fail())
  run twoSignerRootCommitTest = signed.then(begin(1,1,1)).then(commit(1)).then(resolve(1)).then(release(1))
    .then(deliver(0)).then(deliver(1)).then(rootCommit(1,Set(0,1))).expect(safety)
  run lateOriginalDeliveryAfterRestartTest = signed.then(restart).then(deliver(0)).expect(safety and s.delivered.size() == 1)
  run unreleasedOutputCannotDeliverTest = durable.then(deliver(0).fail())
  run lateOldTermDeliveryCannotCommitNewTermTest = signed.then(begin(1,1,1)).then(commit(1)).then(resolve(1)).then(release(1))
    .then(election).then(deliver(0)).then(deliver(1)).then(rootCommit(1,Set(0,1)).fail())
  // Deliberately excluded rules; released observations remain an external test oracle.
  action unsafeDetachedCommit(id) = {
    val q = s.requests.get(id)
    all {s' = s.with("locks",s.locks.set(q.voter,q.candidate)).with("entries",s.entries.set(id,q)).with("committed",s.committed.union(Set(id)))}
  }
  action unsafeEarlySign(id) = all {s.staged.contains(id),s' = s.with("released",s.released.union(Set(s.requests.get(id))))}
  action unsafeRawKey(v,value,epoch) = {
    val q = request(5,v,value).with("epoch",epoch)
    all {s' = s.with("released",s.released.union(Set(q)))}
  }
  action unsafeCheckpointRestart = s' = s.with("epoch",0).with("qualified",true).with("locks",voters.mapBy(_ => empty))
    .with("committed",Set()).with("entries",ids.mapBy(_ => absent)).with("observed",Set())
  action unsafeCachedQualification = s' = s.with("qualified",true)
  run concurrentDetachedCASCounterexampleTest = ready.then(begin(0,0,1)).then(begin(1,0,2)).then(commit(0)).then(resolve(0)).then(release(0))
    .then(unsafeDetachedCommit(1)).then(resolve(1)).then(release(1)).expect(not(noConflictingRelease))
  run signBeforeDurableCommitCounterexampleTest = pending.then(unsafeEarlySign(0)).expect(not(durableBeforeRelease))
  run oldRawKeyAfterRestartCounterexampleTest = signed.then(restart).then(unsafeRawKey(0,2,0)).expect(not(noConflictingRelease))
  run checkpointRestoresSigningAuthorityCounterexampleTest = signed.then(unsafeCheckpointRestart).then(begin(1,0,2)).then(commit(1)).then(resolve(1))
    .then(release(1)).expect(not(noConflictingRelease))
  run cachedRecoveryQualificationCounterexampleTest = ready.then(restart).then(unsafeCachedQualification).expect(not(qualificationSafety))
}
