// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

module LlmWalActivation {
  import LlmAccountCommit as A from "./LlmAccountCommit"
  type Receipt={head:A::Image,journal:List[A::Record],epoch:int,sourceGeneration:int}
  type Wal={records:List[A::Record],candidates:Set[A::Record],receipt:Receipt,haveReceipt:bool,active:bool,sourceQualified:bool}
  var w:Wal
  pure val zero={head:A::genesis,journal:List(),epoch:0,sourceGeneration:0}
  pure val initial={records:List(),candidates:Set(),receipt:zero,haveReceipt:true,active:true,sourceQualified:true}
  pure def frame(p)={proposal:p,after:A::post(p.before,p.transaction),epoch:p.worker}
  pure val f0=frame(A::p0)
  def view={head:A::a.anchor,journal:A::a.journal,epoch:A::a.epoch,sourceGeneration:A::a.sourceGeneration}
  def current=w.haveReceipt and w.receipt==view
  def complete=w.records.length()>=A::a.journal.length() and A::a.journal.indices().forall(i=>w.records.nth(i)==A::a.journal.nth(i))
  action init=all {A::init,w'=initial}
  action prepared=all {A::prepared,w'=initial}
  action flush(p,durable)=all {A::a.prepared.contains(p),A::gate(p),w.records==A::a.journal,durable,A::loseReply,
    w'=w.with("records",w.records.append(frame(p)))}
  action submit(p,durable)=all {w.records.indices().exists(i=>w.records.nth(i)==frame(p)),A::a.prepared.contains(p),A::gate(p),durable,A::loseReply,
    w'=w.with("candidates",w.candidates.union(Set(frame(p)))).with("active",false)}
  action anchor(p,policy,durable)=all {w.candidates.contains(frame(p)),A::commit(p,policy,durable),w'=w.with("active",false)}
  action rotate=all {A::rotate,w'=w.with("active",false)}
  action conflict=all {A::conflictUsage,w'=w.with("active",false).with("sourceQualified",false)}
  action restoreWal(records)=all {A::loseReply,w'=w.with("records",records).with("active",false)}
  action repair(authentic)=all {authentic,A::loseReply,w'=w.with("records",A::a.journal).with("active",false)}
  action observe(authentic)=all {authentic,A::loseReply,w'=w.with("receipt",view).with("haveReceipt",true)}
  action install=all {current,complete,not(A::a.qualified),A::restore(A::a.anchor),w'=w.with("active",false)}
  action restoreImage(image)=all {A::restore(image),w'=w.with("active",false)}
  action activate(authentic)=all {current,complete,authentic,w.sourceQualified,A::a.local==A::a.anchor,
    if (A::a.qualified) A::loseReply else A::recover(true),w'=w.with("active",true)}
  action prepareNext(p)=all {w.active,A::prepare(p),w'=w}
  action loseReply=all {A::loseReply,w'=w.with("haveReceipt",false).with("active",false)}
  action lateFull=all {A::lateFull,w'=w}
  action flushed=prepared.then(flush(A::p0,true))
  action submitted=flushed.then(submit(A::p0,true))
  action anchored=submitted.then(anchor(A::p0,true,true))
  action replayed=anchored.then(observe(true)).then(repair(true)).then(install)
  action activated=replayed.then(activate(true))
  action truncated=anchored.then(restoreWal(List()))
  val live=w.active implies w.sourceQualified and A::a.qualified and A::a.local==A::a.anchor and current and complete
  val candidateSound=w.candidates.forall(r=>r.after==A::post(r.proposal.before,r.proposal.transaction))
  val anchoredOnly=A::a.journal.indices().forall(i=>w.candidates.contains(A::a.journal.nth(i)))
  val safety=anchoredOnly and A::safety and live and candidateSound
  action step={nondet p=A::a.prepared.union(Set(A::p0,A::p1)).oneOf()
    any {prepareNext(p),flush(p,true),submit(p,true),anchor(p,true,true),rotate,conflict,restoreWal(List()),
      repair(true),observe(true),install,restoreImage(A::genesis),restoreImage(A::a.anchor),activate(true),loseReply,lateFull}}
  run walDurableDoesNotReleaseBudgetTest=flushed.expect(safety and A::a.anchor==A::genesis and A::a.everReleased==0)
  run candidateAcceptanceDoesNotReleaseBudgetTest=submitted.expect(safety and A::a.anchor==A::genesis and A::a.everReleased==0 and not(w.active))
  run walFlushRequiresDurableRecordTest=prepared.then(flush(A::p0,false).fail())
  run candidateRequiresCompleteWalBodyTest=prepared.then(submit(A::p0,true).fail())
  run candidateRequiresDurableAcceptanceTest=flushed.then(submit(A::p0,false).fail())
  run anchorRequiresAcceptedOriginalBodyTest=flushed.then(anchor(A::p0,true,true).fail())
  run anchorRequiresDurableCommitTest=submitted.then(anchor(A::p0,true,false).fail())
  run anchorRechecksPolicyTest=submitted.then(anchor(A::p0,false,true).fail())
  run oldWorkerCannotAnchorAcceptedCandidateTest=submitted.then(rotate).then(observe(true)).then(repair(true)).then(install).then(activate(true)).then(anchor(A::p0,true,true).fail())
  run sourceChangeBlocksAcceptedCandidateTest=submitted.then(conflict).then(anchor(A::p0,true,true).fail())
  run committedWithoutReplyCannotActivateTest=anchored.then(loseReply).then(activate(true).fail())
  run committedLostReplyCanRecoverSameResultTest=anchored.then(loseReply).then(observe(true)).then(repair(true)).then(install).then(activate(true))
    .expect(safety and A::a.everReleased==1 and A::a.journal.length()==1)
  run localWalLossCannotCancelPendingCandidateTest=submitted.then(restoreWal(List())).then(anchor(A::p0,true,true)).expect(safety and A::a.journal.length()==1 and not(w.active))
  run truncatedCommittedWalCannotActivateTest=truncated.then(observe(true)).then(activate(true).fail())
  run truncatedWalCanRepairFromAuthorityTest=truncated.then(observe(true)).then(repair(true)).then(install).then(activate(true)).expect(safety and A::a.everReleased==1)
  run oldImageWithNewWalCannotActivateTest=anchored.then(observe(true)).then(restoreImage(A::genesis)).then(activate(true).fail())
  run equalRevisionWrongWalBodyRejectedTest=anchored.then(restoreWal(List(f0.with("proposal",A::p0.with("transaction",A::tx0.with("usage",1))))))
    .then(observe(true)).then(install.fail())
  run repairRequiresAuthenticCurrentPrefixTest=truncated.then(repair(false).fail())
  run observationRequiresAuthenticCurrentPrefixTest=anchored.then(observe(false).fail())
  run oldConfirmationAfterRotateCannotActivateTest=activated.then(rotate).then(repair(true)).then(install.fail())
  run lateReceiptCannotMintAnotherBalanceDeltaTest=activated.then(lateFull).expect(safety and A::a.everReleased==1 and A::a.journal.length()==1)
  run originalCandidateCannotCommitTwiceTest=activated.then(anchor(A::p0,true,true).fail())
  run snapshotDoesNotEraseOriginalApplicationTest=activated.then(rotate).then(restoreImage(A::genesis)).then(restoreWal(List())).then(observe(true))
    .then(repair(true)).then(install).then(activate(true)).then(anchor(A::p0,true,true).fail())
  run uncommittedWalTailDoesNotBecomeFinancialRecordTest=flushed.expect(safety and w.records.length()==1 and A::a.journal.length()==0 and A::a.anchor.balance.held==5)
  run oldCandidateCannotUseNewApplicationIdTest=submitted.then(anchor(A::p0.with("transaction",A::tx0.with("id",999)),true,true).fail())
  run recoveryDoesNotRepeatFinancialDeltaTest=activated.expect(safety and A::a.journal.length()==1 and A::a.everReleased==1)
  run sourceConflictBlocksActivationTest=activated.then(conflict).then(observe(true)).then(activate(true).fail())
  run newOwnerCanReproposeSameOriginalApplicationTest=submitted.then(rotate).then(observe(true)).then(repair(true)).then(install).then(activate(true))
    .then(prepareNext(A::p0.with("worker",1))).then(flush(A::p0.with("worker",1),true)).then(submit(A::p0.with("worker",1),true))
    .then(anchor(A::p0.with("worker",1),true,true)).expect(safety and A::a.everReleased==1 and A::a.journal.length()==1)
  run lateCommitInvalidatesAlreadyActivatedOldHeadTest=submitted.then(observe(true)).then(activate(true)).expect(safety and w.active)
    .then(anchor(A::p0,true,true)).expect(safety and not(w.active)).then(activate(true).fail())
  run lateCommitBetweenRepairAndInstallTest=submitted.then(restoreWal(List())).then(observe(true)).then(repair(true))
    .then(anchor(A::p0,true,true)).then(install.fail())
  action unsafeCandidateConfirmation=all {A::loseReply,
    w'=w.with("receipt",{head:f0.after,journal:List(f0),epoch:A::a.epoch,sourceGeneration:A::a.sourceGeneration})
      .with("haveReceipt",true).with("active",true)}
  action unsafeRequalifyActivate=all {A::unsafeRecover,w'=w.with("active",true)}
  action unsafeActivate=all {A::loseReply,w'=w.with("active",true)}
  action unsafeWalCredit=all {A::unsafeApply(A::p0),w'=w}
  action unsafeDropAnchor=all {A::unsafeRollback,w'=w}
  action unsafeRetry=all {A::unsafeApply(A::p0),w'=w.with("active",false)}
  run walAsMoneyWalCounterexampleTest=flushed.then(unsafeWalCredit).expect(not(live))
  run acceptanceAsConfirmationWalCounterexampleTest=submitted.then(unsafeCandidateConfirmation).expect(not(live))
  run truncatedWalWalCounterexampleTest=activated.then(restoreWal(List())).then(unsafeActivate).expect(not(live))
  run oldSnapshotWalCounterexampleTest=activated.then(rotate).then(restoreImage(A::genesis)).then(unsafeActivate).expect(not(live))
  run staleConfirmationWalCounterexampleTest=activated.then(rotate).then(repair(true)).then(unsafeRequalifyActivate).expect(not(live))
  run lostReplyRetryWalCounterexampleTest=activated.then(loseReply).then(unsafeRetry).expect(not(A::unique))
  run sharedRollbackWalCounterexampleTest=activated.then(unsafeDropAnchor).expect(not(A::conservation))
  run forgedWalBodyWalCounterexampleTest=activated.then(restoreWal(List(f0.with("proposal",A::p0.with("transaction",A::tx0.with("usage",1))))))
    .then(unsafeActivate).expect(not(live))
  run oldCandidateRetryWalCounterexampleTest=activated.then(rotate).then(unsafeRetry).expect(not(A::unique))
  run unconfirmedTailRefundWalCounterexampleTest=flushed.then(loseReply).then(unsafeWalCredit).expect(not(anchoredOnly))
}
