// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

// Finite executable instance; arbitrary-family no-split/conservation is in Lean.
// Native atomicity, authentic source identities and final transport custody are
// refinement premises. An all-copy rollback is outside this state machine.
module SharedDomains {
  val families=Set(0,1,2)
  type State={root:int->int,hroot:int->int,held:int->int,claims:Set[int],history:Set[int],spent:Set[int],
    epoch:int,permit:int->int,calls:int->int,owner:int,permitOwner:int->int,active:Set[int],merged:bool,receipt:bool,revoked:bool,policyPending:bool}
  var s:State
  val initial={root:Map(0->0,1->0,2->2),hroot:Map(0->0,1->0,2->2),held:Map(0->0,1->0,2->0),claims:Set(),history:Set(),spent:Set(),
    epoch:1,permit:Map(0->0,1->0,2->0),calls:Map(0->0,1->0,2->0),owner:1,permitOwner:Map(0->0,1->0,2->0),active:Set(),merged:false,receipt:false,revoked:false,policyPending:false}
  def exposure(d:int):int=families.filter(f=>s.root.get(f)==d).fold(0,(n,f)=>n+s.held.get(f))
  val safety= s.root.get(0)==s.root.get(1) and s.hroot.get(0)==s.hroot.get(1) and
    families.forall(f=>s.calls.get(f)<=1 and (s.spent.contains(f) implies s.claims.contains(f)) and
      (s.claims.contains(f) implies s.held.get(f)==3 and s.history.contains(f)) and exposure(s.root.get(f))<=6) and
    ((s.revoked or s.policyPending) implies s.active==Set()) and
    s.active.forall(f=>s.permit.get(f)==s.epoch and s.permitOwner.get(f)==s.owner and
      s.active.forall(g=>f==g or (s.root.get(f)!=s.root.get(g) and s.hroot.get(f)!=s.hroot.get(g))))
  pure def quotaAllowed(key:int,user:int,tenant:int,amount:int):bool=
    key+amount<=4 and user+amount<=4 and tenant+amount<=8
  run secondKeyCannotSpendUnknownUserQuotaTest=init.expect(
    quotaAllowed(0,0,0,4) and not(quotaAllowed(0,4,4,4)))
  run perKeyOnlyCounterexampleTest=init.expect(0+4<=4 and not(quotaAllowed(0,4,4,4)))
  pure def routeAllowed(bound:int, selected:int, rate:int, authoritative:int, spent:bool):bool=
    not(spent) and (bound==0 or bound==selected) and rate==authoritative
  run staleQuoteRejectsFirstSelectionTest=init.expect(not(routeAllowed(0,1,1,2,false)))
  run unknownCannotSelectAnotherModelTest=init.expect(not(routeAllowed(1,2,2,2,true)))
  pure def quoteReserve(currentVersion:int, offer:int, original:int):int=
    if (original != 0) original else if (currentVersion == offer) offer else 0
  run staleCatalogCannotOpenReservationTest=init.expect(quoteReserve(2,1,0)==0)
  run catalogReplayDoesNotRepriceOriginalTest=init.expect(quoteReserve(2,2,1)==1)
  pure def settlementRelease(retained:int, supplied:int, terminal:bool, applied:bool):int=
    if (terminal and not(applied) and retained==supplied) 3 else 0
  run formulaChangeKeepsOriginalSettlementTest=init.expect(settlementRelease(1,2,true,false)==0 and settlementRelease(1,1,true,false)==3)
  run unknownAndDuplicateTariffReleaseTest=init.expect(settlementRelease(1,1,false,false)==0 and settlementRelease(1,1,true,true)==0)
  action init=s'=initial
  action reserve(f:int):bool=all{not(s.claims.contains(f)),s.active==Set(),exposure(s.root.get(f))+3<=6,
    s'=s.with("claims",s.claims.union(Set(f))).with("history",s.history.union(Set(f))).with("held",s.held.set(f,3))}
  action consume(f:int):bool=all{s.claims.contains(f),not(s.spent.contains(f)),s.active==Set(),
    s'=s.with("spent",s.spent.union(Set(f))).with("permit",s.permit.set(f,s.epoch)).with("permitOwner",s.permitOwner.set(f,s.owner))}
  action finalGuard(f:int):bool=all{not(s.revoked),not(s.policyPending),s.spent.contains(f),s.permit.get(f)==s.epoch,s.permitOwner.get(f)==s.owner,s.calls.get(f)==0,
    s.active.forall(g=>f!=g and s.root.get(f)!=s.root.get(g) and s.hroot.get(f)!=s.hroot.get(g)),s'=s.with("active",s.active.union(Set(f)))}
  action send(f:int):bool=all{s.active.contains(f),s.calls.get(f)==0,s'=s.with("calls",s.calls.set(f,1)).with("active",s.active.exclude(Set(f)))}
  action migrate=all{not(s.receipt),s.active==Set(),exposure(0)+exposure(2)<=6,s'=s.with("root",Map(0->2,1->2,2->2)).with("hroot",Map(0->2,1->2,2->2)).with("epoch",s.epoch+1).with("merged",true).with("receipt",true)}
  action rejectMigration=all{not(s.receipt),s.active==Set(),exposure(0)+exposure(2)>6,s'=s.with("receipt",true)}
  action replay=all{s.receipt,s'=s}
  action replyLoss=s'=s
  action restart=s'=s.with("owner",s.owner+1).with("active",Set())
  action alias= s'=s // aliases resolve to the original; never another claim slot
  action unsafeMutationDuringSend=s'=s.with("epoch",s.epoch+1)
  action unsafeSplit=s'=s.with("root",s.root.set(1,1))
  action unsafeHistoryReset=s'=s.with("history",Set())
  action unsafeStaleUse(f:int):bool=s'=s.with("active",s.active.union(Set(f)))
  action unsafeRefund(f:int):bool=s'=s.with("held",s.held.set(f,0))
  action accepted=init.then(reserve(0)).then(consume(0))
  action revoke=all{s.active==Set(),not(s.revoked),s'=s.with("revoked",true)}
  action stagePolicy=all{s.active==Set(),not(s.policyPending),not(s.revoked),s'=s.with("policyPending",true)}
  action finalizePolicy=all{s.policyPending,s.active==Set(),s'=s.with("policyPending",false).with("revoked",true)}
  action unsafeStageOverWriter=s'=s.with("policyPending",true)
  action step={nondet f=families.oneOf() any{reserve(f),consume(f),finalGuard(f),send(f),migrate,rejectMigration,replay,replyLoss,restart,alias,revoke,stagePolicy,finalizePolicy}}
  run reviewedStagingWaitsForWriterTest=accepted.then(finalGuard(0)).then(stagePolicy.fail())
  run stagedPublicationRetainsUnknownAfterRestartTest=accepted.then(finalGuard(0)).then(send(0)).then(stagePolicy)
    .then(replyLoss).then(restart).expect(safety and s.policyPending and s.held.get(0)==3 and s.history.contains(0))
    .then(finalizePolicy).then(finalGuard(0).fail())
  run stagedPublicationBlocksFreshFinalUseTest=accepted.then(stagePolicy).then(finalGuard(0).fail())
  run stagingOvertakesWriterCounterexampleTest=accepted.then(finalGuard(0)).then(unsafeStageOverWriter).expect(not(safety))
  run revocationBeforeUnionRecoveryTest=accepted.then(revoke).then(migrate).then(replyLoss).then(restart).then(replay).expect(safety and s.revoked and s.held.get(0)==3).then(finalGuard(0).fail())
  run revocationAfterUnionRecoveryTest=accepted.then(migrate).then(replyLoss).then(revoke).then(restart).then(replay).expect(safety and s.revoked and s.history.contains(0)).then(finalGuard(0).fail())
  run ignoreRevocationCounterexampleTest=accepted.then(revoke).then(unsafeStaleUse(0)).expect(not(safety))
  run newFamilySharesOriginalBudgetTest=init.then(reserve(0)).then(reserve(1)).expect(safety and exposure(0)==6)
  run sharedFinalUseSerializesTest=accepted.then(reserve(1)).then(consume(1)).then(finalGuard(0)).then(finalGuard(1).fail())
  run migrationBlocksOldPermitTest=accepted.then(migrate).expect(safety and s.held.get(0)==3).then(finalGuard(0).fail())
  run migrationWaitsForActualUseTest=accepted.then(finalGuard(0)).then(migrate.fail())
  run migrationAfterActualUseTest=accepted.then(finalGuard(0)).then(send(0)).then(migrate).expect(safety)
  run concurrentMutationCASAfterSendTest=accepted.then(finalGuard(0))
    .then(send(0)).then(migrate).then(revoke)
    .then(replyLoss).then(restart).then(replay)
    .expect(safety and s.calls.get(0)==1 and s.held.get(0)==3 and s.history.contains(0))
    .then(finalGuard(0).fail())
  run revocationWaitsForActualUseTest=accepted.then(finalGuard(0)).then(revoke.fail())
  run staleMigrationCASAfterWinnerTest=accepted.then(finalGuard(0)).then(send(0)).then(migrate).then(migrate.fail())
  run stalePolicyCASAfterWinnerTest=accepted.then(finalGuard(0)).then(send(0)).then(revoke).then(revoke.fail())
  run mutationOvertakesWriterCounterexampleTest=accepted.then(finalGuard(0)).then(unsafeMutationDuringSend).expect(not(safety))
  run overCapacityUnionKeepsOriginalDecisionTest=init.then(reserve(0)).then(reserve(1)).then(reserve(2)).then(rejectMigration).then(replyLoss).then(restart).then(replay).expect(safety and not(s.merged) and exposure(0)==6 and exposure(2)==3).then(migrate.fail())
  run oldWorkerAfterRestartTest=accepted.then(restart).then(finalGuard(0).fail())
  run lostReplyRecoveryTest=accepted.then(migrate).then(replyLoss).then(restart).then(replay).expect(safety and s.receipt and s.spent.contains(0)).then(consume(0).fail())
  run originalPendingCannotBeRenamedTest=accepted.then(alias).expect(safety).then(consume(0).fail())
  run domainSplitCounterexampleTest=init.then(reserve(0)).then(reserve(1)).then(unsafeSplit).expect(not(safety))
  run historyResetCounterexampleTest=accepted.then(migrate).then(unsafeHistoryReset).expect(not(safety))
  run stalePermitCounterexampleTest=accepted.then(migrate).then(unsafeStaleUse(0)).expect(not(safety))
  run unknownRefundCounterexampleTest=accepted.then(restart).then(unsafeRefund(0)).expect(not(safety))

  run committedUnionLostReplyKeepsBothOriginalsTest =
    accepted.then(reserve(1)).then(consume(1)).then(migrate).then(replyLoss).then(restart).then(replay)
      .expect(safety and exposure(2)==6 and s.history.contains(0) and s.history.contains(1) and
        s.spent.contains(0) and s.spent.contains(1))
      .then(finalGuard(1).fail())
  run lateMigrationReplyCannotRestoreOldOwnerTest =
    accepted.then(migrate).then(restart).then(replyLoss).then(replay)
      .expect(safety and s.calls.get(0)==0 and s.held.get(0)==3)
      .then(finalGuard(0).fail())
  run partialOriginalSendUnionNeverReopensClaimTest =
    accepted.then(finalGuard(0)).then(send(0)).then(migrate).then(replyLoss).then(restart).then(replay)
      .expect(safety and s.calls.get(0)==1 and s.history.contains(0) and s.held.get(0)==3)
      .then(consume(0).fail())
}
