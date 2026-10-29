// AI Agent Gateway: logical head/fence ownership, durable root CAS and final broker admission.
module GatewayHeadCAS {
  import FiniteDomainMigration as P from "../../specs/quint/FiniteDomainMigration"
  type Head = {id:int,key:int,domain:int,budget:int,history:int,payload:int,claimToken:int,claimStream:int,route:int,policy:int}
  type View = {head:Head,version:int,worker:int,fence:int,semanticRevision:int}
  type Job = {id:int,view:View}
  type Join = {view:View,decisions:Set[Job],rows:Set[Job],boot:int}
  type Audit = {job:Job,at:View}
  type Send = {job:Job,view:View,route:int,key:int,payload:int}
  type State = {head:Head,haveHead:bool,heads:Set[Head],version:int,worker:int,fence:int,boot:int,
    observed:View,haveObservation:bool,jobs:Set[Job],decisions:Set[Job],rows:Set[Job],joined:Join,haveJoin:bool,
    authorityOnline:bool,projectionOnline:bool,sends:Set[Send],audits:Set[Audit]}
  var g:State
  pure val emptyHead = {id:-1,key:-1,domain:-1,budget:-1,history:-1,payload:-1,claimToken:-1,claimStream:-1,route:-1,policy:-1}
  pure val emptyView = {head:emptyHead,version:-1,worker:-1,fence:-1,semanticRevision:-1}
  pure val emptyJob = {id:-1,view:emptyView}
  pure val emptyJoin = {view:emptyView,decisions:Set(),rows:Set(),boot:-1}
  pure val initial = {head:emptyHead,haveHead:false,heads:Set(),version:0,worker:0,fence:0,boot:0,observed:emptyView,haveObservation:false,
    jobs:Set(),decisions:Set(),rows:Set(),joined:emptyJoin,haveJoin:false,authorityOnline:true,projectionOnline:true,sends:Set(),audits:Set()}
  action init = all {P::init,g' = initial}
  def jobAt(id) = g.jobs.fold(emptyJob,(found,j) => if (j.id == id) j else found)
  def decidedJob = g.decisions.fold(emptyJob,(found,j) => if (found.id == -1 or j.id < found.id) j else found)
  def currentView = {head:g.head,version:g.version,worker:g.worker,fence:g.fence,semanticRevision:P::s.revision}
  def currentJoin = {view:currentView,decisions:g.decisions,rows:g.rows,boot:g.boot}
  def canonical(h) = P::intents.contains(h.key) and h.domain == P::root(h.key) and h.budget == P::budget(h.domain) and
    h.history == P::history(h.domain) and h.payload == P::payload(h.key) and P::s.messages.get(h.key).claimed and P::s.messages.get(h.key).reserved and
    h.claimToken == P::s.messages.get(h.key).claimToken and h.claimStream == P::s.messages.get(h.key).claimStream
  def unresolved(k) = not(g.decisions.exists(j => j.view.head.key == k))
  def joined = g.haveJoin and g.joined == currentJoin and g.decisions.subseteq(g.rows) and g.authorityOnline and g.projectionOnline
  def livePolicy(h) = canonical(h) and not(P::s.restricted.contains(h.history)) and h.route >= 0 and h.route <= 2
  action changeHead(k,route,policy,worker) = {
    val h = {id:g.heads.size(),key:k,domain:P::root(k),budget:P::budget(P::root(k)),history:P::history(P::root(k)),payload:P::payload(k),
      claimToken:P::s.messages.get(k).claimToken,claimStream:P::s.messages.get(k).claimStream,route:route,policy:policy}
    all {g.authorityOnline,worker == g.worker,canonical(h),P::resumeOldWorker,
      g' = g.with("head",h).with("haveHead",true).with("heads",g.heads.union(Set(h))).with("version",g.version+1).with("fence",g.fence+1)
        .with("haveObservation",false).with("haveJoin",false)}
  }
  action restoreHead(h,worker) = all {g.authorityOnline,worker == g.worker,g.heads.contains(h),canonical(h),P::resumeOldWorker,
    g' = g.with("head",h).with("version",g.version+1).with("fence",g.fence+1).with("haveObservation",false).with("haveJoin",false)}
  action republish = all {g.authorityOnline,g.haveHead,P::resumeOldWorker,g' = g.with("version",g.version+1).with("haveObservation",false).with("haveJoin",false)}
  action observeHead(v,authentic) = all {authentic,g.authorityOnline,g.haveHead,v == currentView,P::resumeOldWorker,
    g' = g.with("observed",v).with("haveObservation",true)}
  action readHead = observeHead(currentView,true)
  action prepare = {
    val j = {id:g.jobs.size(),view:g.observed}
    all {g.authorityOnline,g.haveObservation,g.observed == currentView,canonical(g.head),unresolved(g.head.key),P::resumeOldWorker,
      g' = g.with("jobs",g.jobs.union(Set(j)))}
  }
  action commit(j,worker,authentic) = all {authentic,g.authorityOnline,g.jobs.contains(j),g.haveHead,g.haveObservation,
    worker == g.worker,j.view.worker == worker,j.view == currentView,g.observed == j.view,canonical(g.head),livePolicy(g.head),unresolved(j.view.head.key),
    P::resumeOldWorker,g' = g.with("decisions",g.decisions.union(Set(j))).with("audits",g.audits.union(Set({job:j,at:currentView}))).with("version",g.version+1).with("haveObservation",false).with("haveJoin",false)}
  // Materialization is metadata only; a historical canonical row is not a send permit.
  action applyRow(j,authentic) = all {authentic,g.projectionOnline,g.decisions.contains(j),
    g.rows.forall(r => r.view.head.key != j.view.head.key or r == j),P::resumeOldWorker,g' = g.with("rows",g.rows.union(Set(j))).with("haveJoin",false)}
  action observeJoin(v,decisions,rows,boot,authentic) = all {authentic,g.authorityOnline,g.projectionOnline,g.haveHead,v == currentView,
    decisions == g.decisions,rows == g.rows,decisions.subseteq(rows),boot == g.boot,P::resumeOldWorker,
    g' = g.with("joined",{view:v,decisions:decisions,rows:rows,boot:boot}).with("haveJoin",true)}
  action readJoin = observeJoin(currentView,g.decisions,g.rows,g.boot,true)
  action send(j,a,e,slot,route,payload) = all {g.haveHead,joined,g.decisions.contains(j),j.view.head == g.head,P::intent(a) == g.head.key,route == g.head.route,payload == g.head.payload,livePolicy(g.head),
    P::offer(a,e,slot),g' = g.with("sends",g.sends.union(Set({job:j,view:currentView,route:route,key:g.head.key,payload:payload}))).with("haveJoin",false).with("haveObservation",false)}
  action restartBroker = all {P::resumeOldWorker,g' = g.with("worker",g.worker+1).with("fence",g.fence+1).with("version",g.version+1)
    .with("boot",g.boot+1).with("haveObservation",false).with("haveJoin",false)}
  action restartClient = all {P::resumeOldWorker,g' = g.with("boot",g.boot+1).with("haveObservation",false).with("haveJoin",false)}
  action rollbackProjection = all {P::resumeOldWorker,g' = g.with("rows",Set()).with("haveJoin",false)}
  action authorityPartition = all {P::resumeOldWorker,g' = g.with("authorityOnline",false).with("haveObservation",false).with("haveJoin",false)}
  action projectionPartition = all {P::resumeOldWorker,g' = g.with("projectionOnline",false).with("haveJoin",false)}
  action reconnect = all {P::resumeOldWorker,g' = g.with("authorityOnline",true).with("projectionOnline",true)}
  action loseReply = all {P::resumeOldWorker,g' = g.with("haveObservation",false).with("haveJoin",false)}
  // Enumerate semantic actions; the unrestricted parent offer is never delegated.
  action enroll(a) = all {P::enroll(a,P::payload(P::intent(a))),g' = g.with("version",g.version+1).with("haveObservation",false).with("haveJoin",false)}
  action create(e,r) = all {P::create(e,r),g' = g.with("version",g.version+1).with("haveObservation",false).with("haveJoin",false)}
  action startWorker(w) = all {P::restart(w),g' = g.with("version",g.version+1).with("haveObservation",false).with("haveJoin",false)}
  action capture(slot,w,r) = all {P::capture(slot,w,r,false),g' = g.with("version",g.version+1).with("haveObservation",false).with("haveJoin",false)}
  action reserve(a,e,slot) = all {P::reserve(a,e,slot),g' = g.with("version",g.version+1).with("haveObservation",false).with("haveJoin",false)}
  action issue(a,e,slot,tok) = all {P::issue(a,e,slot,tok),g' = g.with("version",g.version+1).with("haveObservation",false).with("haveJoin",false)}
  action consume(a,e,slot,w,tok) = all {P::consume(a,e,slot,w,tok),g' = g.with("version",g.version+1).with("haveObservation",false).with("haveJoin",false)}
  action claim(a,e,slot,tok) = all {P::claim(a,e,slot,tok),g' = g.with("version",g.version+1).with("haveObservation",false).with("haveJoin",false)}
  action restrict(h) = all {P::restrict(h),g' = g.with("version",g.version+1).with("haveObservation",false).with("haveJoin",false)}
  action observeOriginal(a,e,slot,tok) = all {P::observe(a,e,slot,tok),g' = g.with("version",g.version+1).with("haveObservation",false).with("haveJoin",false)}
  action rotate(a,e,slot) = all {P::rotate(a,e,slot),g' = g.with("version",g.version+1).with("haveObservation",false).with("haveJoin",false)}
  action reconnectStream(a,e,slot) = all {P::reconnect(a,e,slot),g' = g.with("version",g.version+1).with("haveObservation",false).with("haveJoin",false)}
  val casAudit = g.audits.forall(a => a.job.view == a.at)
  val rootUnique = g.decisions.forall(a => g.decisions.forall(b => a.view.head.key == b.view.head.key implies a == b))
  val decisionsPrepared = g.decisions.subseteq(g.jobs)
  val rowsCommitted = g.rows.subseteq(g.decisions)
  val headSound = g.haveHead implies canonical(g.head)
  val observationSound = g.haveObservation implies g.observed == currentView
  val joinSound = g.haveJoin implies g.joined == currentJoin and g.decisions.subseteq(g.rows)
  val sendBound = g.sends.forall(s => g.decisions.contains(s.job) and s.view.head == s.job.view.head and s.key == s.view.head.key and s.route == s.view.head.route and s.payload == s.view.head.payload)
  val safety = casAudit and P::safety and rootUnique and decisionsPrepared and rowsCommitted and headSound and observationSound and joinSound and sendBound
  action step = {
    nondet k = P::intents.oneOf()
    nondet a = P::rawAliases.oneOf()
    nondet e = P::endpoints.oneOf()
    nondet slot = 0.to(9).oneOf()
    nondet route = 0.to(2).oneOf()
    nondet tok = P::tokens.oneOf()
    nondet w = P::workers.oneOf()
    nondet r = P::roots.oneOf()
    nondet j = g.jobs.union(Set(emptyJob)).oneOf()
    any {changeHead(k,route,0,g.worker),restoreHead(g.head,g.worker),republish,readHead,prepare,commit(j,g.worker,true),applyRow(j,true),readJoin,
      send(j,a,e,slot,route,P::payload(P::intent(a))),restartBroker,restartClient,rollbackProjection,authorityPartition,projectionPartition,reconnect,loseReply,
      enroll(a),create(e,r),startWorker(w),capture(slot,w,r),reserve(a,e,slot),issue(a,e,slot,tok),consume(a,e,slot,w,tok),claim(a,e,slot,tok),
      restrict(r),observeOriginal(a,e,slot,tok),rotate(a,e,slot),reconnectStream(a,e,slot)}
  }
  action originals = init.then(enroll(0)).then(enroll(2)).then(create(0,0)).then(create(1,1)).then(startWorker(0))
    .then(capture(0,0,0)).then(reserve(0,0,0)).then(capture(1,0,0)).then(issue(0,0,1,0))
    .then(capture(2,0,0)).then(consume(0,0,2,0,0)).then(capture(3,0,0)).then(claim(0,0,3,0))
    .then(capture(4,0,1)).then(reserve(2,1,4)).then(capture(5,0,1)).then(issue(2,1,5,1))
    .then(capture(6,0,1)).then(consume(2,1,6,0,1)).then(capture(7,0,1)).then(claim(2,1,7,1)).then(capture(8,0,0))
  action admitted = originals.then(changeHead(0,0,0,g.worker)).then(readHead)
  action prepared = admitted.then(prepare)
  action committed = prepared.then(commit({id:0,view:g.observed},g.worker,true))
  action materialized = committed.then(applyRow(decidedJob,true))
  action ready = materialized.then(readJoin)
  run normalFinalBrokerOfferTest = ready.then(send(decidedJob,0,0,8,0,10)).expect(safety and P::s.messages.get(0).sends == 1)
  run sdkRetryCannotRepeatOriginalOfferTest = ready.then(send(decidedJob,0,0,8,0,10)).then(readJoin).then(send(decidedJob,0,0,8,0,10).fail())
  run preparedIsNotProjectionAuthorityTest = prepared.then(applyRow(jobAt(0),true).fail())
  run lostAuthorityCommitReplyTest = committed.then(loseReply).then(applyRow(decidedJob,true)).then(readJoin).expect(safety and g.decisions.size() == 1)
  run duplicateRootCASRejectedTest = committed.then(readHead).then(commit(jobAt(0),g.worker,true).fail())
  run queuedHeadChangeRejectsCommitTest = prepared.then(changeHead(0,1,0,g.worker)).then(readHead).then(commit(jobAt(0),g.worker,true).fail())
  run republishedHeadRejectsOldVersionTest = prepared.then(republish).then(readHead).then(commit(jobAt(0),g.worker,true).fail())
  run abaHeadPointerDoesNotRestorePermitTest = prepared.then(changeHead(0,1,0,g.worker)).then(restoreHead(jobAt(0).view.head,g.worker)).then(readHead).then(commit(jobAt(0),g.worker,true).fail())
  run oldWorkerCannotCommitAfterRestartTest = prepared.then(restartBroker).then(readHead).then(commit(jobAt(0),g.worker-1,true).fail())
  run newWorkerCannotRelabelOldJobTest = prepared.then(restartBroker).then(readHead).then(commit(jobAt(0),g.worker,true).fail())
  run freshObservationCanRetryUncommittedRootTest = prepared.then(restartBroker).then(readHead).then(prepare)
    .then(commit(jobAt(1),g.worker,true)).expect(safety and g.decisions.size() == 1)
  run twoQueuedJobsHaveSingleWinnerTest = prepared.then(prepare).then(commit(jobAt(0),g.worker,true))
    .then(readHead).then(commit(jobAt(1),g.worker,true).fail())
  run otherMessagePolicyPublicationInvalidatesJobTest = prepared.then(restrict(1)).then(readHead).then(commit(jobAt(0),g.worker,true).fail())
  run semanticTicketPublicationInvalidatesJobTest = prepared.then(capture(9,0,1)).then(readHead).then(commit(jobAt(0),g.worker,true).fail())
  run staleSnapshotObservationRejectedTest = prepared.then(republish).then(observeHead(jobAt(0).view,true).fail())
  run unauthenticatedObservationRejectedTest = admitted.then(observeHead(currentView,false).fail())
  run lostProjectionReplyIsIdempotentTest = materialized.then(loseReply).then(applyRow(decidedJob,true)).then(readJoin).expect(safety and g.rows.size() == 1)
  run projectionRollbackDoesNotRecommitRootTest = materialized.then(rollbackProjection).then(applyRow(decidedJob,true)).then(readJoin)
    .expect(safety and g.decisions.size() == 1 and g.rows.size() == 1)
  run projectionWriteAloneCannotSendTest = materialized.then(send(decidedJob,0,0,8,0,10).fail())
  run oldJoinCannotSurviveBrokerRestartTest = ready.then(restartBroker).then(send(decidedJob,0,0,8,0,10).fail())
  run historicalCommitCanRejoinCurrentBrokerTest = ready.then(restartBroker).then(readJoin).then(send(decidedJob,0,0,8,0,10)).expect(safety)
  run lateProjectionRowDoesNotBypassFenceTest = committed.then(restartBroker).then(applyRow(decidedJob,true)).then(send(decidedJob,0,0,8,0,10).fail())
  run routeChangeBlocksOldCommittedScopeTest = ready.then(changeHead(0,1,0,g.worker)).then(readJoin).then(send(decidedJob,0,0,8,1,10).fail())
  run payloadChangeCannotReuseDecisionTest = ready.then(send(decidedJob,0,0,8,0,11).fail())
  run redirectCannotWidenSelectedRouteTest = ready.then(send(decidedJob,0,0,8,1,10).fail())
  run policyRevocationBlocksFinalOfferTest = ready.then(restrict(0)).then(readJoin).then(send(decidedJob,0,0,8,0,10).fail())
  run unknownBudgetRemainsHeldAcrossRestartTest = committed.then(restartBroker).then(rollbackProjection).expect(safety and P::s.messages.get(0).reserved and P::s.messages.get(1).reserved)
  run clientRestartInvalidatesReadJoinTest = ready.then(restartClient).then(send(decidedJob,0,0,8,0,10).fail())
  run projectionPartitionBlocksSendTest = ready.then(projectionPartition).then(send(decidedJob,0,0,8,0,10).fail())
  run authorityPartitionBlocksCommitTest = prepared.then(authorityPartition).then(commit(jobAt(0),g.worker,true).fail())
  run oldProjectionSnapshotRejectedTest = materialized.then(observeJoin(currentView,g.decisions,Set(),g.boot,true).fail())
  run falseJoinReceiptRejectedTest = materialized.then(observeJoin(currentView,g.decisions,g.rows,g.boot,false).fail())
  run streamReconnectCannotReclaimOriginalTest = ready.then(reconnectStream(0,0,8)).then(readJoin).then(send(decidedJob,0,0,8,0,10).fail())
  // Deliberately unsafe helpers are excluded from step.
  action unsafeStaleCommit = all {P::resumeOldWorker,g' = g.with("decisions",g.decisions.union(Set(jobAt(0)))).with("audits",g.audits.union(Set({job:jobAt(0),at:currentView})))}
  action unsafeSecondCommit = all {P::resumeOldWorker,g' = g.with("decisions",g.decisions.union(Set(decidedJob.with("id",99))))}
  action unsafePreparedRow = all {P::resumeOldWorker,g' = g.with("rows",g.rows.union(Set(jobAt(0))))}
  action unsafeKeepJoinAfterFence = all {P::resumeOldWorker,g' = g.with("fence",g.fence+1)}
  action unsafeRouteSend = all {P::offer(0,0,8),g' = g.with("sends",g.sends.union(Set({job:decidedJob,view:currentView,route:1,key:0,payload:10}))).with("haveJoin",false)}
  run semanticPublicationCASCounterexampleTest = prepared.then(restrict(1)).then(unsafeStaleCommit).expect(not(casAudit))
  run staleHeadCASCounterexampleTest = prepared.then(republish).then(unsafeStaleCommit).expect(not(casAudit))
  run oldWorkerCASCounterexampleTest = prepared.then(restartBroker).then(unsafeStaleCommit).expect(not(casAudit))
  run duplicateRootCompletionCounterexampleTest = committed.then(unsafeSecondCommit).expect(not(rootUnique))
  run preparedProjectionAsCommitCounterexampleTest = prepared.then(unsafePreparedRow).expect(not(rowsCommitted))
  run staleJoinAfterNewFenceCounterexampleTest = ready.then(unsafeKeepJoinAfterFence).expect(not(joinSound))
  run redirectedFinalSendCounterexampleTest = ready.then(unsafeRouteSend).expect(not(sendBound))
}
