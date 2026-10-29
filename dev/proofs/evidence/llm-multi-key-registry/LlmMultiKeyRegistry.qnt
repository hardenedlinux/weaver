module LlmMultiKeyRegistry {
  // Integers stand for qualified identifiers; no parser/hash/native-store claim.
  type Entry={origin:int,family:int,claim:int,profile:int,budget:int,history:int}
  type Alias={key:int,origin:int}
  type Request={id:int,parent:int,fence:int,source:int,policy:int,kind:int,entry:Entry,alias:Alias,amount:int}
  type Decision={request:Request,position:int}
  type Use={request:Request,revision:int,fence:int,source:int,policy:int}
  type State={rows:Set[Entry],aliases:Set[Alias],pending:Set[Request],decisions:Set[Decision],uses:List[Use],
    revision:int,fence:int,source:int,policy:int,online:bool,visible:Set[int],applied:Set[int],spent:Set[int],everSpent:Set[int],charged:int,calls:int,denied:bool}
  var s:State
  pure val e0={origin:10,family:11,claim:12,profile:30,budget:5,history:9}
  pure val e1={origin:20,family:21,claim:22,profile:31,budget:5,history:9}
  pure val e2={origin:30,family:31,claim:32,profile:32,budget:5,history:9}
  pure val admittedEntries=Set(e0,e1,e2,e1.with("family",11),e1.with("claim",12))
  pure val a0={key:100,origin:10}
  pure val a1={key:101,origin:20}
  pure val a2={key:102,origin:10}
  pure val initial={rows:Set(),aliases:Set(),pending:Set(),decisions:Set(),uses:List(),revision:0,fence:0,source:0,policy:0,
    online:true,visible:Set(),applied:Set(),spent:Set(),everSpent:Set(),charged:0,calls:0,denied:false}
  pure def req(id,parent,fence,source,policy,kind,e,a,amount)={id:id,parent:parent,fence:fence,source:source,policy:policy,kind:kind,entry:e,alias:a,amount:amount}
  pure val r0=req(0,0,0,0,0,0,e0,a0,0)
  pure val rRace=req(1,0,0,0,0,0,e1,a1,0)
  pure val r1=req(1,1,0,1,0,0,e1,a1,0)
  pure val b0=req(2,2,0,2,0,1,e0,a0,0)
  pure val b1=req(3,3,0,3,0,1,e1,a1,0)
  pure val c0=req(4,4,0,4,0,2,e0,a0,3)
  pure val c1=req(5,5,0,5,0,2,e1,a1,3)
  pure val c1fit=c1.with("amount",2)
  def fresh(r)=s.pending.contains(r) and s.decisions.forall(d=>d.request.id!=r.id) and
    r.parent==s.revision and r.fence==s.fence and r.source==s.source and r.policy==s.policy and s.online
  def commitImage(r)=s.with("decisions",s.decisions.union(Set({request:r,position:s.revision+1})))
    .with("revision",s.revision+1).with("source",s.source+1)
  action init=s'=initial
  action stage(r)=all {s.pending.forall(old=>old.id!=r.id or old==r), s'=s.with("pending",s.pending.union(Set(r)))}
  action register(r,authorized)=all {fresh(r),r.kind==0,authorized,admittedEntries.contains(r.entry),
    s.rows.forall(e=>e.origin!=r.entry.origin and e.family!=r.entry.family and e.claim!=r.entry.claim),
    s'=commitImage(r).with("rows",s.rows.union(Set(r.entry)))}
  action bind(r,continuity)=all {fresh(r),r.kind==1,continuity,s.rows.contains(r.entry),r.entry.origin==r.alias.origin,
    s.aliases.forall(a=>a.key!=r.alias.key),s'=commitImage(r).with("aliases",s.aliases.union(Set(r.alias)))}
  action consume(r,policy)=all {fresh(r),r.kind==2,policy,not(s.denied),s.rows.contains(r.entry),s.aliases.contains(r.alias),
    r.alias.origin==r.entry.origin,not(s.spent.contains(r.entry.claim)),r.amount>=0,s.charged+r.amount<=5,
    s'=commitImage(r).with("spent",s.spent.union(Set(r.entry.claim))).with("everSpent",s.everSpent.union(Set(r.entry.claim)))
      .with("charged",s.charged+r.amount).with("calls",s.calls+1)
      .with("uses",s.uses.append({request:r,revision:s.revision,fence:s.fence,source:s.source,policy:s.policy}))}
  action apply(id,exact)=all {exact,s.online,s.decisions.exists(d=>d.request.id==id),s'=s.with("applied",s.applied.union(Set(id)))}
  action query(r,exact)=all {exact,s.online,s.decisions.exists(d=>d.request==r),s'=s.with("visible",s.visible.union(Set(r.id)))}
  action loseReply=s'=s.with("visible",Set())
  action mixedSnapshot=s'=s.with("applied",Set()).with("visible",Set()).with("online",false)
  action restart=s'=s.with("fence",s.fence+1).with("online",false)
  action recover(currentPrefix)=all {currentPrefix,s'=s.with("online",true)}
  action denyHistory=s'=s.with("denied",true).with("policy",s.policy+1).with("revision",s.revision+1)
  action sourceWrite=s'=s.with("source",s.source+1).with("revision",s.revision+1)
  val unique=s.rows.forall(e=>s.rows.forall(f=>e==f or (e.origin!=f.origin and e.family!=f.family and e.claim!=f.claim)))
  val bound=s.rows.forall(e=>admittedEntries.contains(e)) and s.aliases.forall(a=>s.rows.exists(e=>e.origin==a.origin)) and
    s.aliases.forall(a=>s.aliases.forall(b=>a.key!=b.key or a==b))
  val decisionUnique=s.decisions.forall(d=>s.decisions.forall(e=>d==e or (d.request.id!=e.request.id and d.position!=e.position)))
  val accounting=s.charged>=0 and s.charged<=5 and s.everSpent.subseteq(s.spent) and s.calls==s.everSpent.size()
  val pendingRetained=s.decisions.forall(d=>s.pending.contains(d.request))
  val usesBound=s.uses.indices().forall(i=>{val u=s.uses.nth(i) val r=u.request
    r.parent==u.revision and r.fence==u.fence and r.source==u.source and r.policy==u.policy})
  val projections=s.applied.forall(id=>s.decisions.exists(d=>d.request.id==id))
  val safety=unique and bound and decisionUnique and accounting and pendingRetained and usesBound and projections
  action registered=init.then(stage(r0)).then(register(r0,true))
  action pair=registered.then(stage(r1)).then(register(r1,true))
  action aliases=pair.then(stage(b0)).then(bind(b0,true)).then(stage(b1)).then(bind(b1,true))
  action unknown=aliases.then(stage(c0)).then(consume(c0,true))
  action restarted=unknown.then(restart)
  action stagedRace=init.then(stage(r0)).then(stage(rRace))
  action step={nondet e=Set(e0,e1,e2).oneOf() nondet kind=Set(0,1,2).oneOf() nondet amount=Set(0,2,3).oneOf()
    val r=req(s.pending.size(),s.revision,s.fence,s.source,s.policy,kind,e,{key:e.origin+90,origin:e.origin},amount)
    nondet pending=s.pending.union(Set(r)).oneOf()
    any {stage(r),register(pending,true),bind(pending,true),consume(pending,true),apply(pending.id,true),query(pending,true),loseReply,
      mixedSnapshot,restart,recover(true),denyHistory,sourceWrite}}
  run distinctOriginsShareOnePrefixTest=pair.expect(safety and s.rows.size()==2 and s.revision==2)
  run concurrentOldParentCannotCommitTest=stagedRace.then(register(r0,true)).then(register(rRace,true).fail())
  run staleParentWithFreshSourceStillFailsTest=registered.then(stage(rRace.with("source",1)))
    .then(register(rRace.with("source",1),true).fail())
  run staleSourceWithFreshParentStillFailsTest=aliases.then(sourceWrite).then(stage(c0.with("parent",5)))
    .then(consume(c0.with("parent",5),true).fail())
  run duplicateOriginDifferentTransactionTest=registered.then(stage(r0.with("id",7).with("parent",1).with("source",1)))
    .then(register(r0.with("id",7).with("parent",1).with("source",1),true).fail())
  run lostReplyQueryKeepsOneOriginTest=registered.then(loseReply).then(query(r0,true)).expect(safety and s.rows.size()==1 and s.visible.contains(0))
  run lostReplyCannotApplyAgainTest=registered.then(loseReply).then(register(r0,true).fail())
  run reusedTransactionDifferentBodyTest=registered.then(stage(r0.with("entry",e1)).fail())
  run wrongBodyQueryCannotResolveTest=registered.then(query(r0.with("entry",e1),true).fail())
  run familyCollisionRejectedTest=registered.then(stage(r1.with("entry",e1.with("family",11))))
    .then(register(r1.with("entry",e1.with("family",11)),true).fail())
  run claimCollisionRejectedTest=registered.then(stage(r1.with("entry",e1.with("claim",12))))
    .then(register(r1.with("entry",e1.with("claim",12)),true).fail())
  run aliasRequiresCommittedOriginTest=init.then(stage(b0.with("parent",0).with("source",0))).then(bind(b0.with("parent",0).with("source",0),true).fail())
  run aliasRequiresContinuityTest=pair.then(stage(b0)).then(bind(b0,false).fail())
  run aliasCannotRebindAcrossOriginsTest=aliases.then(stage(b1.with("id",7).with("parent",4).with("source",4).with("alias",a0.with("origin",20))))
    .then(bind(b1.with("id",7).with("parent",4).with("source",4).with("alias",a0.with("origin",20)),true).fail())
  run aliasAndConsumeSerializeTest=aliases.then(stage(c0)).then(stage(b0.with("id",8).with("parent",4).with("source",4).with("alias",a2)))
    .then(bind(b0.with("id",8).with("parent",4).with("source",4).with("alias",a2),true)).then(consume(c0,true).fail())
  run sharedBudgetRejectsIndependentAllowanceTest=unknown.then(stage(c1)).then(consume(c1,true).fail())
  run sharedBudgetAllowsRemainingAmountTest=unknown.then(stage(c1fit)).then(consume(c1fit,true)).expect(safety and s.charged==5 and s.calls==2)
  run mixedSnapshotCannotCreateTest=registered.then(mixedSnapshot).then(register(rRace,true).fail())
  run recoveryReplaysDecisionOnlyTest=unknown.then(mixedSnapshot).then(recover(true)).then(apply(4,true)).then(apply(4,true))
    .expect(safety and s.charged==3 and s.spent.contains(12) and s.calls==1)
  run missingCurrentPrefixCannotRecoverTest=restarted.then(recover(false).fail())
  run pendingSurvivesRestartTest=stagedRace.then(restart).then(recover(true)).expect(s.pending.contains(r0) and s.pending.contains(rRace) and safety)
  run oldOwnerCannotCommitTest=aliases.then(stage(c0)).then(restart).then(recover(true)).then(consume(c0,true).fail())
  run staleSourceReadCannotCommitTest=aliases.then(stage(c0)).then(sourceWrite).then(consume(c0,true).fail())
  run historyChangeInvalidatesAdmissionTest=aliases.then(stage(c0)).then(denyHistory).then(consume(c0,true).fail())
  run freshReceiptStillSeesHistoryDenialTest=aliases.then(denyHistory).then(stage(c0.with("parent",5).with("policy",1)))
    .expect(fresh(c0.with("parent",5).with("policy",1)) and s.denied).then(consume(c0.with("parent",5).with("policy",1),true).fail())
  run freshReceiptStillSeesSpentClaimTest=unknown.then(stage(c0.with("id",9).with("parent",5).with("source",5)))
    .expect(fresh(c0.with("id",9).with("parent",5).with("source",5)) and s.spent.contains(12))
    .then(consume(c0.with("id",9).with("parent",5).with("source",5),true).fail())
  run oldOwnerMayObserveExactOutcomeTest=restarted.then(recover(true)).then(query(c0,true)).expect(safety and s.visible.contains(4) and s.fence==1)
  run projectionCannotInventCommitTest=pair.then(apply(99,true).fail())
  run registrationRequiresAdmissionTest=init.then(stage(r0)).then(register(r0,false).fail())
  run absentCommitIsNotAbortEvidenceTest=stagedRace.then(mixedSnapshot).expect(s.pending.size()==2 and not(s.online) and safety)
  // Deliberately broken alternatives are excluded from step.
  action unsafeDuplicate=s'=s.with("rows",s.rows.union(Set(e0.with("family",99))))
  action unsafeFamily=s'=s.with("rows",s.rows.union(Set(e1.with("family",11))))
  action unsafeClaim=s'=s.with("rows",s.rows.union(Set(e1.with("claim",12))))
  action unsafeAlias=s'=s.with("aliases",s.aliases.union(Set(a0.with("origin",20))))
  action unsafeConsume(r)=s'=s.with("uses",s.uses.append({request:r,revision:s.revision,fence:s.fence,source:s.source,policy:s.policy}))
  action unsafeBudget=s'=s.with("charged",6)
  action unsafeRestore=s'=s.with("spent",Set()).with("charged",0)
  action unsafeDecision=s'=s.with("decisions",s.decisions.union(Set({request:r0.with("entry",e1),position:2})))
  action unsafePending=s'=s.with("pending",Set())
  run duplicateOriginCounterexampleTest=registered.then(loseReply).then(unsafeDuplicate).expect(not(unique))
  run duplicateFamilyCounterexampleTest=registered.then(unsafeFamily).expect(not(unique))
  run duplicateClaimCounterexampleTest=registered.then(unsafeClaim).expect(not(unique))
  run aliasRebindCounterexampleTest=aliases.then(unsafeAlias).expect(not(bound))
  run oldOwnerCounterexampleTest=aliases.then(stage(c0)).then(restart).then(recover(true)).then(unsafeConsume(c0)).expect(not(usesBound))
  run staleSourceCounterexampleTest=aliases.then(stage(c0)).then(sourceWrite).then(unsafeConsume(c0)).expect(not(usesBound))
  run sharedBudgetCounterexampleTest=unknown.then(unsafeBudget).expect(not(accounting))
  run rollbackCounterexampleTest=unknown.then(mixedSnapshot).then(unsafeRestore).expect(not(accounting))
  run conflictingDecisionCounterexampleTest=registered.then(unsafeDecision).expect(not(decisionUnique))
  run droppedPendingCounterexampleTest=registered.then(unsafePending).expect(not(pendingRetained))
}
