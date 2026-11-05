// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

// An admitted original-task fixture; the Lean product also projects source setup.
module LlmAuthoritativeScope {
  type Record={root:int,domain:int,commitment:int,input:int,claim:int,stream:int,document:bool,tools:Set[int],maxArgs:int,maxCalls:int}
  type Attempt={id:int,root:int,input:int,target:int,manifest:int,bound:int,epoch:int,view:int}
  type Scope={root:int,attempt:int,target:int,manifest:int,input:int,roles:List[int],tools:Set[int],schema:int,
    choice:int,parallel:bool,candidates:int,document:bool,budget:int,history:int,maxArgs:int,maxCalls:int}
  type Image={version:int,boot:int,route:int,claim:int,stream:int}
  type Ticket={id:int,child:Attempt,scope:Scope,image:Image}
  type Use={ticket:Ticket,actual:Image,record:Record,historyClear:bool,kind:int}
  type Authority={registered:bool,record:Record,known:bool,online:bool,recovered:bool,boot:int,version:int,route:int,
    history:Set[int],parentRetired:bool,parentCharged:bool,closed:bool,attempts:Set[Attempt],allocated:int,
    calls:int->int,retired:Set[int],terminal:int->int,usage:int->int,tickets:Set[Ticket],uses:Set[Use],winner:int,toolEffects:int}
  var s:Authority
  pure val canonical={root:0,domain:2,commitment:20,input:10,claim:11,stream:4,document:true,tools:Set(7,8),maxArgs:4,maxCalls:2}
  // Another legitimate task can share input bytes without sharing claim or scope.
  pure val foreign=canonical.with("root",1).with("commitment",21).with("claim",12).with("document",false)
  pure val ids=0.to(3)
  pure val missingAttempt={id:-1,root:-1,input:-1,target:-1,manifest:-1,bound:0,epoch:-1,view:-1}
  pure val emptyScope={root:-1,attempt:-1,target:-1,manifest:-1,input:-1,roles:List(),tools:Set(),schema:0,choice:0,
    parallel:false,candidates:1,document:false,budget:-1,history:-1,maxArgs:0,maxCalls:0}
  pure val emptyTicket={id:-1,child:missingAttempt,scope:emptyScope,image:{version:-1,boot:-1,route:-1,claim:-1,stream:-1}}
  pure val initial={registered:false,record:canonical,known:true,online:true,recovered:true,boot:0,version:0,route:0,
    history:Set(),parentRetired:false,parentCharged:false,closed:false,attempts:Set(),allocated:0,
    calls:ids.mapBy(i=>0),retired:Set(),terminal:ids.mapBy(i=>0),usage:ids.mapBy(i=>-1),tickets:Set(),uses:Set(),winner:-1,toolEffects:0}
  pure def cost(m)=if(m==0)6 else 8
  pure def expected(a)={root:0,attempt:a.id,target:a.target,manifest:a.manifest,input:10,roles:List(1,2,3),tools:Set(7,8),schema:4,
    choice:7,parallel:false,candidates:1,document:true,budget:5,history:9,maxArgs:4,maxCalls:2}
  def image={version:s.version,boot:s.boot,route:s.route,claim:11,stream:4}
  def attempt(i)=s.attempts.fold(missingAttempt,(a,b)=>if(b.id==i)b else a)
  def ticket(i)=s.tickets.fold(emptyTicket,(a,b)=>if(b.child.id==i and b.image==image)b else a)
  def rootLive=s.registered and s.record==canonical and s.known and s.online and s.recovered and
    not(s.history.contains(9)) and not(s.parentRetired) and not(s.parentCharged)
  def current(t)=rootLive and s.attempts.contains(t.child) and t.child.root==0 and t.child.input==10 and
    Set(0,6).contains(t.child.target) and t.scope==expected(t.child) and t.image==image
  def resolved=s.attempts.forall(a=>s.retired.contains(a.id) and s.terminal.get(a.id)!=0 and s.usage.get(a.id)>=0)
  action init=s'=initial
  action initMissing=s'=initial.with("known",false)
  action register(r,authenticated)=all {not(s.registered),authenticated,s.known,s.online,s.recovered,r==canonical,s'=s.with("registered",true).with("record",r)}
  action allocate(m)=all {rootLive,Set(0,6).contains(m),s.attempts.size()<4,not(s.closed),s.winner == -1,
    s.attempts.size()==0 or s.attempts.forall(a=>s.terminal.get(a.id)==1),s.allocated+cost(m)<=20,
    s'=s.with("attempts",s.attempts.union(Set({id:s.attempts.size(),root:0,input:10,target:m,manifest:100+m,bound:cost(m),epoch:s.boot,view:s.route})))
      .with("allocated",s.allocated+cost(m))}
  action observe(a,scope,record,authenticated)={
    val t={id:s.tickets.size(),child:a,scope:scope,image:image}
    all {authenticated,record==s.record,current(t),s'=s.with("tickets",s.tickets.union(Set(t)))}
  }
  action invoke(t,worker,bodyValid,policy)=all {s.tickets.contains(t),current(t),worker==s.boot,t.child.epoch==s.boot,
    t.child.view==s.route,not(s.retired.contains(t.child.id)),s.calls.get(t.child.id)==0,not(s.closed),bodyValid,policy,
    s'=s.with("calls",s.calls.set(t.child.id,1)).with("uses",s.uses.union(Set({ticket:t,actual:image,record:s.record,historyClear:true,kind:0})))}
  action selectWinner(i,qualified)=all {qualified,s.calls.get(i)==1,s.winner == -1,s'=s.with("winner",i)}
  action release(t,worker,kind,complete,policy)=all {s.tickets.contains(t),current(t),worker==s.boot,s.calls.get(t.child.id)==1,
    s.winner==t.child.id,policy,kind==2,complete,
    s'=s.with("uses",s.uses.union(Set({ticket:t,actual:image,record:s.record,historyClear:true,kind:1})))}
  action propose(t,tool,argUnits,finished,schema)=all {s.tickets.contains(t),current(t),s.calls.get(t.child.id)==1,
    t.scope.tools.contains(tool),argUnits>=0,argUnits<=t.scope.maxArgs,finished,schema,
    s'=s.with("uses",s.uses.union(Set({ticket:t,actual:image,record:s.record,historyClear:true,kind:2})))}
  action retire(i)=all {s.attempts.exists(a=>a.id==i),s'=s.with("retired",s.retired.union(Set(i)))}
  action noExecution(i,qualified)=all {qualified,s.retired.contains(i),s.terminal.get(i)==0,s.winner!=i,s'=s.with("terminal",s.terminal.set(i,1))}
  action terminal(i,qualified)=all {qualified,s.calls.get(i)==1,s.terminal.get(i)==0,s'=s.with("terminal",s.terminal.set(i,2))}
  action finalUsage(i,amount,qualified)=all {qualified,s.retired.contains(i),s.terminal.get(i)!=0,s.usage.get(i)== -1,
    amount>=0,amount<=attempt(i).bound,s'=s.with("usage",s.usage.set(i,amount))}
  action close=all {resolved,not(s.closed),s'=s.with("closed",true)}
  action settleParent=all {s.closed,resolved,s'=s.with("parentCharged",true)}
  action republish=s'=s.with("version",s.version+1)
  action reroute=s'=s.with("route",s.route+1)
  action restrict(h)=s'=s.with("history",s.history.union(Set(h))).with("version",s.version+1)
  action offline=s'=s.with("online",false)
  action restart=s'=s.with("boot",s.boot+1).with("recovered",false).with("retired",s.attempts.map(a=>a.id))
  action recover(r,qualified)=all {qualified,s.known,r==canonical,r==s.record,s'=s.with("recovered",true).with("online",true)}
  action timeoutOrNewNonce=s'=s
  pure def bound(u)=u.ticket.scope==expected(u.ticket.child) and u.record==canonical and u.ticket.image==u.actual and
    u.actual.claim==11 and u.actual.stream==4 and u.historyClear
  val usesBound=s.uses.forall(u=>bound(u))
  val recordBound=not(s.registered) or s.record==canonical
  val allowanceBound=s.allocated==s.attempts.fold(0,(n,a)=>n+a.bound) and s.allocated<=20 and ids.forall(i=>s.calls.get(i)<=1)
  val settlementBound=(s.parentCharged implies s.closed and resolved) and (s.closed implies resolved)
  val safety=usesBound and recordBound and allowanceBound and settlementBound and s.toolEffects==0
  action step={
    nondet i=ids.oneOf()
    nondet m=Set(0,6).oneOf()
    nondet amount=0.to(8).oneOf()
    any {register(canonical,true),allocate(m),observe(attempt(i),expected(attempt(i)),canonical,true),invoke(ticket(i),s.boot,true,true),
      selectWinner(i,true),release(ticket(i),s.boot,2,true,true),propose(ticket(i),7,2,true,true),retire(i),noExecution(i,true),terminal(i,true),
      finalUsage(i,amount,true),close,settleParent,republish,reroute,restrict(9),restrict(2),offline,restart,recover(canonical,true),timeoutOrNewNonce}
  }
  action registered=init.then(register(canonical,true))
  action prepared=registered.then(allocate(0)).then(observe(attempt(0),expected(attempt(0)),canonical,true))
  action invoked=prepared.then(invoke(ticket(0),0,true,true))
  action winner=invoked.then(selectWinner(0,true))
  action recovered=invoked.then(restart).then(recover(canonical,true)).then(observe(attempt(0),expected(attempt(0)),canonical,true))
  run canonicalScopeInvocationTest=invoked.expect(safety)
  run selfConsistentForgedBudgetRejectedTest=registered.then(allocate(0)).then(observe(attempt(0),expected(attempt(0)).with("budget",99),canonical,true).fail())
  run forgedHistoryDomainRejectedTest=registered.then(allocate(0)).then(observe(attempt(0),expected(attempt(0)).with("history",99),canonical,true).fail())
  run downgradedResponseModeRejectedTest=registered.then(allocate(0)).then(observe(attempt(0),expected(attempt(0)).with("document",false),canonical,true).fail())
  run expandedToolsRejectedTest=registered.then(allocate(0)).then(observe(attempt(0),expected(attempt(0)).with("tools",Set(7,8,9)),canonical,true).fail())
  run inflatedArgumentLimitRejectedTest=registered.then(allocate(0)).then(observe(attempt(0),expected(attempt(0)).with("maxArgs",400),canonical,true).fail())
  run sameInputForeignTaskRejectedTest=init.then(register(foreign,true).fail())
  run forgedOriginalClaimRejectedTest=init.then(register(canonical.with("claim",99),true).fail())
  run originalRecordCannotReplaceTest=registered.then(register(foreign,true).fail())
  run missingRegistryFailsClosedTest=initMissing.then(register(canonical,true).fail())
  run unauthenticatedPublicationRejectedTest=init.then(register(canonical,false).fail())
  run rootRepublicationInvalidatesTicketTest=prepared.then({val old=ticket(0);republish.then(invoke(old,0,true,true).fail())})
  run routeChangeInvalidatesTicketTest=prepared.then({val old=ticket(0);reroute.then(invoke(old,0,true,true).fail())})
  run restrictedOriginalHistoryBlocksNewScopeTest=prepared.then(restrict(9)).then(observe(attempt(0),expected(attempt(0)).with("history",99),canonical,true).fail())
  run executionDomainIsNotHistoryAccountTest=prepared.then(restrict(2)).then(observe(attempt(0),expected(attempt(0)),canonical,true)).then(invoke(ticket(0),0,true,true)).expect(safety)
  run newNonceCannotReplayTest=invoked.then(timeoutOrNewNonce).then(invoke(ticket(0),0,true,true).fail())
  run providerConversionNeedsBodyCheckTest=prepared.then(invoke(ticket(0),0,false,true).fail())
  run actualChildPolicyRequiredTest=prepared.then(invoke(ticket(0),0,true,false).fail())
  run structuredResponseCannotBecomeTextTest=winner.then(release(ticket(0),0,0,false,true).fail())
  run completeDocumentReleaseTest=winner.then(release(ticket(0),0,2,true,true)).expect(safety)
  run toolProposalUsesCanonicalSetTest=invoked.then(propose(ticket(0),9,2,true,true).fail())
  run proposalIsNotExecutionGrantTest=invoked.then(propose(ticket(0),7,2,true,true)).expect(safety and s.toolEffects==0)
  run historyRestrictionBlocksProposalTest=invoked.then(restrict(9)).then(observe(attempt(0),expected(attempt(0)),canonical,true).fail())
  run unknownUsageCannotSettleRootTest=invoked.then(settleParent.fail())
  run restartInvalidatesQueuedUseTest=prepared.then(restart).then(invoke(ticket(0),0,true,true).fail())
  run recoveryCannotReplaceProfileTest=invoked.then(restart).then(recover(canonical.with("document",false),true).fail())
  run recoveryRequiresEvidenceTest=invoked.then(restart).then(recover(canonical,false).fail())
  run recoveredOldChildCannotInvokeAgainTest=recovered.then(invoke(ticket(0),1,true,true).fail())
  run recoveredProposalRetainsTaskTest=recovered.then(propose(ticket(0),7,2,true,true)).expect(safety)
  run qualifiedNoExecutionKeepsAllowanceTest=invoked.then(retire(0)).then(noExecution(0,true)).then(allocate(6)).expect(safety and s.allocated==14)
  run unknownCannotAllocateNewChildTest=invoked.then(allocate(6).fail())
  run lateUsageReconcilesOriginalRootTest=recovered.then(terminal(0,true)).then(finalUsage(0,4,true)).then(close).then(settleParent).expect(safety)
  run closedRootCannotSendTest=registered.then(close).then(settleParent).then(allocate(0).fail())
  def unsafeRow(t)={ticket:t,actual:image,record:s.record,historyClear:not(s.history.contains(9)),kind:0}
  action unsafeForgedDomain=s'=s.with("uses",Set(unsafeRow(ticket(0).with("scope",expected(attempt(0)).with("budget",99).with("history",99)))))
  action unsafeResponseDowngrade=s'=s.with("uses",Set(unsafeRow(ticket(0).with("scope",expected(attempt(0)).with("document",false)))))
  action unsafeForeignClaim=s'=s.with("uses",Set(unsafeRow(ticket(0)).with("record",foreign)))
  action unsafeStaleAuthority(t)=s'=s.with("uses",Set(unsafeRow(t)))
  action unsafeHistoryAlias=s'=s.with("uses",Set(unsafeRow(emptyTicket.with("child",attempt(0)).with("scope",expected(attempt(0))).with("image",image))))
  action unsafeToolExpansion=s'=s.with("uses",Set(unsafeRow(ticket(0).with("scope",expected(attempt(0)).with("tools",Set(7,8,9))))))
  action unsafeNewScopeReplay=s'=s.with("calls",s.calls.set(0,2))
  action unsafeUnknownRefund=s'=s.with("parentCharged",true)
  run forgedDomainScopeCounterexampleTest=prepared.then(unsafeForgedDomain).expect(not(usesBound))
  run responseDowngradeScopeCounterexampleTest=prepared.then(unsafeResponseDowngrade).expect(not(usesBound))
  run foreignClaimScopeCounterexampleTest=prepared.then(unsafeForeignClaim).expect(not(usesBound))
  run staleAuthorityScopeCounterexampleTest=prepared.then({val old=ticket(0);republish.then(unsafeStaleAuthority(old))}).expect(not(usesBound))
  run historyAliasScopeCounterexampleTest=prepared.then(restrict(9)).then(unsafeHistoryAlias).expect(not(usesBound))
  run toolExpansionScopeCounterexampleTest=prepared.then(unsafeToolExpansion).expect(not(usesBound))
  run newScopeReplayScopeCounterexampleTest=invoked.then(unsafeNewScopeReplay).expect(not(allowanceBound))
  run unknownRefundScopeCounterexampleTest=invoked.then(unsafeUnknownRefund).expect(not(settlementBound))
}
