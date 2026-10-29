module LlmExecutionReconciliation {
  import LlmExecutorOffer as X from "./LlmExecutorOffer"
  type Key={root:int,claim:int,profile:int,budget:int,history:int,slot:int,lo:int,hi:int}
  type Decision={key:Key,kind:int,cut:int,burns:int,calls:int,submitted:bool}
  type Application={decision:Decision,worker:int,epoch:int}
  type Payment={decision:Decision,amount:int,released:int,worker:int,epoch:int}
  type Reconciliation={epoch:int,qualified:bool,sealed:bool,decisions:List[Decision],source:List[Application],usage:int,
    payments:List[Payment],released:int,terminalEvidence:bool,usageEvidence:bool,conflict:bool,dispatchView:int,sourceView:int,accountView:int}
  var e:Reconciliation
  pure val key={root:10,claim:11,profile:30,budget:5,history:9,slot:11,lo:0,hi:4}
  pure val initial={epoch:0,qualified:true,sealed:false,decisions:List(),source:List(),usage:-1,payments:List(),released:0,
    terminalEvidence:false,usageEvidence:false,conflict:false,dispatchView:0,sourceView:0,accountView:0}
  def current(kind)={key:key,kind:kind,cut:e.epoch,burns:X::s.burns.size(),calls:X::s.laneCalls,submitted:X::s.submitted}
  pure val absent={key:key,kind:1,cut:0,burns:0,calls:0,submitted:false}
  pure val executed={key:key,kind:2,cut:0,burns:1,calls:1,submitted:true}
  action init=all {X::enqueued,e'=initial}
  action inert=all {X::timeout,e'=e}
  action seal(worker,complete)=all {worker==e.epoch,e.qualified,not(e.conflict),complete,X::timeout,e'=e.with("sealed",true)}
  action decide(kind,worker,complete)=all {e.sealed,e.qualified,not(e.conflict),worker==e.epoch,complete,e.decisions.length()==0,
    if (kind==1) X::s.burns.size()==0 and not(X::s.submitted) and X::s.laneCalls==0
      else kind==2 and X::s.submitted and X::s.laneCalls==1 and e.terminalEvidence,
    X::timeout,e'=e.with("decisions",List(current(kind))).with("dispatchView",1)}
  action sourceCAS(d,worker)=all {e.qualified,not(e.conflict),worker==e.epoch,e.decisions==List(d),e.source.length()==0,
    X::timeout,e'=e.with("source",List({decision:d,worker:worker,epoch:e.epoch})).with("sourceView",1)}
  action usageCAS(d,amount,worker,authentic)=all {worker==e.epoch,e.qualified,not(e.conflict),e.decisions==List(d),e.source.length()==1,e.usage<0,
    amount>=0,amount<=3,authentic,if (d.kind==1) amount==0 else e.usageEvidence,
    X::timeout,e'=e.with("usage",amount)}
  action accountCAS(d,worker,authentic)=all {e.qualified,not(e.conflict),worker==e.epoch,e.decisions==List(d),e.source.length()==1,
    e.source.nth(0).decision==d,e.usage>=0,e.payments.length()==0,authentic,X::timeout,
    e'=e.with("payments",List({decision:d,amount:e.usage,released:3-e.usage,worker:worker,epoch:e.epoch})).with("released",3-e.usage).with("accountView",1)}
  action terminalReceipt(authentic)=all {authentic,X::s.submitted,X::s.laneCalls==1,X::timeout,e'=e.with("terminalEvidence",true)}
  action finalUsageReceipt(authentic)=all {authentic,e.terminalEvidence,X::timeout,e'=e.with("usageEvidence",true)}
  action lateFull=all {X::fullReceipt(X::t0,4,true),e'=e}
  action latePartial=all {X::partial(X::t0,2),e'=e}
  action conflict=all {X::timeout,e'=e.with("qualified",false).with("conflict",true)}
  action restart=all {X::restart,e'=e.with("epoch",e.epoch+1).with("qualified",false).with("dispatchView",-1).with("sourceView",-1).with("accountView",-1)}
  action recover(dispatchExact,sourceExact,accountExact)=all {not(e.qualified),not(e.conflict),dispatchExact,sourceExact,accountExact,e.dispatchView==e.decisions.length(),e.sourceView==e.source.length(),e.accountView==e.payments.length(),
    X::timeout,e'=e.with("qualified",true)}
  action restoreDispatch(pos)=all {not(e.qualified),pos>=0,pos<=e.decisions.length(),X::timeout,e'=e.with("dispatchView",pos)}
  action restoreSource(pos)=all {not(e.qualified),pos>=0,pos<=e.source.length(),X::timeout,e'=e.with("sourceView",pos)}
  action restoreAccount(pos)=all {not(e.qualified),pos>=0,pos<=e.payments.length(),X::timeout,e'=e.with("accountView",pos)}
  action restoreAll=restoreDispatch(e.decisions.length()).then(restoreSource(e.source.length())).then(restoreAccount(e.payments.length()))
  action drive=all {not(e.sealed),X::step,e'=e}
  action burned=all {X::burned,e'=initial}
  action offered=all {X::offered,e'=initial}
  action negativeDecision=init.then(seal(0,true)).then(decide(1,0,true))
  action terminalDecision=offered.then(seal(0,true)).then(terminalReceipt(true)).then(decide(2,0,true))
  action sourceApplied=terminalDecision.then(sourceCAS(executed,0))
  action usageApplied=sourceApplied.then(finalUsageReceipt(true)).then(usageCAS(executed,2,0,true))
  action paid=usageApplied.then(accountCAS(executed,0,true))
  val unique=e.decisions.length()<=1 and e.source.length()<=1 and e.payments.length()<=1
  val negativeSound=e.decisions.indices().forall(i=>{val d=e.decisions.nth(i)
    d.kind!=1 or (d.burns==0 and d.calls==0 and not(d.submitted) and X::s.burns.size()==0 and X::s.laneCalls==0)})
  val positiveSound=e.decisions.indices().forall(i=>{val d=e.decisions.nth(i)
    d.kind!=2 or (d.calls==1 and d.submitted and e.terminalEvidence)})
  val original=e.decisions.indices().forall(i=>e.decisions.nth(i).key==key) and
    e.source.indices().forall(i=>e.decisions==List(e.source.nth(i).decision)) and
    e.payments.indices().forall(i=>e.decisions==List(e.payments.nth(i).decision))
  val evidence=e.usage<0 or (e.source.length()==1 and e.decisions.length()==1 and
    (if (e.decisions.nth(0).kind==1) e.usage==0 else e.usageEvidence))
  val held=e.payments.length()==0 implies e.released==0
  val settled=e.payments.indices().forall(i=>{val p=e.payments.nth(i)
    p.worker==p.epoch and e.source.length()==1 and e.usage>=0 and p.amount==e.usage and p.released+e.usage==3 and e.released==p.released})
  val qualifiedViews=e.qualified implies e.dispatchView==e.decisions.length() and e.sourceView==e.source.length() and e.accountView==e.payments.length()
  val safety=qualifiedViews and X::safety and unique and negativeSound and positiveSound and original and evidence and held and settled
  action step={nondet kind=Set(1,2).oneOf() nondet amount=Set(0,2,3).oneOf()
    nondet d=e.decisions.indices().map(i=>e.decisions.nth(i)).union(Set(absent,executed)).oneOf()
    any {drive,seal(e.epoch,true),decide(kind,e.epoch,true),sourceCAS(d,e.epoch),usageCAS(d,amount,e.epoch,true),accountCAS(d,e.epoch,true),
      terminalReceipt(true),finalUsageReceipt(true),lateFull,latePartial,restart,restoreDispatch(e.decisions.length()),restoreSource(e.source.length()),restoreAccount(e.payments.length()),recover(true,true,true),conflict,inert}}
  run sourceZeroAfterActualOfferTest=offered.expect(X::s.sourceCalls==0 and X::s.laneCalls==1).then(seal(0,true)).then(decide(1,0,true).fail())
  run uncertainBurnCannotCertifyAbsenceTest=burned.then(seal(0,true)).then(decide(1,0,true).fail())
  run completeAbsenceCanResolveTest=negativeDecision.expect(safety).then(sourceCAS(absent,0)).then(usageCAS(absent,0,0,true)).then(accountCAS(absent,0,true)).expect(safety and e.released==3)
  run negativeNeedsClosedExecutionTest=init.then(decide(1,0,true).fail())
  run sealNeedsCompletePrefixTest=init.then(seal(0,false).fail())
  run decisionNeedsCompletePrefixTest=init.then(seal(0,true)).then(decide(1,0,false).fail())
  run sealedCannotDriveTest=negativeDecision.then(drive.fail())
  run rangeFullIsNotTerminalTest=offered.then(lateFull).then(seal(0,true)).then(decide(2,0,true).fail())
  run partialIsNotTerminalTest=offered.then(latePartial).then(seal(0,true)).then(decide(2,0,true).fail())
  run terminalIsNotFinalUsageTest=sourceApplied.then(usageCAS(executed,2,0,true).fail())
  run sourceTerminalDoesNotRefundTest=sourceApplied.expect(safety and e.released==0 and e.usage<0)
  run terminalRequiresAuthenticReceiptTest=offered.then(terminalReceipt(false).fail())
  run usageRequiresAuthenticReceiptTest=sourceApplied.then(finalUsageReceipt(false).fail())
  run meteredNeedsSourceApplicationTest=terminalDecision.then(finalUsageReceipt(true)).then(usageCAS(executed,2,0,true).fail())
  run accountRequiresSourceAndUsageTest=sourceApplied.then(accountCAS(executed,0,true).fail())
  run exactApplicationRejectsChangedClaimTest=terminalDecision.then(sourceCAS(executed.with("key",key.with("claim",12)),0).fail())
  run exactUsageRejectsChangedBudgetTest=sourceApplied.then(finalUsageReceipt(true)).then(usageCAS(executed.with("key",key.with("budget",6)),2,0,true).fail())
  run usageCannotExceedOriginalBoundTest=sourceApplied.then(finalUsageReceipt(true)).then(usageCAS(executed,4,0,true).fail())
  run negativeUsageMustBeZeroTest=negativeDecision.then(sourceCAS(absent,0)).then(usageCAS(absent,1,0,true).fail())
  run sourceLostReplyCannotApplyTwiceTest=sourceApplied.then(inert).then(sourceCAS(executed,0).fail())
  run accountLostReplyCannotApplyTwiceTest=paid.then(inert).then(accountCAS(executed,0,true).fail())
  run lateUsageCannotRepriceTest=paid.then(finalUsageReceipt(true)).then(usageCAS(executed,1,0,true).fail())
  run lateFullAfterPaymentIsDataTest=paid.then(lateFull).expect(safety and e.released==1 and e.payments.length()==1)
  run restartRetainsUnknownTest=offered.then(restart).expect(safety and e.released==0 and X::s.unknown and X::s.burns.size()==1)
  run oldWorkerCannotApplySourceTest=terminalDecision.then(restart).then(restoreAll).then(recover(true,true,true)).then(sourceCAS(executed,0).fail())
  run currentWorkerCanReconcileOldDecisionTest=terminalDecision.then(restart).then(restoreAll).then(recover(true,true,true)).then(sourceCAS(executed,1)).expect(safety)
  run mixedDispatchRecoveryRejectedTest=sourceApplied.then(restart).then(restoreAll).then(recover(false,true,true).fail())
  run mixedSourceRecoveryRejectedTest=sourceApplied.then(restart).then(restoreAll).then(recover(true,false,true).fail())
  run mixedAccountRecoveryRejectedTest=paid.then(restart).then(restoreAll).then(recover(true,true,false).fail())
  run conflictQuarantinesReleaseTest=usageApplied.then(conflict).then(accountCAS(executed,0,true).fail())
  run unknownCannotCloseOrRefundTest=offered.then(latePartial).then(inert).expect(safety and e.decisions.length()==0 and e.released==0)
  run rolledBackSourceCannotRecoverTest=sourceApplied.then(restart).then(restoreDispatch(1)).then(restoreSource(0)).then(restoreAccount(0)).then(recover(true,true,true).fail())
  run rolledBackAccountCannotRecoverTest=paid.then(restart).then(restoreDispatch(1)).then(restoreSource(1)).then(restoreAccount(0)).then(recover(true,true,true).fail())
  run rolledBackDispatchCannotRecoverTest=sourceApplied.then(restart).then(restoreDispatch(0)).then(restoreSource(1)).then(restoreAccount(0)).then(recover(true,true,true).fail())
  run restoredAccountCannotPayAgainTest=paid.then(restart).then(restoreAll).then(recover(true,true,true)).then(accountCAS(executed,1,true).fail())
  run oldWorkerCannotApplyUsageTest=sourceApplied.then(finalUsageReceipt(true)).then(restart).then(restoreAll).then(recover(true,true,true)).then(usageCAS(executed,2,0,true).fail())
  action unsafeNegative=all {X::timeout,e'=e.with("sealed",true).with("decisions",List(current(1)))}
  action unsafeTerminal=all {X::timeout,e'=e.with("decisions",List(current(2)))}
  action unsafeRefund=all {X::timeout,e'=e.with("released",3)}
  action unsafeSource(d)=all {X::timeout,e'=e.with("source",e.source.append({decision:d,worker:0,epoch:e.epoch}))}
  action unsafeUsage=all {X::timeout,e'=e.with("usage",0)}
  action unsafePay=all {X::timeout,e'=e.with("payments",e.payments.append({decision:executed,amount:0,released:3,worker:0,epoch:e.epoch})).with("released",3)}
  run sourceZeroReconciliationCounterexampleTest=offered.then(unsafeNegative).expect(not(negativeSound))
  run burnOnlyReconciliationCounterexampleTest=burned.then(unsafeNegative).expect(not(negativeSound))
  run fullAsTerminalReconciliationCounterexampleTest=offered.then(lateFull).then(unsafeTerminal).expect(not(positiveSound))
  run unknownRefundReconciliationCounterexampleTest=offered.then(unsafeRefund).expect(not(held))
  run duplicateSourceReconciliationCounterexampleTest=sourceApplied.then(unsafeSource(executed)).expect(not(unique))
  run changedClaimReconciliationCounterexampleTest=terminalDecision.then(unsafeSource(executed.with("key",key.with("claim",12)))).expect(not(original))
  run missingUsageReconciliationCounterexampleTest=sourceApplied.then(unsafePay).expect(not(settled))
  run lateUsageReconciliationCounterexampleTest=paid.then(unsafeUsage).expect(not(settled))
  run oldWorkerReconciliationCounterexampleTest=usageApplied.then(restart).then(unsafePay).expect(not(settled))
  run duplicatePaymentReconciliationCounterexampleTest=paid.then(unsafePay).expect(not(unique))
}
