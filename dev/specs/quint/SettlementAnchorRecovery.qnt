// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

// Account gate and independent anchor survive restorable worker/DB-view snapshots.
module SettlementAnchorRecovery {
  import WriterSettlementClosure as W from "./WriterSettlementClosure"
  type Request = {key:int,usage:W::Usage,lineage:int}
  type Permit = {request:Request,worker:int,fence:int}
  type Snapshot = {source:W::World,sourceRevision:int,intentRevision:int,gateRevision:int,confirmRevision:int,
    worker:int,fence:int,intents:Set[int],requests:int->Request,accepted:Set[int],permits:int->Permit,
    outcomes:Set[int],receipts:int->Permit,confirmed:Set[int],confirmations:int->Permit}
  type State = {sourceRevision:int,intentRevision:int,gateRevision:int,confirmRevision:int,worker:int,fence:int,
    intents:Set[int],requests:int->Request,accepted:Set[int],permits:int->Permit,outcomes:Set[int],receipts:int->Permit,
    confirmed:Set[int],confirmations:int->Permit,accepts:int->int,writes:int->int,online:bool,cache:Set[Snapshot],violations:int}
  var a:State
  pure val messages = Set(0,1,2,3)
  pure def blankRequest(k) = {key:k,usage:W::blankUsage(k),lineage:7}
  pure def blankPermit(k) = {request:blankRequest(k),worker:0,fence:0}
  pure val initialState = {sourceRevision:0,intentRevision:0,gateRevision:0,confirmRevision:0,
    worker:0,fence:0,intents:Set(),requests:messages.mapBy(k => blankRequest(k)),accepted:Set(),permits:messages.mapBy(k => blankPermit(k)),
    outcomes:Set(),receipts:messages.mapBy(k => blankPermit(k)),confirmed:Set(),confirmations:messages.mapBy(k => blankPermit(k)),
    accepts:messages.mapBy(_ => 0),writes:messages.mapBy(_ => 0),online:false,cache:Set(),violations:0}
  action initWith(n) = all {W::initWith(n),a' = initialState}
  action init = initWith(3)
  action emptyInit = initWith(0)
  action singletonInit = initWith(1)
  action largerInit = initWith(5)
  action baseStay = all {W::stay,W::z' = W::z}
  def view = {source:W::z,sourceRevision:a.sourceRevision,intentRevision:a.intentRevision,gateRevision:a.gateRevision,
    confirmRevision:a.confirmRevision,worker:a.worker,fence:a.fence,intents:a.intents,requests:a.requests,
    accepted:a.accepted,permits:a.permits,outcomes:a.outcomes,receipts:a.receipts,confirmed:a.confirmed,confirmations:a.confirmations}
  val recovered = a.online and a.cache == Set(view)
  pure def sourceChanged(x) = x.with("sourceRevision",x.sourceRevision+1).with("online",false)
  action recover(image) = all {image == view,baseStay,a' = a.with("cache",Set(image)).with("online",true)}
  action sync = recover(view)
  action restore(image) = all {baseStay,a' = a.with("cache",Set(image)).with("online",false)}
  action loseReply = all {baseStay,a' = a}
  action anchor(k,u) = all {recovered,W::z.settled.contains(k),W::z.settlement.get(k) == u,not(a.intents.contains(k)),baseStay,
    a' = a.with("intents",a.intents.union(Set(k))).with("requests",a.requests.set(k,{key:k,usage:u,lineage:7}))
      .with("intentRevision",a.intentRevision+1).with("online",false)}
  action accept(k,q,worker,fence) = all {recovered,a.intents.contains(k),a.requests.get(k) == q,
    worker == a.worker,fence == a.fence,not(a.accepted.contains(k)),baseStay,
    a' = a.with("accepted",a.accepted.union(Set(k))).with("permits",a.permits.set(k,{request:q,worker:worker,fence:fence}))
      .with("accepts",a.accepts.set(k,a.accepts.get(k)+1)).with("gateRevision",a.gateRevision+1).with("online",false)}
  // Protected account-ledger append and canonical receipt are one gate transaction.
  action applyAtGate(k,permit) = all {a.accepted.contains(k),a.permits.get(k) == permit,not(a.outcomes.contains(k)),
    baseStay,a' = a.with("outcomes",a.outcomes.union(Set(k))).with("receipts",a.receipts.set(k,permit))
      .with("writes",a.writes.set(k,a.writes.get(k)+1)).with("gateRevision",a.gateRevision+1)
      .with("online",false)}
  action confirm(k,receipt) = all {recovered,a.outcomes.contains(k),a.receipts.get(k) == receipt,
    a.requests.get(k) == receipt.request,not(a.confirmed.contains(k)),baseStay,
    a' = a.with("confirmed",a.confirmed.union(Set(k))).with("confirmations",a.confirmations.set(k,receipt))
      .with("confirmRevision",a.confirmRevision+1).with("online",false)}
  action materialize(k) = all {recovered,a.confirmed.contains(k),a.outcomes.contains(k),
    a.confirmations.get(k) == a.receipts.get(k),W::applySettlement(k),a' = sourceChanged(a)}
  action resolve(k,receipt) = all {a.outcomes.contains(k),a.receipts.get(k) == receipt,baseStay,a' = a}
  action rotate(worker) = all {baseStay,a' = a.with("worker",worker).with("fence",a.fence+1)
    .with("gateRevision",a.gateRevision+1).with("online",false)}
  action sourceStep = {
    nondet k = messages.oneOf()
    nondet r = (if (W::z.n == 0) Set(0) else W::ids(W::z.n)).oneOf()
    nondet n = 1.to(4).oneOf()
    nondet inc = 0.to(3).oneOf()
    nondet amount = 0.to(2*W::unit(W::z.n)).oneOf()
    val p = (k,r)
    all {recovered,
      any {W::install(k),W::retire(k),W::close(k),W::observe(k),W::commitUsage(W::usage(k,amount)),W::commitSettlement(k),
        W::driverCrash,W::driverRecover,W::ownerCrash,W::recover,W::restartOwner,W::recoverOwner,W::restrict(k%2),W::recoverHost,
        if (r < W::z.n) any {W::delegate(k,r,inc),W::write(k,r,n),W::prepare(p),W::storeEvidence(W::certificate(p,false)),
          W::storeEvidence(W::certificate(p,true)),W::commitFinish(W::z.evidence.get((p,false))),
          W::acknowledgeFence(W::z.evidence.get((p,true))),W::commitIsolation(W::z.evidence.get((p,true))),W::publish(p)}
        else all {baseStay}},a' = sourceChanged(a)}
  }
  val chainSafety = a.intents.forall(k => a.requests.get(k).key == k and a.requests.get(k).lineage == 7 and
      W::z.settled.contains(k) and W::z.settlement.get(k) == a.requests.get(k).usage) and
    a.accepted.forall(k => a.intents.contains(k) and a.permits.get(k).request == a.requests.get(k)) and
    a.outcomes.forall(k => a.accepted.contains(k) and a.receipts.get(k) == a.permits.get(k)) and
    a.confirmed.forall(k => a.outcomes.contains(k) and a.confirmations.get(k) == a.receipts.get(k))
  val onceSafety = messages.forall(k => a.accepts.get(k) <= 1 and a.writes.get(k) <= 1 and
    (a.accepted.contains(k) iff a.accepts.get(k) == 1) and (a.outcomes.contains(k) iff a.writes.get(k) == 1))
  val accountSafety = messages.forall(k => W::z.applied.contains(k) implies (a.outcomes.contains(k) and a.confirmed.contains(k))) and
    Set(0,1).forall(b => a.outcomes.filter(k => k%2 == b).fold(0,(sum,k) => sum+a.receipts.get(k).request.usage.amount) <= 4*W::unit(W::z.n)) and W::accountSafety
  val recoverySafety = a.online implies a.cache == Set(view)
  val safety = W::safety and chainSafety and onceSafety and accountSafety and recoverySafety and a.violations == 0
  action step = {
    nondet k = messages.oneOf()
    nondet worker = Set(0,1,2).oneOf()
    nondet fence = 0.to(4).oneOf()
    any {sourceStep,sync,restore(view.with("gateRevision",0)),restore(view.with("sourceRevision",0)),
      anchor(k,W::z.settlement.get(k)),accept(k,a.requests.get(k),worker,fence),applyAtGate(k,a.permits.get(k)),
      confirm(k,a.receipts.get(k)),materialize(k),resolve(k,a.receipts.get(k)),rotate(worker),loseReply}
  }
  // Build the preceding real source pipeline, preserving this product on every step.
  action sourceInstall = all {recovered,W::install(0),a' = sourceChanged(a)}
  action sourceDelegate = all {recovered,W::delegate(0,0,0),a' = sourceChanged(a)}
  action sourceWrite = all {recovered,W::write(0,0,4),a' = sourceChanged(a)}
  action sourcePrepare = all {recovered,W::prepare((0,0)),a' = sourceChanged(a)}
  action sourceEvidence = all {recovered,W::storeEvidence(W::certificate((0,0),false)),a' = sourceChanged(a)}
  action sourceFinish = all {recovered,W::commitFinish(W::z.evidence.get(((0,0),false))),a' = sourceChanged(a)}
  action sourcePublish = all {recovered,W::publish((0,0)),a' = sourceChanged(a)}
  action sourceRetire = all {recovered,W::retire(0),a' = sourceChanged(a)}
  action sourceClose = all {recovered,W::close(0),a' = sourceChanged(a)}
  action sourceObserve = all {recovered,W::observe(0),a' = sourceChanged(a)}
  action sourceUsage = all {recovered,W::commitUsage(W::usage(0,1)),a' = sourceChanged(a)}
  action sourceSettle = all {recovered,W::commitSettlement(0),a' = sourceChanged(a)}
  action decision = init.then(sync).then(sourceInstall).then(sync).then(sourceDelegate).then(sync)
    .then(sourceWrite).then(sync).then(sourcePrepare).then(sync).then(sourceEvidence).then(sync)
    .then(sourceFinish).then(sync).then(sourcePublish).then(sync).then(sourceRetire).then(sync)
    .then(sourceClose).then(sync).then(sourceObserve).then(sync).then(sourceUsage).then(sync).then(sourceSettle).then(sync)
  action anchored = decision.then(anchor(0,W::z.settlement.get(0))).then(sync)
  action accepted = anchored.then(accept(0,a.requests.get(0),0,0))
  action applied = accepted.then(applyAtGate(0,a.permits.get(0)))
  action finalized = applied.then(sync).then(confirm(0,a.receipts.get(0))).then(sync).then(materialize(0)).then(sync)
  run anchorReplyLostTest = anchored.then(loseReply).then(anchor(0,W::z.settlement.get(0)).fail())
  run acceptReplyLostPreventsNewWorkerPermitTest = accepted.then(loseReply).then(rotate(1)).then(sync).then(accept(0,a.requests.get(0),1,1).fail())
  run accountWriteReplyLostTest = applied.then(loseReply).then(sync).then(resolve(0,a.receipts.get(0)))
    .then(confirm(0,a.receipts.get(0))).then(sync).expect(safety and a.writes.get(0) == 1)
  run duplicateApplyRejectedTest = applied.then(loseReply).then(applyAtGate(0,a.permits.get(0)).fail())
  run oldWorkerNewAcceptRejectedTest = anchored.then(rotate(1)).then(sync).then(accept(0,a.requests.get(0),0,0).fail())
  run acceptedBeforeFenceMayCompleteOnceTest = accepted.then(rotate(1)).then(applyAtGate(0,a.permits.get(0)))
    .then(sync).then(confirm(0,a.receipts.get(0))).then(sync).expect(safety)
  run gateReceiptRequiredForConfirmationTest = accepted.then(sync).then(confirm(0,a.permits.get(0)).fail())
  run mixedGateSnapshotRejectedTest = applied.then(recover(view.with("gateRevision",0)).fail())
  run mixedSourceSnapshotRejectedTest = applied.then(recover(view.with("sourceRevision",0)).fail())
  run matchingRevisionWrongRowRejectedTest = applied.then(recover(view.with("outcomes",Set())).fail())
  run wrongReceiptAccountRejectedTest = anchored.then(accept(0,a.requests.get(0).with("usage",W::usage(0,1).with("account",1)),0,0).fail())
  run lateWrongReceiptRejectedTest = applied.then(resolve(0,a.receipts.get(0).with("fence",999)).fail())
  run confirmationLostReplyTest = finalized.then(loseReply).then(restore(view.with("confirmed",Set())))
    .then(sync).then(resolve(0,a.receipts.get(0))).expect(safety and a.writes.get(0) == 1)
  run unknownWriteRetainsFullScopeTest = accepted.then(loseReply).then(rotate(1)).then(sync)
    .expect(safety and a.accepted.contains(0) and not(a.outcomes.contains(0)) and W::z.settled.contains(0))
  run staleCacheCannotAuthorizeTest = anchored.then(restore(view.with("intents",Set()))).then(accept(0,a.requests.get(0),0,0).fail())
  run oldSnapshotFreshRecoveryDoesNotReplayTest = finalized.then(restore(view.with("outcomes",Set()).with("accepted",Set())))
    .then(sync).then(accept(0,a.requests.get(0),0,0).fail())
  run noMaterializationWithoutAnchorConfirmationTest = applied.then(sync).then(materialize(0).fail())
  run anchorConfirmationThenCategoryMaterializationTest = finalized.expect(safety and W::z.applied.contains(0))
  run wrongLineageAcceptRejectedTest = anchored.then(accept(0,a.requests.get(0).with("lineage",8),0,0).fail())
  run duplicateConfirmationRejectedTest = finalized.then(confirm(0,a.receipts.get(0)).fail())
  // Excluded mutants retain the real historical counters and original records.
  action forgetGateRows(k) = all {baseStay,a' = a.with("accepted",a.accepted.exclude(Set(k))).with("outcomes",a.outcomes.exclude(Set(k)))
    .with("online",false)}
  action trustMixedCache(image) = all {baseStay,a' = a.with("cache",Set(image)).with("online",true)}
  action duplicateWrite(k) = all {baseStay,a' = a.with("writes",a.writes.set(k,a.writes.get(k)+1))}
  action releaseUnknownBudget(k) = all {W::stay,W::z' = W::z.with("settled",W::z.settled.exclude(Set(k))),a' = a.with("online",false)}
  action fabricateConfirmation(k) = all {baseStay,a' = a.with("confirmed",a.confirmed.union(Set(k)))
    .with("confirmations",a.confirmations.set(k,a.permits.get(k))).with("online",false)}
  action oldWorkerBypass(k) = all {baseStay,a' = a.with("accepted",a.accepted.union(Set(k)))
    .with("permits",a.permits.set(k,{request:a.requests.get(k),worker:0,fence:0}))
    .with("accepts",a.accepts.set(k,a.accepts.get(k)+1)).with("online",false).with("violations",a.violations+1)}
  run gateSnapshotRollbackCounterexampleTest = applied.then(forgetGateRows(0)).then(sync)
    .then(accept(0,a.requests.get(0),0,0)).then(applyAtGate(0,a.permits.get(0))).expect(not(onceSafety) and a.writes.get(0) == 2)
  run cacheEqualityOnlyCounterexampleTest = applied.then(trustMixedCache(view.with("receipts",a.receipts.set(0,blankPermit(0)))))
    .expect(not(recoverySafety))
  run replayUnknownWriteCounterexampleTest = applied.then(duplicateWrite(0)).expect(not(onceSafety))
  run unknownRefundCounterexampleTest = accepted.then(releaseUnknownBudget(0)).expect(not(chainSafety))
  run confirmationWithoutWriteCounterexampleTest = accepted.then(fabricateConfirmation(0)).expect(not(chainSafety))
  run oldWorkerFenceBypassCounterexampleTest = anchored.then(rotate(1)).then(oldWorkerBypass(0)).expect(not(safety))
}
