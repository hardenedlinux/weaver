// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

// Split evidence/decision/view stores; original final usage and settlement joins.
module WriterSettlementClosure {
  import DriverCompletionRecovery as D from "./DriverCompletionRecovery"
  type Key = (int,int)
  type Evidence = {key:Key,manifest:int,generation:int,epoch:int,inc:int,frontier:int,
    isolation:bool,writers:int,buffers:int,authentic:bool}
  type Usage = {message:int,manifest:int,token:int,stream:int,account:int,history:int,
    closure:int,unit:int,amount:int,final:bool,authentic:bool}
  type World = {n:int,accepted:Set[Key],blobs:Set[(Key,bool)],evidence:(Key,bool)->Evidence,
    decisions:Set[Key],selected:Key->bool,visible:Set[Key],retired:Set[int],closed:Set[int],
    usage:Set[int],receipts:int->Usage,settled:Set[int],settlement:int->Usage,applied:Set[int],charges:int->int,
    ready:bool,violations:int}
  var z:World
  pure def ids(n) = 0.to(n-1)
  pure def pairs(n) = Set(0,1,2,3).map(k => ids(n).map(r => (k,r))).flatten()
  pure def evidenceIds(n) = pairs(n).map(p => Set((p,false),(p,true))).flatten()
  pure def blankEvidence(p,i) = {key:p,manifest:100+p._1,generation:-1,epoch:0,inc:0,frontier:0,
    isolation:i,writers:2000+100*p._1+p._2,buffers:3000+100*p._1+p._2,authentic:false}
  pure def blankUsage(k) = {message:k,manifest:100+k,token:k,stream:k%2,account:k%2,history:k%2,
    closure:4000+k,unit:1,amount:0,final:false,authentic:false}
  pure def unit(n) = if (n == 0) 1 else n*(n+1)/2
  action initWith(n) = all {D::initWith(n),z' = {n:n,accepted:Set(),blobs:Set(),
    evidence:evidenceIds(n).mapBy(t => blankEvidence(t._1,t._2)),decisions:Set(),selected:pairs(n).mapBy(_ => false),
    visible:Set(),retired:Set(),closed:Set(),usage:Set(),receipts:Set(0,1,2,3).mapBy(k => blankUsage(k)),
    settled:Set(),settlement:Set(0,1,2,3).mapBy(k => blankUsage(k)),applied:Set(),charges:Set(0,1,2,3).mapBy(_ => 0),ready:true,violations:0}}
  action init = initWith(3)
  action emptyInit = initWith(0)
  action singletonInit = initWith(1)
  action largerInit = initWith(5)
  action stay = all {D::stay,D::y' = D::y}
  def certificate(p,i) = {
    val q = D::request(p)
    {key:p,manifest:q.manifest,generation:D::y.tails.get(p),epoch:q.epoch,inc:q.inc,frontier:q.frontier,
      isolation:i,writers:2000+100*p._1+p._2,buffers:3000+100*p._1+p._2,authentic:true}
  }
  pure def req(e) = {key:e.key,manifest:e.manifest,generation:e.generation,epoch:e.epoch,inc:e.inc,frontier:e.frontier}
  def evidenceBound(e) = e.authentic and z.accepted.contains(e.key) and e.manifest == 100+e.key._1 and
    e.generation == D::y.tails.get(e.key) and e.epoch == D::request(e.key).epoch and e.inc == D::request(e.key).inc and
    e.writers == 2000+100*e.key._1+e.key._2 and e.buffers == 3000+100*e.key._1+e.key._2
  def streamPublished(k) = z.decisions.filter(p => p._1%2 == k%2).forall(p => z.visible.contains(p))
  def closureReady(k) = z.accepted.filter(p => p._1 == k).forall(p => z.decisions.contains(p) and z.visible.contains(p))
  def usage(k,amount) = blankUsage(k).with("final",true).with("authentic",true).with("amount",amount)
  def usageBound(u) = u.authentic and u.final and z.closed.contains(u.message) and
    u.manifest == 100+u.message and u.token == u.message and u.stream == u.message%2 and
    u.account == u.message%2 and u.history == u.message%2 and u.closure == 4000+u.message and
    u.unit == 1 and u.amount >= 0 and u.amount <= 2*unit(z.n)
  action install(k) = all {z.ready,D::install(k),z' = z}
  action delegate(k,r,inc) = all {z.ready,streamPublished(k),not(z.closed.contains(k)),D::delegate(k,r,0,inc),
    z' = z.with("accepted",z.accepted.union(Set((k,r))))}
  action write(k,r,n) = all {z.ready,D::write(k,r,n),z' = z}
  action prepare(p) = all {z.ready,D::prepare(D::request(p)),z' = z}
  // Durable authentic evidence store; the two kinds have separate immutable slots.
  action storeEvidence(e) = all {z.ready,evidenceBound(e),not(z.blobs.contains((e.key,e.isolation))),stay,
    z' = z.with("blobs",z.blobs.union(Set((e.key,e.isolation)))).with("evidence",z.evidence.set((e.key,e.isolation),e))}
  // Linearization is the canonical durable decision, not its RPC response or view.
  action commitFinish(e) = all {z.ready,not(e.isolation),z.blobs.contains((e.key,false)),
    z.evidence.get((e.key,false)) == e,not(z.decisions.contains(e.key)),D::finish(req(e)),
    z' = z.with("decisions",z.decisions.union(Set(e.key))).with("selected",z.selected.set(e.key,false))}
  action acknowledgeFence(e) = all {z.ready,e.isolation,z.blobs.contains((e.key,true)),
    z.evidence.get((e.key,true)) == e,D::fence(e.key),z' = z}
  action commitIsolation(e) = all {z.ready,e.isolation,z.blobs.contains((e.key,true)),
    z.evidence.get((e.key,true)) == e,not(z.decisions.contains(e.key)),D::quarantine(e.key),
    z' = z.with("decisions",z.decisions.union(Set(e.key))).with("selected",z.selected.set(e.key,true))}
  action publish(p) = all {z.ready,z.decisions.contains(p),z.blobs.contains((p,z.selected.get(p))),stay,
    z' = z.with("visible",z.visible.union(Set(p)))}
  action retire(k) = all {z.ready,closureReady(k),D::retire(k),z' = z.with("retired",z.retired.union(Set(k)))}
  action close(k) = all {z.ready,z.retired.contains(k),closureReady(k),stay,z' = z.with("closed",z.closed.union(Set(k)))}
  action commitUsage(u) = all {z.ready,usageBound(u),not(z.usage.contains(u.message)),D::finalUsage(u.message),
    z' = z.with("usage",z.usage.union(Set(u.message))).with("receipts",z.receipts.set(u.message,u))}
  action commitSettlement(k) = all {z.ready,z.closed.contains(k),z.usage.contains(k),not(z.settled.contains(k)),stay,
    z' = z.with("settled",z.settled.union(Set(k))).with("settlement",z.settlement.set(k,z.receipts.get(k)))}
  action applySettlement(k) = all {z.ready,z.settled.contains(k),not(z.applied.contains(k)),D::settle(k),
    z' = z.with("applied",z.applied.union(Set(k))).with("charges",z.charges.set(k,z.charges.get(k)+1))}
  action resolveSettlement(k,u) = all {z.settled.contains(k),z.settlement.get(k) == u,stay,z' = z}
  action observe(k) = all {D::observe(k),z' = z}
  action loseReply = all {D::loseReply,z' = z}
  action driverCrash = all {D::crash,z' = z}
  action driverRecover = all {D::recover,z' = z}
  action ownerCrash = all {stay,z' = z.with("ready",false)}
  // Recovery preserves the independently authoritative stores and original bindings.
  action recover = all {stay,z' = z.with("ready",true)}
  action restartOwner = all {D::restartOwner,z' = z}
  action recoverOwner = all {D::recoverOwner,z' = z}
  action restrict(h) = all {D::restrict(h),z' = z}
  action recoverHost = all {D::recoverHost,z' = z}
  val visibleSafety = z.visible.forall(p => z.decisions.contains(p) and z.blobs.contains((p,z.selected.get(p))))
  val decisionSafety = z.decisions.forall(p => z.accepted.contains(p) and z.blobs.contains((p,z.selected.get(p))) and
    z.evidence.get((p,z.selected.get(p))).key == p)
  val closedSafety = z.closed.forall(k => z.retired.contains(k) and closureReady(k))
  val settlementSafety = z.settled.forall(k => z.usage.contains(k) and z.closed.contains(k) and
    z.settlement.get(k) == z.receipts.get(k) and usageBound(z.receipts.get(k))) and
    Set(0,1,2,3).forall(k => z.charges.get(k) <= 1)
  val appliedSafety = Set(0,1,2,3).forall(k =>
    (z.applied.contains(k) iff z.charges.get(k) == 1) and
    (D::y.charged.contains(k) iff z.applied.contains(k)) and
    (z.applied.contains(k) implies z.settled.contains(k)))
  val accountSafety = Set(0,1).forall(a => Set(0,1,2,3).filter(k => k%2 == a and z.settled.contains(k))
    .fold(0,(sum,k) => sum+z.settlement.get(k).amount) <= 4*unit(z.n))
  val safety = D::safety and visibleSafety and decisionSafety and closedSafety and settlementSafety and appliedSafety and accountSafety and z.violations == 0
  action step = {
    nondet k = Set(0,1,2,3).oneOf()
    nondet r = (if (z.n == 0) Set(0) else ids(z.n)).oneOf()
    nondet inc = 0.to(3).oneOf()
    nondet n = 1.to(4).oneOf()
    nondet amount = 0.to(2*unit(z.n)).oneOf()
    val p = (k,r)
    any {install(k),driverCrash,driverRecover,ownerCrash,recover,restartOwner,recoverOwner,
      observe(k),retire(k),close(k),commitUsage(usage(k,amount)),commitSettlement(k),applySettlement(k),
      resolveSettlement(k,z.settlement.get(k)),loseReply,restrict(k%2),recoverHost,
      if (r < z.n) any {delegate(k,r,inc),write(k,r,n),prepare(p),storeEvidence(certificate(p,false)),storeEvidence(certificate(p,true)),
        commitFinish(z.evidence.get((p,false))),acknowledgeFence(z.evidence.get((p,true))),commitIsolation(z.evidence.get((p,true))),publish(p)}
      else all {stay,z' = z}}
  }
  // Mutants are never enabled by step. Audit facts are not execution guards.
  action publishFromBlob(p) = all {stay,z' = z.with("visible",z.visible.union(Set(p)))}
  action duplicateSettlement(k) = all {stay,z' = z.with("charges",z.charges.set(k,z.charges.get(k)+1))}
  action replaceFinal(u) = all {stay,z' = z.with("receipts",z.receipts.set(u.message,u))}
  action forgedClose(k) = all {stay,z' = z.with("closed",z.closed.union(Set(k)))}
  action dropDecision(p) = all {stay,z' = z.with("decisions",z.decisions.exclude(Set(p)))}
  action restoreOldFd(p) = all {D::copyRecoveredTail(p),z' = z}
  action trustWrongFence(e) = all {D::fence(e.key),z' = z.with("violations",z.violations+1)}
  action finishAsUsage(k) = all {stay,z' = z.with("settled",z.settled.union(Set(k))).with("charges",z.charges.set(k,1))}

  action ready = init.then(install(0)).then(delegate(0,0,0))
  action full = ready.then(write(0,0,4)).then(prepare((0,0))).then(storeEvidence(certificate((0,0),false)))
  action finished = full.then(commitFinish(z.evidence.get(((0,0),false))))
  action terminal = finished.then(publish((0,0))).then(retire(0)).then(close(0)).then(observe(0))
  action billed = terminal.then(commitUsage(usage(0,1))).then(commitSettlement(0)).then(applySettlement(0))
  run evidenceReplyLostKeepsStreamTest = full.then(loseReply).then(delegate(0,1,0).fail())
  run committedButUnpublishedBlocksStreamTest = finished.then(loseReply).then(delegate(0,1,0).fail())
  run publishMissingDecisionRejectedTest = full.then(publish((0,0)).fail())
  run commitReplyLostRecoveryTest = finished.then(loseReply).then(ownerCrash).then(driverCrash).then(driverRecover).then(recover)
    .then(publish((0,0))).then(delegate(0,1,0)).expect(safety)
  run uncommittedFinishRestartRejectsTest = full.then(driverCrash).then(driverRecover)
    .then(commitFinish(z.evidence.get(((0,0),false))).fail())
  run separateIsolationEvidenceAfterFinishIntentTest = full.then(driverCrash).then(driverRecover)
    .then(storeEvidence(certificate((0,0),true))).then(acknowledgeFence(z.evidence.get(((0,0),true))))
    .then(commitIsolation(z.evidence.get(((0,0),true)))).then(publish((0,0))).then(retire(0)).then(close(0)).expect(safety)
  run partialOldFdCannotResumeTest = ready.then(write(0,0,1)).then(driverCrash).then(driverRecover).then(write(0,0,3).fail())
  run fenceAcknowledgmentRequiredTest = ready.then(storeEvidence(certificate((0,0),true)))
    .then(commitIsolation(z.evidence.get(((0,0),true))).fail())
  run wrongWriterInventoryRejectedTest = ready.then(storeEvidence(certificate((0,0),true).with("writers",999)).fail())
  run wrongBufferInventoryRejectedTest = ready.then(storeEvidence(certificate((0,0),true).with("buffers",999)).fail())
  run forgedAuthenticityRejectedTest = ready.then(storeEvidence(certificate((0,0),true).with("authentic",false)).fail())
  run unpublishedPreventsRetirementTest = finished.then(retire(0).fail())
  run lateOriginalPublishKeepsSuccessorTest = finished.then(publish((0,0))).then(delegate(0,1,0))
    .then(publish((0,0))).expect(safety).then(retire(0).fail())
  run noFinalUsageFromFinishTest = finished.then(commitUsage(usage(0,1)).fail())
  run lateUsageDoesNotReleaseStreamTest = ready.then(commitUsage(usage(0,1)).fail())
  run finalUsageLostReplyResolveTest = terminal.then(commitUsage(usage(0,1))).then(loseReply).then(ownerCrash).then(recover)
    .then(commitSettlement(0)).then(loseReply).then(resolveSettlement(0,usage(0,1))).then(applySettlement(0)).expect(safety)
  run duplicateFinalUsageRejectedTest = billed.then(commitUsage(usage(0,1)).fail())
  run conflictingLateUsageRejectedTest = billed.then(commitUsage(usage(0,2)).fail())
  run wrongClosureUsageRejectedTest = terminal.then(commitUsage(usage(0,1).with("closure",999)).fail())
  run wrongUnitUsageRejectedTest = terminal.then(commitUsage(usage(0,1).with("unit",999)).fail())
  run wrongAccountUsageRejectedTest = terminal.then(commitUsage(usage(0,1).with("account",1)).fail())
  run wrongTokenUsageRejectedTest = terminal.then(commitUsage(usage(0,1).with("token",999)).fail())
  run progressUsageRejectedTest = terminal.then(commitUsage(usage(0,1).with("final",false)).fail())
  run overEnvelopeUsageRejectedTest = terminal.then(commitUsage(usage(0,1000)).fail())
  run settlementRetryCannotChargeTwiceTest = billed.then(loseReply).then(ownerCrash).then(recover)
    .then(resolveSettlement(0,usage(0,1))).expect(safety).then(commitSettlement(0).fail())
  run isolatedUnknownHoldRetainedTest = ready.then(driverCrash).then(driverRecover).then(storeEvidence(certificate((0,0),true)))
    .then(acknowledgeFence(z.evidence.get(((0,0),true)))).then(commitIsolation(z.evidence.get(((0,0),true)))).then(publish((0,0)))
    .then(retire(0)).then(close(0)).then(observe(0)).then(commitSettlement(0).fail())
  run forgedFinalUsageRejectedTest = terminal.then(commitUsage(usage(0,1).with("authentic",false)).fail())
  run isolationWinningRejectsFinishTest = full.then(storeEvidence(certificate((0,0),true)))
    .then(acknowledgeFence(z.evidence.get(((0,0),true)))).then(commitIsolation(z.evidence.get(((0,0),true))))
    .then(commitFinish(z.evidence.get(((0,0),false))).fail())
  run finishWinningRejectsIsolationTest = finished.then(storeEvidence(certificate((0,0),true)))
    .then(commitIsolation(z.evidence.get(((0,0),true))).fail())
  run sharedAccountFinalizationTest = initWith(1).then(install(0)).then(install(2)).then(delegate(0,0,0))
    .then(write(0,0,4)).then(prepare((0,0))).then(storeEvidence(certificate((0,0),false)))
    .then(commitFinish(z.evidence.get(((0,0),false)))).then(publish((0,0))).then(retire(0)).then(close(0))
    .then(observe(0)).then(commitUsage(usage(0,2))).then(commitSettlement(0)).then(applySettlement(0)).then(delegate(2,0,0))
    .then(write(2,0,4)).then(prepare((2,0))).then(storeEvidence(certificate((2,0),false)))
    .then(commitFinish(z.evidence.get(((2,0),false)))).then(publish((2,0))).then(retire(2)).then(close(2))
    .then(observe(2)).then(commitUsage(usage(2,2))).then(commitSettlement(2)).then(applySettlement(2)).expect(safety and accountSafety)
  run settlementDecisionLostReplyBeforeAccountApplyTest = terminal.then(commitUsage(usage(0,1))).then(commitSettlement(0))
    .then(loseReply).then(ownerCrash).then(recover).then(resolveSettlement(0,usage(0,1)))
    .expect(safety and z.charges.get(0) == 0).then(applySettlement(0)).then(loseReply)
    .then(resolveSettlement(0,usage(0,1))).expect(safety and z.charges.get(0) == 1)
  run accountApplyRetryRejectedTest = billed.then(loseReply).then(ownerCrash).then(recover).then(applySettlement(0).fail())
  run evidenceOnlyPublicationCounterexampleTest = full.then(publishFromBlob((0,0))).expect(not(visibleSafety))
  run duplicatedFinancialApplyCounterexampleTest = billed.then(duplicateSettlement(0)).expect(not(settlementSafety))
  run lateFinalOverwriteCounterexampleTest = billed.then(replaceFinal(usage(0,2))).expect(not(settlementSafety))
  run usageCreatesClosureCounterexampleTest = ready.then(forgedClose(0)).expect(not(closedSafety))
  run commitReplyLossErasesDecisionCounterexampleTest = finished.then(publish((0,0))).then(loseReply)
    .then(dropDecision((0,0))).expect(not(visibleSafety))
  run restoredFdRetagCounterexampleTest = ready.then(write(0,0,1)).then(driverCrash).then(driverRecover)
    .then(restoreOldFd((0,0))).then(write(0,0,3)).expect(not(safety))
  run incompleteWriterUniverseCounterexampleTest = ready.then(trustWrongFence(certificate((0,0),true).with("writers",999))).expect(not(safety))
  run completionIsBillingCounterexampleTest = finished.then(finishAsUsage(0)).expect(not(settlementSafety))
}
