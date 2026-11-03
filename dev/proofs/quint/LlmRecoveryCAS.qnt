// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

// Registry publication is an already qualified fixture; Lean composes actual source transitions.
module LlmRecoveryCAS {
  type Binding={operation:int,claim:int,commitment:int,input:int,budget:int,history:int,document:bool}
  type Cut={binding:Binding,revision:int,fence:int,policyGeneration:int}
  type Permit={id:int,binding:Binding,revision:int,fence:int,worker:int}
  type Request={id:int,permit:Permit,cut:Cut,kind:int}
  type Decision={request:Request,actual:Cut,allowed:bool,historyClear:bool}
  type CASState={binding:Binding,revision:int,fence:int,policyGeneration:int,allowed:bool,restricted:bool,
    readBinding:Binding,readRevision:int,readFence:int,readGeneration:int,hasBinding:bool,hasExecution:bool,hasPolicy:bool,
    permits:Set[Permit],requests:Set[Request],decisions:List[Decision],confirmations:List[Decision],ack:bool,
    spent:bool,calls:int,allocated:int,hold:int,usage:int,closed:bool,charged:bool}
  var s:CASState
  pure val original={operation:40,claim:11,commitment:20,input:10,budget:5,history:9,document:true}
  pure val initialCut={binding:original,revision:0,fence:0,policyGeneration:0}
  pure val permit0={id:0,binding:original,revision:0,fence:0,worker:0}
  pure val request0={id:0,permit:permit0,cut:initialCut,kind:0}
  pure val decision0={request:request0,actual:initialCut,allowed:true,historyClear:true}
  pure val emptyPermit={id:-1,binding:original,revision:-1,fence:-1,worker:-1}
  pure val emptyRequest={id:-1,permit:emptyPermit,cut:initialCut,kind:0}
  pure val initial={binding:original,revision:0,fence:0,policyGeneration:0,allowed:true,restricted:false,
    readBinding:original,readRevision:-1,readFence:-1,readGeneration:-1,hasBinding:false,hasExecution:false,hasPolicy:false,
    permits:Set(),requests:Set(),decisions:List(),confirmations:List(),ack:false,
    spent:false,calls:0,allocated:6,hold:6,usage:-1,closed:false,charged:false}
  def cut={binding:s.binding,revision:s.revision,fence:s.fence,policyGeneration:s.policyGeneration}
  def observedCut={binding:s.readBinding,revision:s.readRevision,fence:s.readFence,policyGeneration:s.readGeneration}
  def permit=s.permits.fold(emptyPermit,(a,b)=>if(b.id>a.id)b else a)
  def request=s.requests.fold(emptyRequest,(a,b)=>if(b.id>a.id)b else a)
  def current(q)=s.requests.contains(q) and q.cut==cut and s.allowed and not(s.restricted) and
    s.permits.contains(q.permit) and q.permit.binding==s.binding and q.permit.revision==s.revision and
    q.permit.fence==s.fence and q.permit.worker==s.fence and s.decisions.indices().forall(i=>s.decisions.nth(i).request.id!=q.id)
  action init=s'=initial
  action issuePermit=s'=s.with("permits",s.permits.union(Set({id:s.permits.size(),binding:s.binding,revision:s.revision,fence:s.fence,worker:s.fence})))
  action readBinding=s'=s.with("readBinding",s.binding).with("hasBinding",true)
  action readExecution=s'=s.with("readRevision",s.revision).with("readFence",s.fence).with("hasExecution",true)
  action readPolicy=s'=s.with("readGeneration",s.policyGeneration).with("hasPolicy",s.allowed and not(s.restricted))
  action restoreObservation(c)=s'=s.with("readBinding",c.binding).with("readRevision",c.revision).with("readFence",c.fence)
    .with("readGeneration",c.policyGeneration).with("hasBinding",true).with("hasExecution",true).with("hasPolicy",true)
  action prepare(p,kind)=all {s.hasBinding,s.hasExecution,s.hasPolicy,s.permits.contains(p),p.binding==s.readBinding,
    p.revision==s.readRevision,p.fence==s.readFence,
    s'=s.with("requests",s.requests.union(Set({id:s.requests.size(),permit:p,cut:observedCut,kind:kind})))}
  action policyChange(allowed)=s'=s.with("policyGeneration",s.policyGeneration+1).with("allowed",allowed).with("restricted",not(allowed))
  action ledgerWrite=s'=s.with("revision",s.revision+1)
  action restart=s'=s.with("fence",s.fence+1).with("revision",s.revision+1).with("ack",false)
  action consume(q,qualified)=all {current(q),q.kind==0,not(s.spent),qualified,
    s'=s.with("spent",true).with("calls",s.calls+1).with("revision",s.revision+1)
      .with("decisions",s.decisions.append({request:q,actual:cut,allowed:s.allowed,historyClear:not(s.restricted)}))}
  action loseReply=s'=s.with("ack",false)
  action confirm(d)=all {s.decisions.indices().exists(i=>s.decisions.nth(i)==d),s'=s.with("confirmations",s.confirmations.append(d)).with("ack",true)}
  action usage(amount,qualified)=all {s.spent,s.usage == -1,amount>=0,amount<=s.allocated,qualified,
    s'=s.with("usage",amount).with("closed",true).with("revision",s.revision+1)}
  action settle(q,qualified)=all {current(q),q.kind==1,s.spent,s.closed,s.usage>=0,not(s.charged),qualified,
    s'=s.with("charged",true).with("hold",0).with("revision",s.revision+1)
      .with("decisions",s.decisions.append({request:q,actual:cut,allowed:s.allowed,historyClear:not(s.restricted)}))}
  val exactCut=s.decisions.indices().forall(i=>{val d=s.decisions.nth(i)
    d.request.cut==d.actual and d.allowed and d.historyClear and d.actual.binding==original and
    d.request.permit.binding==original and d.request.permit.worker==d.actual.fence})
  val unique=s.decisions.indices().forall(i=>s.decisions.indices().forall(j=>i==j or s.decisions.nth(i).request.id!=s.decisions.nth(j).request.id))
  val originalBound=s.binding==original and s.allocated==6 and s.allocated<=20
  val accounting=s.calls<=1 and (s.spent implies s.calls==1) and (s.charged implies s.closed and s.usage>=0) and
    (s.usage == -1 implies s.hold==6)
  val safety=exactCut and unique and originalBound and accounting
  action step={nondet amount=0.to(6).oneOf()
    any {issuePermit,readBinding,readExecution,readPolicy,restoreObservation(initialCut),prepare(permit,0),prepare(permit,1),
      policyChange(false),policyChange(true),ledgerWrite,restart,consume(request,true),loseReply,confirm(decision0),usage(amount,true),settle(request,true)}}
  action observed=init.then(issuePermit).then(readBinding).then(readExecution).then(readPolicy)
  action prepared=observed.then(prepare(permit0,0))
  action committed=prepared.then(consume(request0,true))
  action restricted=prepared.then(policyChange(false))
  action restarted=prepared.then(restart)
  action unknown=committed.then(loseReply).then(restart)
  action refresh(kind)=issuePermit.then(readBinding).then(readExecution).then(readPolicy).then(prepare(permit,kind))
  run exactReadCASCanCommitTest=prepared.then(consume(request0,true)).expect(safety)
  run observationCannotConsumeTest=observed.then(consume(request0,true).fail())
  run readPolicyIsNotReservationTest=observed.then(policyChange(false)).then(prepare(permit0,0)).then(consume(request0,true).fail())
  run tornReadCannotCommitTest=init.then(issuePermit).then(readPolicy).then(policyChange(false)).then(readBinding).then(readExecution)
    .then(prepare(permit0,0)).then(consume(request0,true).fail())
  run policyABACannotCommitTest=prepared.then(policyChange(false)).then(policyChange(true)).then(consume(request0,true).fail())
  run externalHistoryWithoutLedgerWriteBlocksTest=restricted.expect(s.revision==0).then(consume(request0,true).fail())
  run ledgerWriteInvalidatesPermitTest=prepared.then(ledgerWrite).then(consume(request0,true).fail())
  run ownerRestartInvalidatesPermitTest=restarted.then(consume(request0,true).fail())
  run currentImageStillRequiresIssuedPermitTest=init.then(restoreObservation(initialCut)).then(prepare(permit0,0).fail())
  run restoredObservationIsOnlyDataTest=prepared.then(restoreObservation(initialCut)).expect(safety and s.calls==0)
  run forgedClaimCannotCommitTest=prepared.then(consume(request0.with("cut",initialCut.with("binding",original.with("claim",12))),true).fail())
  run forgedProfileCannotCommitTest=prepared.then(consume(request0.with("cut",initialCut.with("binding",original.with("commitment",21))),true).fail())
  run budgetAliasCannotCommitTest=prepared.then(consume(request0.with("cut",initialCut.with("binding",original.with("budget",99))),true).fail())
  run historyAliasCannotCommitTest=prepared.then(consume(request0.with("cut",initialCut.with("binding",original.with("history",99))),true).fail())
  run durableCASReceiptRequiredTest=prepared.then(consume(request0,false).fail())
  run duplicateRequestCannotCommitTest=committed.then(consume(request0,true).fail())
  run committedReplyLossKeepsSpentTest=committed.then(loseReply).expect(safety and s.spent and s.hold==6)
  run exactDecisionQueryDoesNotConsumeTest=committed.then(loseReply).then(confirm(decision0)).expect(safety and s.calls==1)
  run foreignDecisionCannotConfirmTest=committed.then(confirm(decision0.with("request",request0.with("id",99))).fail())
  run lateConfirmationAfterFenceIsOnlyDataTest=unknown.then(confirm(decision0)).expect(safety and s.calls==1 and s.fence==1)
  run lateConfirmationCannotRevivePermitTest=unknown.then(confirm(decision0)).then(consume(request0,true).fail())
  run freshRequestCannotReplaySpentClaimTest=committed.then(refresh(0)).then(consume(request,true).fail())
  run freshRequestKeepsOriginalBudgetTest=unknown.then(refresh(0)).expect(safety and s.hold==6 and s.usage == -1)
  run freshScopeCannotRefundUnknownTest=unknown.then(refresh(1)).then(settle(request,true).fail())
  run lateUsageNeedsSourceEvidenceTest=unknown.then(usage(4,false).fail())
  run lateUsagePreservesOriginalHoldUntilSettlementTest=unknown.then(usage(4,true)).expect(safety and s.hold==6)
  run exactSettlementAfterLateUsageTest=unknown.then(usage(4,true)).then(refresh(1)).then(settle(request,true)).expect(safety)
  run settlementRequiresCorrectOperationTest=committed.then(usage(4,true)).then(refresh(0)).then(settle(request,true).fail())
  run settlementReceiptRequiredTest=committed.then(usage(4,true)).then(refresh(1)).then(settle(request,false).fail())
  run staleSettlementAfterPolicyChangeTest=committed.then(usage(4,true)).then(refresh(1)).then(policyChange(false)).then(settle(request,true).fail())
  run missingDecisionIsNotSuccessTest=prepared.then(confirm(decision0).fail())
  run uncommittedRetryUsesSameRequestTest=prepared.then(loseReply).then(consume(request0,true)).expect(safety)
  action unsafeAccept(q)=s'=s.with("decisions",s.decisions.append({request:q,actual:cut,allowed:s.allowed,historyClear:not(s.restricted)}))
    .with("spent",true).with("calls",s.calls+1)
  action unsafeDuplicateDecision=s'=s.with("decisions",s.decisions.append(decision0))
  action unsafeRefund=s'=s.with("charged",true).with("hold",0)
  run tornReadCASCounterexampleTest=init.then(issuePermit).then(readPolicy).then(policyChange(false)).then(readBinding).then(readExecution)
    .then(prepare(permit0,0)).then(unsafeAccept(request0)).expect(not(exactCut))
  run policyABACASCounterexampleTest=prepared.then(policyChange(false)).then(policyChange(true)).then(unsafeAccept(request0)).expect(not(exactCut))
  run oldFenceCASCounterexampleTest=restarted.then(unsafeAccept(request0)).expect(not(exactCut))
  run staleLedgerCASCounterexampleTest=prepared.then(ledgerWrite).then(unsafeAccept(request0)).expect(not(exactCut))
  run lateAckCASCounterexampleTest=unknown.then(confirm(decision0)).then(unsafeAccept(request0)).expect(not(accounting))
  run duplicateCASCounterexampleTest=committed.then(unsafeDuplicateDecision).expect(not(unique))
  run profileSwapCASCounterexampleTest=prepared.then(unsafeAccept(request0.with("cut",initialCut.with("binding",original.with("commitment",21))))).expect(not(exactCut))
  run unknownRefundCASCounterexampleTest=unknown.then(unsafeRefund).expect(not(accounting))
}
