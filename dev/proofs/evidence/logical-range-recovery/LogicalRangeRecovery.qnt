// Stable logical range identity; execution permits carry a separate current epoch.
module LogicalRangeRecovery {
  import BrokerConsumptionQueue as Q from "./BrokerConsumptionQueue"
  type Scope = {root:int,claim:int,budget:int,history:int,payload:int,manifest:int,route:int,lo:int,hi:int}
  type Cut = {scope:Scope,epoch:int,revision:int,calls:int}
  type Permit = {scope:Scope,epoch:int,activation:int}
  type Receipt = {call:Permit,bytes:int}
  pure val scope = {root:0,claim:0,budget:0,history:0,payload:10,manifest:10,route:0,lo:0,hi:2}
  pure val emptyCut = {scope:scope,epoch:-1,revision:-1,calls:-1}
  pure val emptyPermit = {scope:scope,epoch:-1,activation:-1}
  type Recovery = {epoch:int,revision:int,calls:int,fenced:bool,allowed:bool,observed:Cut,haveObservation:bool,
    jobs:Set[Cut],decisions:Set[Permit],permit:Permit,havePermit:bool,invocation:Permit,haveInvocation:bool,
    unknown:bool,full:bool,receipts:Set[Receipt]}
  var x:Recovery
  pure val initial = {epoch:0,revision:0,calls:0,fenced:false,allowed:true,observed:emptyCut,haveObservation:false,
    jobs:Set(),decisions:Set(),permit:emptyPermit,havePermit:false,invocation:emptyPermit,haveInvocation:false,
    unknown:false,full:false,receipts:Set()}
  action init = all {Q::reserved,x' = initial}
  action holdParent = Q::partialOrTimeout
  def currentCut = {scope:scope,epoch:x.epoch,revision:x.revision,calls:x.calls}
  def nextPermit = {scope:scope,epoch:x.epoch,activation:x.revision+1}
  action fence = all {holdParent,x' = x.with("epoch",x.epoch+1).with("revision",x.revision+1)
    .with("fenced",true).with("havePermit",false).with("haveObservation",false)}
  action certify(c,authentic) = all {authentic,x.fenced,c == currentCut,holdParent,
    x' = x.with("observed",c).with("haveObservation",true)}
  action readCut = certify(currentCut,true)
  action prepare = all {x.haveObservation,x.observed == currentCut,x.fenced,x.calls==0,holdParent,
    x' = x.with("jobs",x.jobs.union(Set(currentCut)))}
  action activateWithPolicy(c,view,authentic) = all {authentic,view==currentCut,x.jobs.contains(c),c==currentCut,x.fenced,x.calls==0,x.allowed,holdParent,
    x' = x.with("revision",x.revision+1).with("fenced",false).with("permit",nextPermit).with("havePermit",true)
      .with("decisions",x.decisions.union(Set(nextPermit))).with("haveObservation",false)}
  action activate(c) = activateWithPolicy(c,currentCut,true)
  // The parent range epoch is an abstract stable binding stamp. This layer's
  // x.epoch is the real mutable execution fence; it is checked below.
  action invokeWithPolicy(p,worker,view,authentic) = all {authentic,view==currentCut,x.havePermit,p==x.permit,p.scope==scope,p.epoch==x.epoch,worker==x.epoch,
    p.activation==x.revision,x.calls==0,x.allowed,Q::invoke(Q::q.pending,Q::q.epoch),
    x' = x.with("revision",x.revision+1).with("calls",1).with("havePermit",false).with("invocation",p)
      .with("haveInvocation",true).with("unknown",true).with("haveObservation",false)}
  action invoke(p,worker) = invokeWithPolicy(p,worker,currentCut,true)
  action fullReceipt(r,authentic) = all {authentic,x.haveInvocation,r.call==x.invocation,x.calls==1,r.bytes==scope.hi-scope.lo,
    if (x.full) holdParent else Q::fullReceipt(Q::q.pending,true),
    x' = x.with("unknown",false).with("full",true).with("receipts",x.receipts.union(Set(r)))}
  action loseReply = all {holdParent,x' = x.with("haveObservation",false)}
  action partialOrTimeout = all {holdParent,x' = x}
  action revoke = all {Q::revoke,x' = x.with("epoch",x.epoch+1).with("revision",x.revision+1)
    .with("fenced",true).with("allowed",false).with("havePermit",false).with("haveObservation",false)}
  action reauthorize = all {Q::reauthorize,x' = x.with("revision",x.revision+1).with("allowed",true).with("havePermit",false).with("haveObservation",false)}
  def jobAt(rev) = x.jobs.fold(emptyCut,(found,c) => if (c.revision==rev) c else found)
  val callOnce = x.calls<=1
  val unknownSound = x.unknown implies x.calls==1 and not(x.full)
  val fullSound = x.full implies x.calls==1 and not(x.unknown)
  val permitSound = x.havePermit implies x.permit.scope==scope and x.permit.epoch==x.epoch and
    x.permit.activation==x.revision and x.calls==0 and not(x.fenced)
  val invocationBound = x.haveInvocation implies x.invocation.scope==scope and x.calls==1
  val receiptBound = x.receipts.forall(r => x.haveInvocation and r.call==x.invocation and r.bytes==scope.hi-scope.lo)
  val parentCoupled = x.calls == Q::q.calls.get(scope.lo) and x.unknown == Q::q.unknown and
    (x.full implies not(Q::q.hasPending)) and not(Q::q.settled)
  val safety = Q::safety and callOnce and unknownSound and fullSound and permitSound and invocationBound and receiptBound and parentCoupled
  action step = {
    nondet c = x.jobs.union(Set(emptyCut)).oneOf()
    nondet p = x.decisions.union(Set(emptyPermit)).oneOf()
    nondet worker = Set(x.epoch,x.epoch-1).oneOf()
    any {fence,readCut,prepare,activate(c),invoke(p,worker),
      fullReceipt({call:x.invocation,bytes:2},true),loseReply,partialOrTimeout,revoke,reauthorize}
  }
  action sealed = init.then(fence)
  action prepared = sealed.then(readCut).then(prepare)
  action active = prepared.then(activate(currentCut))
  action uncertain = active.then(invoke(x.permit,x.epoch))
  action complete = uncertain.then(fullReceipt({call:x.invocation,bytes:2},true))
  run initialRecoveryTest = active.expect(safety and x.havePermit and x.calls==0)
  run lostReadReplyDoesNotCancelJobTest = prepared.then(loseReply).then(activate(jobAt(1))).expect(safety and x.havePermit)
  run lostActivationReplyTest = active.then(loseReply).expect(safety and x.decisions.size()==1)
  run lostFenceResponseCanReconcileTest = active.then(fence).then(loseReply).then(readCut).then(prepare).then(activate(currentCut)).then(invoke(x.permit,x.epoch)).expect(safety and x.calls==1)
  run duplicateActivationRejectedTest = active.then(activate(jobAt(1)).fail())
  run restartBeforeCallCanContinueSameRangeTest = active.then(fence).then(readCut).then(prepare).then(activate(currentCut))
    .then(invoke(x.permit,x.epoch)).expect(safety and x.calls==1 and x.invocation.scope==scope)
  run oldPermitAfterFenceRejectedTest = active.then(fence).then(invoke({scope:scope,epoch:1,activation:2},1).fail())
  run currentWorkerCannotRelabelOldPermitTest = active.then(fence).then(readCut).then(prepare).then(activate(currentCut))
    .then(invoke({scope:scope,epoch:1,activation:2},x.epoch).fail())
  run callBeforeFenceCannotRearmTest = uncertain.then(fence).then(readCut).then(prepare.fail())
  run fenceBeforeCallRejectsOldWorkerTest = active.then(fence).then(invoke({scope:scope,epoch:1,activation:2},1).fail())
  run staleCutCannotActivateTest = prepared.then(fence).then(activate(jobAt(1)).fail())
  run cutRequiresFenceTest = init.then(readCut.fail())
  run forgedCutRejectedTest = sealed.then(certify(currentCut,false).fail())
  run wrongRootCutRejectedTest = sealed.then(certify(currentCut.with("scope",scope.with("root",1)),true).fail())
  run changedPolicyInvalidatesCutTest = prepared.then(revoke).then(reauthorize).then(activate(jobAt(1)).fail())
  run oldActivationAllowCannotAuthorizeInvokeTest = active.then(invokeWithPolicy(x.permit,x.epoch,jobAt(1),true).fail())
  run forgedFinalPolicyRejectedTest = active.then(invokeWithPolicy(x.permit,x.epoch,currentCut,false).fail())
  run replayAfterUnknownRejectedTest = uncertain.then(invoke(x.invocation,x.epoch).fail())
  run timeoutDoesNotRearmTest = uncertain.then(partialOrTimeout).then(fence).then(readCut).then(prepare.fail())
  run lateOriginalReceiptAfterFenceTest = uncertain.then(fence).then(fullReceipt({call:x.invocation,bytes:2},true)).expect(safety and x.full)
  run wrongManifestReceiptRejectedTest = uncertain.then(fullReceipt({call:x.invocation.with("scope",scope.with("manifest",11)),bytes:2},true).fail())
  run wrongPermitReceiptRejectedTest = uncertain.then(fullReceipt({call:x.invocation.with("activation",99),bytes:2},true).fail())
  run partialReceiptCannotCompleteTest = uncertain.then(fullReceipt({call:x.invocation,bytes:1},true).fail())
  run forgedFullReceiptRejectedTest = uncertain.then(fullReceipt({call:x.invocation,bytes:2},false).fail())
  run duplicateReceiptIsDataOnlyTest = complete.then(fullReceipt({call:x.invocation,bytes:2},true)).expect(safety and x.calls==1 and x.receipts.size()==1)
  run lateTimeoutCannotUndoFullReceiptTest = complete.then(partialOrTimeout).then(fence).expect(safety and x.full and not(x.unknown))
  run localFullReceiptCannotSettleStreamTest = complete.expect(safety and Q::q.frontier==2 and not(Q::q.completed) and not(Q::q.settled))
  // Unsafe controls are excluded from step.
  action unsafeKeepPermit = all {holdParent,x' = x.with("epoch",x.epoch+1).with("revision",x.revision+1)}
  action unsafeReplay = all {holdParent,x' = x.with("calls",2)}
  action unsafeResetSlot = all {holdParent,x' = x.with("calls",0)}
  action unsafeStaleCutPermit = all {holdParent,x' = x.with("permit",{scope:scope,epoch:x.epoch,activation:x.revision}).with("havePermit",true)}
  action unsafeFakeComplete = all {holdParent,x' = x.with("full",true)}
  action unsafeForeignReceipt = all {holdParent,x' = x.with("receipts",Set({call:x.invocation.with("scope",scope.with("root",1)),bytes:2}))}
  run stalePermitCounterexampleTest = active.then(unsafeKeepPermit).expect(not(permitSound))
  run recoveryReplayCounterexampleTest = uncertain.then(unsafeReplay).expect(not(callOnce))
  run resetConsumedSlotCounterexampleTest = uncertain.then(fence).then(unsafeResetSlot).expect(not(unknownSound) and not(parentCoupled))
  run staleNoCallCutCounterexampleTest = uncertain.then(fence).then(unsafeStaleCutPermit).expect(not(permitSound) and x.calls==1)
  run timeoutAsFullCounterexampleTest = uncertain.then(partialOrTimeout).then(unsafeFakeComplete).expect(not(unknownSound))
  run foreignReceiptCounterexampleTest = uncertain.then(unsafeForeignReceipt).expect(not(receiptBound))
}
