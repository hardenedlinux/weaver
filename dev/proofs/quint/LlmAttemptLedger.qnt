// Child attempts share one task sponsorship, escrow and immutable retry profile.
// Retirement fences admissions; it is not evidence of remote non-execution.
module LlmAttemptLedger {
  type Attempt = {id:int,root:int,target:int,bound:int,epoch:int,view:int}
  type Ledger = {epoch:int,view:int,attempts:Set[Attempt],allocated:int,charged:int,
    calls:int->int,retired:Set[int],terminal:int->int,usage:int->int,ready:Set[int],
    winner:int,winners:Set[int],closed:bool,duplicate:bool,nonTool:bool}
  var a:Ledger
  pure val ids = 0.to(3)
  pure val emptyAttempt = {id:-1,root:-1,target:-1,bound:0,epoch:-1,view:-1}
  pure val initial = {epoch:0,view:0,attempts:Set(),allocated:0,charged:0,
    calls:ids.mapBy(i=>0),retired:Set(),terminal:ids.mapBy(i=>0),usage:ids.mapBy(i=>-1),ready:Set(),
    winner:-1,winners:Set(),closed:false,duplicate:false,nonTool:true}
  pure def cost(m) = if(m==0) 6 else if(m==6) 8 else 30
  def eligible(m) = (m==0 or m==6) and not(a.view>0 and m==0)
  def attempt(i) = a.attempts.fold(emptyAttempt,(r,t)=>if(t.id==i)t else r)
  def retryAllowed = a.attempts.size()==0 or a.attempts.forall(t=>a.terminal.get(t.id)==1) or (a.duplicate and a.nonTool)
  action init = a'=initial
  action initDuplicate = a'=initial.with("duplicate",true)
  action initToolDuplicate = a'=initial.with("duplicate",true).with("nonTool",false)
  action allocate(m,view,policy) = {
    val t={id:a.attempts.size(),root:0,target:m,bound:cost(m),epoch:a.epoch,view:view}
    all {policy,eligible(m),view==a.view,retryAllowed,a.attempts.size()<4,a.allocated+cost(m)<=20,
      a.winner == -1,not(a.closed),a'=a.with("attempts",a.attempts.union(Set(t))).with("allocated",a.allocated+cost(m))}
  }
  action invoke(t,worker,policy) = all {policy,a.attempts.contains(t),t.epoch==a.epoch,worker==a.epoch,
    not(a.retired.contains(t.id)),a.calls.get(t.id)==0,not(a.closed),a.winner == -1 or a.winner==t.id,
    t.view==a.view,eligible(t.target),a'=a.with("calls",a.calls.set(t.id,1))}
  action retire(i) = all {a.attempts.exists(t=>t.id==i),a'=a.with("retired",a.retired.union(Set(i)))}
  action noExecution(i,qualified) = all {qualified,a.attempts.exists(t=>t.id==i),a.retired.contains(i),
    a.terminal.get(i)==0,not(a.ready.contains(i)),not(a.closed),a'=a.with("terminal",a.terminal.set(i,1))}
  action terminal(i,kind,qualified) = all {qualified,a.attempts.exists(t=>t.id==i),a.calls.get(i)==1,
    a.terminal.get(i)==0,kind==2 or kind==3,not(a.closed),a'=a.with("terminal",a.terminal.set(i,kind))}
  action prefixReady(i,qualified) = all {qualified,a.attempts.exists(t=>t.id==i),a.calls.get(i)==1,
    a.terminal.get(i)!=1,not(a.closed),a'=a.with("ready",a.ready.union(Set(i)))}
  action commitWinner(i,policy) = all {policy,a.attempts.exists(t=>t.id==i),a.calls.get(i)==1,
    a.ready.contains(i),a.winner == -1,not(a.closed),a'=a.with("winner",i).with("winners",Set(i))}
  action finalUsage(t,amount,qualified) = all {qualified,a.attempts.contains(t),a.retired.contains(t.id),
    a.terminal.get(t.id)!=0,a.usage.get(t.id)== -1,amount>=0,amount<=t.bound,a.charged+amount<=a.allocated,not(a.closed),
    a'=a.with("charged",a.charged+amount).with("usage",a.usage.set(t.id,amount))}
  def closeReady = a.attempts.forall(t=>a.retired.contains(t.id) and a.terminal.get(t.id)!=0 and a.usage.get(t.id)>=0)
  action close = all {not(a.closed),closeReady,a'=a.with("closed",true)}
  action restart = a'=a.with("epoch",a.epoch+1).with("retired",a.attempts.map(t=>t.id))
  action restrictPolicyOrHistory = a'=a.with("view",a.view+1)
  action timeoutOrLostReply = a'=a
  val allocationBound = a.allocated==a.attempts.fold(0,(n,t)=>n+t.bound) and a.allocated<=20 and
    a.attempts.forall(t=>t.root==0 and t.bound==cost(t.target) and t.id>=0 and t.id<4) and
    a.attempts.size()==a.attempts.map(t=>t.id).size()
  val callBound = ids.forall(i=>a.calls.get(i)<=1)
  val winnerBound = a.winners.size()<=1 and (a.winner == -1 or (a.ready.contains(a.winner) and a.winners.contains(a.winner)))
  val closureBound = a.closed implies closeReady
  val usageBound = a.charged==a.attempts.fold(0,(n,t)=>n+ (if(a.usage.get(t.id)<0) 0 else a.usage.get(t.id))) and a.charged<=a.allocated
  val safety = allocationBound and callBound and winnerBound and closureBound and usageBound
  action step = {
    nondet i=ids.oneOf()
    nondet m=Set(0,6,5).oneOf()
    nondet amount=0.to(8).oneOf()
    any {allocate(m,a.view,true),invoke(attempt(i),a.epoch,true),retire(i),noExecution(i,true),terminal(i,2,true),terminal(i,3,true),
      prefixReady(i,true),commitWinner(i,true),finalUsage(attempt(i),amount,true),close,restart,restrictPolicyOrHistory,timeoutOrLostReply}
  }
  action allocated = init.then(allocate(0,0,true))
  action unknown = allocated.then(invoke(attempt(0),0,true))
  action rejected = unknown.then(retire(0)).then(noExecution(0,true))
  action failover = rejected.then(allocate(6,0,true))
  action hedged = initDuplicate.then(allocate(0,0,true)).then(invoke(attempt(0),0,true)).then(allocate(6,0,true)).then(invoke(attempt(1),0,true))
  action winner = hedged.then(prefixReady(1,true)).then(commitWinner(1,true))
  run primaryKeepsOriginalRootTest = unknown.expect(safety and a.allocated==6 and attempt(0).root==0)
  run unknownDefaultCannotFailoverTest = unknown.then(allocate(6,0,true).fail())
  run retirementAloneCannotFailoverTest = unknown.then(retire(0)).then(allocate(6,0,true).fail())
  run timeoutCannotProveNoExecutionTest = unknown.then(timeoutOrLostReply).then(retire(0)).then(noExecution(0,false).fail())
  run qualifiedNoExecutionAllowsChildTest = failover.expect(safety and a.allocated==14 and attempt(1).root==0 and a.usage.get(0)== -1)
  run explicitNonToolDuplicationTest = hedged.expect(safety and a.allocated==14)
  run toolProfileCannotDuplicateTest = initToolDuplicate.then(allocate(0,0,true)).then(invoke(attempt(0),0,true)).then(allocate(6,0,true).fail())
  run sharedEscrowCannotExpandTest = hedged.then(allocate(6,0,true).fail())
  run deniedTargetRejectedTest = init.then(allocate(5,0,true).fail())
  run childPolicyRequiredTest = allocated.then(invoke(attempt(0),0,false).fail())
  run staleViewCannotInvokeTest = allocated.then(restrictPolicyOrHistory).then(invoke(attempt(0),0,true).fail())
  run sdkRetryCannotReinvokeTest = unknown.then(timeoutOrLostReply).then(invoke(attempt(0),0,true).fail())
  run restartCannotReinvokeTest = unknown.then(restart).then(invoke(attempt(0),1,true).fail())
  run oldUncalledChildCannotRelabelEpochTest = allocated.then(restart).then(invoke(attempt(0).with("epoch",1),1,true).fail())
  run retiredUncalledChildCanResolveTest = allocated.then(restart).then(noExecution(0,true)).then(allocate(6,0,true)).expect(safety)
  run winnerStopsNewAttemptsTest = winner.then(allocate(0,0,true).fail())
  run winnerCannotSwitchTest = winner.then(prefixReady(0,true)).then(commitWinner(0,true).fail())
  run disclosureRequiresCurrentPolicyTest = hedged.then(prefixReady(1,true)).then(commitWinner(1,false).fail())
  run prefixCannotBecomeNoExecutionTest = unknown.then(prefixReady(0,true)).then(retire(0)).then(noExecution(0,true).fail())
  run negativeCannotProducePrefixTest = rejected.then(prefixReady(0,true).fail())
  run loserUnknownPreventsClosureTest = winner.then(retire(1)).then(terminal(1,2,true)).then(finalUsage(attempt(1),7,true)).then(close.fail())
  run terminalAloneDoesNotReleaseTest = unknown.then(terminal(0,2,true)).then(retire(0)).then(close.fail())
  run duplicateUsageReceiptRejectedTest = rejected.then(finalUsage(attempt(0),0,true)).then(finalUsage(attempt(0),0,true).fail())
  run lateUsageAfterRestartReconcilesTest = unknown.then(terminal(0,3,true)).then(restart).then(finalUsage(attempt(0),4,true)).then(close).expect(safety and a.charged==4)
  run foreignAttemptReceiptRejectedTest = rejected.then(finalUsage(attempt(0).with("root",9),0,true).fail())
  run usageAboveBoundRejectedTest = rejected.then(finalUsage(attempt(0),7,true).fail())
  run zeroUsageDoesNotReopenAllocationTest = rejected.then(finalUsage(attempt(0),0,true)).then(allocate(6,0,true)).expect(safety and a.allocated==14)
  run bothChildrenResolveBeforeCloseTest = winner.then(retire(0)).then(terminal(0,3,true)).then(finalUsage(attempt(0),4,true))
    .then(retire(1)).then(terminal(1,2,true)).then(finalUsage(attempt(1),7,true)).then(close).expect(safety and a.charged==11 and a.allocated==14)
  action unsafeResetAllowance = a'=a.with("allocated",0)
  action unsafeReplay = a'=a.with("calls",a.calls.set(0,2))
  action unsafeSwitchWinner = a'=a.with("winner",0).with("winners",a.winners.union(Set(0)))
  action unsafeCloseUnknown = a'=a.with("closed",true)
  action unsafeDoubleUsage = a'=a.with("charged",a.charged+1)
  action unsafeForeignRoot = a'=a.with("attempts",a.attempts.map(t=>t.with("root",9)))
  run resetAllowanceAttemptCounterexampleTest = allocated.then(unsafeResetAllowance).expect(not(allocationBound))
  run sdkReplayAttemptCounterexampleTest = unknown.then(unsafeReplay).expect(not(callBound))
  run switchWinnerAttemptCounterexampleTest = winner.then(unsafeSwitchWinner).expect(not(winnerBound))
  run closeUnknownAttemptCounterexampleTest = winner.then(unsafeCloseUnknown).expect(not(closureBound))
  run duplicateUsageAttemptCounterexampleTest = rejected.then(finalUsage(attempt(0),0,true)).then(unsafeDoubleUsage).expect(not(usageBound))
  run foreignRootAttemptCounterexampleTest = allocated.then(unsafeForeignRoot).expect(not(allocationBound))
}
