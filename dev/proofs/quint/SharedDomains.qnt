// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

// Finite executable instance; arbitrary-family no-split/conservation is in Lean.
// Native atomicity, authentic source identities and final transport custody are
// refinement premises. An all-copy rollback is outside this state machine.
module SharedDomains {
  val families=Set(0,1,2)
  type State={root:int->int,hroot:int->int,held:int->int,claims:Set[int],history:Set[int],spent:Set[int],
    epoch:int,permit:int->int,calls:int->int,owner:int,permitOwner:int->int,active:Set[int],merged:bool,receipt:bool}
  var s:State
  val initial={root:Map(0->0,1->0,2->2),hroot:Map(0->0,1->0,2->2),held:Map(0->0,1->0,2->0),claims:Set(),history:Set(),spent:Set(),
    epoch:1,permit:Map(0->0,1->0,2->0),calls:Map(0->0,1->0,2->0),owner:1,permitOwner:Map(0->0,1->0,2->0),active:Set(),merged:false,receipt:false}
  def exposure(d:int):int=families.filter(f=>s.root.get(f)==d).fold(0,(n,f)=>n+s.held.get(f))
  val safety= s.root.get(0)==s.root.get(1) and s.hroot.get(0)==s.hroot.get(1) and
    families.forall(f=>s.calls.get(f)<=1 and (s.spent.contains(f) implies s.claims.contains(f)) and
      (s.claims.contains(f) implies s.held.get(f)==3 and s.history.contains(f)) and exposure(s.root.get(f))<=6) and
    s.active.forall(f=>s.permit.get(f)==s.epoch and s.permitOwner.get(f)==s.owner and
      s.active.forall(g=>f==g or (s.root.get(f)!=s.root.get(g) and s.hroot.get(f)!=s.hroot.get(g))))
  action init=s'=initial
  action reserve(f:int):bool=all{not(s.claims.contains(f)),s.active==Set(),exposure(s.root.get(f))+3<=6,
    s'=s.with("claims",s.claims.union(Set(f))).with("history",s.history.union(Set(f))).with("held",s.held.set(f,3))}
  action consume(f:int):bool=all{s.claims.contains(f),not(s.spent.contains(f)),s.active==Set(),
    s'=s.with("spent",s.spent.union(Set(f))).with("permit",s.permit.set(f,s.epoch)).with("permitOwner",s.permitOwner.set(f,s.owner))}
  action finalGuard(f:int):bool=all{s.spent.contains(f),s.permit.get(f)==s.epoch,s.permitOwner.get(f)==s.owner,s.calls.get(f)==0,
    s.active.forall(g=>f!=g and s.root.get(f)!=s.root.get(g) and s.hroot.get(f)!=s.hroot.get(g)),s'=s.with("active",s.active.union(Set(f)))}
  action send(f:int):bool=all{s.active.contains(f),s.calls.get(f)==0,s'=s.with("calls",s.calls.set(f,1)).with("active",s.active.exclude(Set(f)))}
  action migrate=all{not(s.receipt),s.active==Set(),exposure(0)+exposure(2)<=6,s'=s.with("root",Map(0->2,1->2,2->2)).with("hroot",Map(0->2,1->2,2->2)).with("epoch",s.epoch+1).with("merged",true).with("receipt",true)}
  action rejectMigration=all{not(s.receipt),s.active==Set(),exposure(0)+exposure(2)>6,s'=s.with("receipt",true)}
  action replay=all{s.receipt,s'=s}
  action replyLoss=s'=s
  action restart=s'=s.with("owner",s.owner+1).with("active",Set())
  action alias= s'=s // aliases resolve to the original; never another claim slot
  action unsafeSplit=s'=s.with("root",s.root.set(1,1))
  action unsafeHistoryReset=s'=s.with("history",Set())
  action unsafeStaleUse(f:int):bool=s'=s.with("active",s.active.union(Set(f)))
  action unsafeRefund(f:int):bool=s'=s.with("held",s.held.set(f,0))
  action accepted=init.then(reserve(0)).then(consume(0))
  action step={nondet f=families.oneOf() any{reserve(f),consume(f),finalGuard(f),send(f),migrate,rejectMigration,replay,replyLoss,restart,alias}}
  run newFamilySharesOriginalBudgetTest=init.then(reserve(0)).then(reserve(1)).expect(safety and exposure(0)==6)
  run sharedFinalUseSerializesTest=accepted.then(reserve(1)).then(consume(1)).then(finalGuard(0)).then(finalGuard(1).fail())
  run migrationBlocksOldPermitTest=accepted.then(migrate).expect(safety and s.held.get(0)==3).then(finalGuard(0).fail())
  run migrationWaitsForActualUseTest=accepted.then(finalGuard(0)).then(migrate.fail())
  run migrationAfterActualUseTest=accepted.then(finalGuard(0)).then(send(0)).then(migrate).expect(safety)
  run overCapacityUnionKeepsOriginalDecisionTest=init.then(reserve(0)).then(reserve(1)).then(reserve(2)).then(rejectMigration).then(replyLoss).then(restart).then(replay).expect(safety and not(s.merged) and exposure(0)==6 and exposure(2)==3).then(migrate.fail())
  run oldWorkerAfterRestartTest=accepted.then(restart).then(finalGuard(0).fail())
  run lostReplyRecoveryTest=accepted.then(migrate).then(replyLoss).then(restart).then(replay).expect(safety and s.receipt and s.spent.contains(0)).then(consume(0).fail())
  run originalPendingCannotBeRenamedTest=accepted.then(alias).expect(safety).then(consume(0).fail())
  run domainSplitCounterexampleTest=init.then(reserve(0)).then(reserve(1)).then(unsafeSplit).expect(not(safety))
  run historyResetCounterexampleTest=accepted.then(migrate).then(unsafeHistoryReset).expect(not(safety))
  run stalePermitCounterexampleTest=accepted.then(migrate).then(unsafeStaleUse(0)).expect(not(safety))
  run unknownRefundCounterexampleTest=accepted.then(restart).then(unsafeRefund(0)).expect(not(safety))
}
