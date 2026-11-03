// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

// Recoverable gate journal; independent pre-effect issuance/consumption root.
module GateConsumptionPersistence {
  import SettlementAnchorRecovery as A from "./SettlementAnchorRecovery"
  type Journal = {seals:Set[int],permits:int->A::Permit,grants:Set[int],grantEpoch:int->int,
    burns:Set[int],burnPermits:int->A::Permit,burnEpoch:int->int,results:Set[int],receipts:int->A::Permit,epoch:int}
  type State = {root:Journal,disk:Journal,caps:Set[int],capEpoch:int->int,pending:Set[int],
    grantCount:int->int,burnCount:int->int,needsFence:bool,violations:int}
  var g:State
  pure val messageKeys = A::messages
  pure val emptyJournal = {seals:Set(),permits:messageKeys.mapBy(k => A::blankPermit(k)),
    grants:Set(),grantEpoch:messageKeys.mapBy(_ => 0),burns:Set(),burnPermits:messageKeys.mapBy(k => A::blankPermit(k)),
    burnEpoch:messageKeys.mapBy(_ => 0),results:Set(),receipts:messageKeys.mapBy(k => A::blankPermit(k)),epoch:0}
  pure val initial = {root:emptyJournal,disk:emptyJournal,caps:Set(),capEpoch:messageKeys.mapBy(_ => 0),pending:Set(),
    grantCount:messageKeys.mapBy(_ => 0),burnCount:messageKeys.mapBy(_ => 0),needsFence:false,violations:0}
  action initWith(n) = all {A::initWith(n),g' = initial}
  action init = initWith(3)
  action emptyInit = initWith(0)
  action singletonInit = initWith(1)
  action largerInit = initWith(5)
  action baseStay = all {A::baseStay,A::a' = A::a}
  val covered = g.root.burns.subseteq(g.root.results)
  val ready = not(g.needsFence) and g.disk == g.root and covered
  action rebuild = all {not(g.needsFence),covered,A::sync,g' = g.with("disk",g.root)}
  action sealRoot(k) = all {ready,not(g.root.seals.contains(k)),
    A::accept(k,A::a.requests.get(k),A::a.worker,A::a.fence),
    g' = g.with("root",g.root.with("seals",g.root.seals.union(Set(k)))
      .with("permits",g.root.permits.set(k,{request:A::a.requests.get(k),worker:A::a.worker,fence:A::a.fence})))}
  action grant(k) = all {ready,A::recovered,g.root.seals.contains(k),not(g.root.grants.contains(k)),baseStay,
    g' = g.with("root",g.root.with("grants",g.root.grants.union(Set(k))).with("grantEpoch",g.root.grantEpoch.set(k,g.root.epoch)))
      .with("caps",g.caps.union(Set(k))).with("capEpoch",g.capEpoch.set(k,g.root.epoch))
      .with("grantCount",g.grantCount.set(k,g.grantCount.get(k)+1))}
  action burn(k) = all {not(g.needsFence),g.caps.contains(k),g.capEpoch.get(k) == g.root.epoch,
    g.root.seals.contains(k),not(g.root.burns.contains(k)),baseStay,
    g' = g.with("root",g.root.with("burns",g.root.burns.union(Set(k)))
      .with("burnPermits",g.root.burnPermits.set(k,g.root.permits.get(k))).with("burnEpoch",g.root.burnEpoch.set(k,g.root.epoch)))
      .with("caps",g.caps.exclude(Set(k))).with("pending",g.pending.union(Set(k)))
      .with("burnCount",g.burnCount.set(k,g.burnCount.get(k)+1))}
  action complete(k) = all {g.root.burns.contains(k),g.pending.contains(k),A::applyAtGate(k,g.root.burnPermits.get(k)),
    g' = g.with("pending",g.pending.exclude(Set(k))).with("disk",g.disk.with("results",g.disk.results.union(Set(k)))
      .with("receipts",g.disk.receipts.set(k,g.root.burnPermits.get(k))))}
  // receipt authenticity is a qualified external-owner input, not metadata equality.
  action archive(k,receipt,authentic) = all {authentic,g.root.burns.contains(k),not(g.root.results.contains(k)),
    A::a.outcomes.contains(k),A::a.receipts.get(k) == receipt,g.root.burnPermits.get(k) == receipt,baseStay,
    g' = g.with("root",g.root.with("results",g.root.results.union(Set(k))).with("receipts",g.root.receipts.set(k,receipt)))}
  action loseJournal(image) = all {A::restore(A::view),g' = g.with("disk",image).with("needsFence",true)}
  action fence(authentic) = all {authentic,A::restore(A::view),
    g' = g.with("root",g.root.with("epoch",g.root.epoch+1)).with("needsFence",false)}
  action confirm(k) = all {ready,g.root.results.contains(k),A::confirm(k,g.root.receipts.get(k)),g' = g}
  action materialize(k) = all {ready,g.root.results.contains(k),A::materialize(k),g' = g}
  action loseReply = all {baseStay,g' = g}
  action sourceStep = all {ready,A::sourceStep,g' = g}
  action anchor(k) = all {ready,A::anchor(k,A::view.source.settlement.get(k)),g' = g}
  val rootSafety = A::a.confirmed.forall(k => g.root.results.contains(k) and g.root.receipts.get(k) == A::a.confirmations.get(k)) and
    g.root.seals == A::a.accepted and g.root.seals.forall(k => g.root.permits.get(k) == A::a.permits.get(k)) and
    g.root.burns.forall(k => g.root.seals.contains(k) and g.root.burnPermits.get(k) == g.root.permits.get(k)) and
    A::a.outcomes.forall(k => g.root.burns.contains(k) and g.root.burnPermits.get(k) == A::a.receipts.get(k)) and
    g.root.results.forall(k => A::a.outcomes.contains(k) and g.root.receipts.get(k) == A::a.receipts.get(k))
  val onceSafety = messageKeys.forall(k => g.grantCount.get(k) <= 1 and g.burnCount.get(k) <= 1 and
    (g.root.grants.contains(k) iff g.grantCount.get(k) == 1) and (g.root.burns.contains(k) iff g.burnCount.get(k) == 1))
  val recoverySafety = ready implies g.root.results == A::a.outcomes
  val safety = A::safety and rootSafety and onceSafety and recoverySafety and g.violations == 0
  action step = {
    nondet k = messageKeys.oneOf()
    any {sourceStep,anchor(k),sealRoot(k),grant(k),burn(k),complete(k),archive(k,A::a.receipts.get(k),true),
      archive(k,A::blankPermit(k),false),loseJournal(emptyJournal),loseJournal(g.disk),fence(true),rebuild,confirm(k),materialize(k),loseReply}
  }
  action sourceInstall = all {ready,A::sourceInstall,g' = g}
  action sourceDelegate = all {ready,A::sourceDelegate,g' = g}
  action sourceWrite = all {ready,A::sourceWrite,g' = g}
  action sourcePrepare = all {ready,A::sourcePrepare,g' = g}
  action sourceEvidence = all {ready,A::sourceEvidence,g' = g}
  action sourceFinish = all {ready,A::sourceFinish,g' = g}
  action sourcePublish = all {ready,A::sourcePublish,g' = g}
  action sourceRetire = all {ready,A::sourceRetire,g' = g}
  action sourceClose = all {ready,A::sourceClose,g' = g}
  action sourceObserve = all {ready,A::sourceObserve,g' = g}
  action sourceUsage = all {ready,A::sourceUsage,g' = g}
  action sourceSettle = all {ready,A::sourceSettle,g' = g}
  action decision = init.then(rebuild).then(sourceInstall).then(rebuild).then(sourceDelegate).then(rebuild).then(sourceWrite).then(rebuild).then(sourcePrepare).then(rebuild).then(sourceEvidence).then(rebuild).then(sourceFinish).then(rebuild).then(sourcePublish).then(rebuild).then(sourceRetire).then(rebuild).then(sourceClose).then(rebuild).then(sourceObserve).then(rebuild).then(sourceUsage).then(rebuild).then(sourceSettle).then(rebuild)
  action anchored = decision.then(anchor(0)).then(rebuild)
  action sealed = anchored.then(sealRoot(0)).then(rebuild)
  action granted = sealed.then(grant(0))
  action burned = granted.then(burn(0))
  action applied = burned.then(complete(0))
  action archived = applied.then(archive(0,A::a.receipts.get(0),true)).then(rebuild)
  action finalized = archived.then(confirm(0)).then(rebuild).then(materialize(0)).then(rebuild)
  run sealReplyLostTest = sealed.then(loseReply).then(sealRoot(0).fail())
  run grantReplyLostTest = granted.then(loseReply).then(rebuild).then(grant(0).fail())
  run burnReplyLostTest = burned.then(loseReply).then(burn(0).fail())
  run lossBeforeBurnBlocksOldCapTest = granted.then(loseJournal(emptyJournal)).then(burn(0).fail())
  run fenceRejectsHeldOldCapTest = granted.then(loseJournal(emptyJournal)).then(fence(true)).then(rebuild).then(burn(0).fail())
  run restartCannotRegrantTest = granted.then(loseJournal(emptyJournal)).then(fence(true)).then(rebuild).then(grant(0).fail())
  run unknownBurnBlocksRebuildTest = burned.then(loseJournal(emptyJournal)).then(fence(true)).then(rebuild.fail())
  run unknownBurnBlocksConfirmationTest = burned.then(confirm(0).fail())
  run appliedUnarchivedBlocksRebuildTest = applied.then(loseJournal(emptyJournal)).then(fence(true)).then(rebuild.fail())
  run lostLocalResultNeedsAuthenticReceiptTest = applied.then(loseJournal(emptyJournal)).then(fence(true))
    .then(archive(0,A::a.receipts.get(0),false).fail())
  run pendingOriginalCompletesAfterFenceTest = burned.then(loseJournal(emptyJournal)).then(fence(true)).then(complete(0))
    .then(archive(0,A::a.receipts.get(0),true)).then(rebuild).expect(safety and A::a.writes.get(0) == 1)
  run authenticLateReceiptRebuildsTest = applied.then(loseJournal(emptyJournal)).then(fence(true))
    .then(archive(0,A::a.receipts.get(0),true)).then(rebuild).then(confirm(0)).then(rebuild).then(materialize(0)).then(rebuild).expect(safety)
  run archivedResultSurvivesMixedDiskTest = archived.then(loseJournal(emptyJournal)).then(fence(true)).then(rebuild)
    .expect(safety and g.disk == g.root and A::a.writes.get(0) == 1)
  run wrongReceiptRejectedTest = applied.then(archive(0,A::a.receipts.get(0).with("fence",999),true).fail())
  run missingActualOutcomeRejectedTest = burned.then(archive(0,g.root.burnPermits.get(0),true).fail())
  run archiveReplyLostTest = archived.then(loseReply).then(archive(0,A::a.receipts.get(0),true).fail())
  run duplicateCompleteRejectedTest = applied.then(complete(0).fail())
  run unqualifiedBarrierRejectedTest = granted.then(loseJournal(emptyJournal)).then(fence(false).fail())
  run fullClosureTest = finalized.expect(safety and A::a.writes.get(0) == 1)
  run sealedJournalLossDoesNotReacceptTest = sealed.then(loseJournal(emptyJournal)).then(fence(true)).then(rebuild).then(sealRoot(0).fail())
  run forgedLocalOutcomeCannotCloseUnknownTest = burned.then(loseJournal(g.root.with("results",Set(0))
    .with("receipts",g.root.receipts.set(0,g.root.burnPermits.get(0))))).then(fence(true)).then(rebuild.fail())
  run wrongAccountReceiptRejectedTest = applied.then(archive(0,A::a.receipts.get(0).with("request",
    A::a.receipts.get(0).request.with("usage",A::a.receipts.get(0).request.usage.with("account",999))),true).fail())
  run wrongLineageReceiptRejectedTest = applied.then(archive(0,A::a.receipts.get(0).with("request",
    A::a.receipts.get(0).request.with("lineage",999)),true).fail())
  run wrongAmountReceiptRejectedTest = applied.then(archive(0,A::a.receipts.get(0).with("request",
    A::a.receipts.get(0).request.with("usage",A::a.receipts.get(0).request.usage.with("amount",999))),true).fail())
  // Excluded rules retain ghost observations so forbidden effects are observable.
  action forgetIndependentRoot(k) = all {A::forgetGateRows(k),g' = initial.with("grantCount",g.grantCount).with("burnCount",g.burnCount)}
  action replayIssuedCap(k) = all {baseStay,g' = g.with("caps",g.caps.union(Set(k))).with("capEpoch",g.capEpoch.set(k,g.root.epoch))
    .with("grantCount",g.grantCount.set(k,g.grantCount.get(k)+1))}
  action staleCapBypass(k) = all {baseStay,g.caps.contains(k),g.capEpoch.get(k) != g.root.epoch,
    g' = g.with("violations",g.violations+1)}
  action inventResult(k) = all {baseStay,g' = g.with("root",g.root.with("results",g.root.results.union(Set(k)))
    .with("receipts",g.root.receipts.set(k,g.root.burnPermits.get(k))))}
  action recoverUnknown = all {A::sync,g' = g.with("disk",g.root).with("violations",g.violations+1)}
  action refundUnknown(k) = all {A::releaseUnknownBudget(k),g' = g}
  run allRootsRollbackCounterexampleTest = applied.then(forgetIndependentRoot(0)).then(rebuild).then(sealRoot(0)).then(rebuild)
    .then(grant(0)).then(burn(0)).then(complete(0)).expect(not(safety) and A::a.writes.get(0) == 2)
  run reissueFromStatusCounterexampleTest = granted.then(replayIssuedCap(0)).expect(not(onceSafety))
  run staleHeldCapCounterexampleTest = granted.then(loseJournal(emptyJournal)).then(fence(true)).then(rebuild)
    .then(staleCapBypass(0)).expect(not(safety))
  run syntheticResultCounterexampleTest = burned.then(inventResult(0)).expect(not(rootSafety))
  run absenceAsUnusedCounterexampleTest = burned.then(loseJournal(emptyJournal)).then(fence(true)).then(recoverUnknown).expect(not(safety))
  run unknownRefundCounterexampleTest = burned.then(refundUnknown(0)).expect(not(A::chainSafety))
}
