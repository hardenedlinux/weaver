module LlmPolicyContinuation {
  type Change={id:int,root:int,parent:int,tip:int,content:int,allowed:bool,claim:int,profile:int,budget:int,history:int}
  type View={generation:int,tip:int,fence:int,revision:int}
  type Approval={candidate:Change,view:View,authorized:bool}
  type Publication={change:Change,generation:int,actual:View,approval:View,reauthorized:bool}
  type Alias={protocol:int,task:int,canonicalRoot:int}
  type Permit={id:int,generation:int,fence:int,revision:int}
  type Use={permit:Permit,actual:View,allowed:bool}
  type State={staged:Set[Change],log:List[Publication],generation:int,allowed:bool,fence:int,revision:int,online:bool,
    inspections:Set[View],approvals:Set[Approval],winner:int,visibleWinner:int,acks:Set[int],aliases:Set[Alias],permits:Set[Permit],
    uses:List[Use],spent:bool,everSpent:bool,calls:int,hold:int,usage:int}
  var s:State
  pure val original={id:10,root:10,parent:0,tip:0,content:100,allowed:true,claim:11,profile:20,budget:5,history:9}
  pure val external0=original.with("id",20).with("root",20).with("content",200).with("allowed",false)
  pure val continuation=original.with("id",11).with("parent",1).with("tip",20)
  pure val sibling=continuation.with("id",12)
  pure val second=original.with("id",12).with("parent",2).with("tip",11)
  pure val v1={generation:1,tip:20,fence:0,revision:0}
  pure val permit0={id:0,generation:0,fence:0,revision:0}
  pure val permit2={id:1,generation:2,fence:0,revision:0}
  pure val initial={staged:Set(original,external0),log:List(),generation:0,allowed:true,fence:0,revision:0,online:true,
    inspections:Set(),approvals:Set(),winner:-1,visibleWinner:-1,acks:Set(),aliases:Set(),permits:Set(permit0),uses:List(),spent:false,everSpent:false,calls:0,hold:6,usage:-1}
  def tip=if(s.log.length()==0)0 else s.log.nth(s.log.length()-1).change.id
  def effective=if(s.log.length()==0)true else s.log.nth(s.log.length()-1).change.allowed
  def view={generation:s.generation,tip:tip,fence:s.fence,revision:s.revision}
  pure def sameIntent(c)=c.root==10 and c.content==original.content and c.allowed==original.allowed and c.claim==original.claim and c.profile==original.profile and c.budget==original.budget and c.history==original.history
  def registered(c)=c==original or s.approvals.exists(a=>a.candidate==c)
  def approvalCurrent(c)=c==original or s.approvals.exists(a=>a.candidate==c and a.view==view and a.authorized)
  action init=s'=initial
  action stage(c,qualified)=all {qualified,c.root==10,s.staged.forall(old=>old.id!=c.id),s'=s.with("staged",s.staged.union(Set(c)))}
  action inspect(qualified)=all {s.online,s.winner == -1,s.log.indices().forall(i=>s.log.nth(i).change.root!=10),qualified,
    s'=s.with("inspections",s.inspections.union(Set(view)))}
  action approve(c,observed,authorized,durable)=all {s.staged.contains(c),s.staged.contains(original),c.id!=10,sameIntent(c),s.winner == -1,
    s.inspections.contains(observed),observed==view,original.parent<s.generation,c.parent==s.generation,c.tip==tip,s.online,authorized,durable,
    s'=s.with("approvals",s.approvals.union(Set({candidate:c,view:observed,authorized:authorized})))}
  action publish(c,worker,durable,policy)=all {s.staged.contains(c),registered(c),sameIntent(c),s.winner == -1,approvalCurrent(c),s.online,
    c.parent==s.generation,c.tip==tip,worker==s.fence,durable,policy,s.log.indices().forall(i=>s.log.nth(i).change.id!=c.id),
    s'=s.with("generation",s.generation+1).with("allowed",c.allowed).with("winner",c.id).with("visibleWinner",c.id)
      .with("log",s.log.append({change:c,generation:s.generation+1,actual:view,approval:view,reauthorized:true}))}
  action otherPublish(c,qualified)=all {qualified,c.root!=10,s.online,c.parent==s.generation,c.tip==tip,
    s.log.indices().forall(i=>s.log.nth(i).change.id!=c.id),s'=s.with("generation",s.generation+1).with("allowed",c.allowed)
      .with("log",s.log.append({change:c,generation:s.generation+1,actual:view,approval:view,reauthorized:true}))}
  action queryWinner(qualified)=all {qualified,s'=s.with("visibleWinner",s.winner)}
  action loseReply=s'=s.with("visibleWinner",-1)
  action ack(id)=all {s.log.indices().exists(i=>s.log.nth(i).change.id==id),s'=s.with("acks",s.acks.union(Set(id)))}
  action alias(protocol,task,root,qualified)=all {qualified,root==10,protocol>=1,protocol<=5,
    s'=s.with("aliases",s.aliases.union(Set({protocol:protocol,task:task,canonicalRoot:root})))}
  action restart=s'=s.with("online",false).with("fence",s.fence+1).with("revision",s.revision+1).with("visibleWinner",-1)
  action recover(qualified)=all {qualified,s'=s.with("online",true)}
  action ledgerWrite=s'=s.with("revision",s.revision+1)
  action issue=s'=s.with("permits",s.permits.union(Set({id:s.permits.size(),generation:s.generation,fence:s.fence,revision:s.revision})))
  action consume(p)=all {s.online,s.allowed,s.permits.contains(p),p.generation==s.generation,p.fence==s.fence,p.revision==s.revision,not(s.spent),
    s'=s.with("spent",true).with("everSpent",true).with("calls",s.calls+1).with("revision",s.revision+1)
      .with("uses",s.uses.append({permit:p,actual:view.with("generation",s.log.length()),allowed:effective}))}
  val originalRetained=s.staged.contains(original)
  val familyUnique=s.log.indices().filter(i=>s.log.nth(i).change.root==10).size()<=1
  val winnerBound=s.log.indices().forall(i=>s.log.nth(i).change.root==10 implies s.winner==s.log.nth(i).change.id) and
    (s.winner != -1 implies s.log.indices().exists(i=>s.log.nth(i).change.root==10 and s.log.nth(i).change.id==s.winner))
  val continuationBound=s.approvals.forall(a=>sameIntent(a.candidate) and a.authorized) and
    s.log.indices().forall(i=>{val r=s.log.nth(i)
      r.change.root==10 implies sameIntent(r.change) and r.reauthorized and r.approval==r.actual})
  val prefixBound=s.generation==s.log.length() and s.allowed==effective and s.log.indices().forall(i=>s.log.nth(i).change.parent==i)
  val aliasesBound=s.aliases.forall(a=>a.canonicalRoot==10)
  val accounting=s.calls<=1 and (s.everSpent implies s.spent) and (s.usage == -1 implies s.hold==6)
  val usesBound=s.uses.indices().forall(i=>{val u=s.uses.nth(i)
    u.allowed and u.permit.generation==u.actual.generation and u.permit.fence==u.actual.fence and u.permit.revision==u.actual.revision})
  val safety=originalRetained and familyUnique and winnerBound and continuationBound and prefixBound and aliasesBound and accounting and usesBound
  action step={
    nondet protocol=1.to(5).oneOf()
    nondet task=10.to(12).oneOf()
    any {stage(continuation,true),stage(sibling,true),inspect(true),approve(continuation,view,true,true),approve(sibling,view,true,true),
      publish(original,s.fence,true,true),publish(continuation,s.fence,true,true),publish(sibling,s.fence,true,true),otherPublish(external0,true),
      queryWinner(true),loseReply,ack(10),ack(11),alias(protocol,task,10,true),restart,recover(true),ledgerWrite,issue,consume(permit0)}
  }
  action conflicted=init.then(otherPublish(external0,true))
  action inspected=conflicted.then(inspect(true)).then(stage(continuation,true))
  action approved=inspected.then(approve(continuation,v1,true,true))
  action committed=approved.then(publish(continuation,0,true,true))
  action restarted=approved.then(restart).then(recover(true))
  action unknown=init.then(consume(permit0)).then(otherPublish(external0,true))
  run staleOriginalCannotPublishTest=conflicted.then(publish(original,0,true,true).fail())
  run inspectionNeedsQualifiedAbsenceTest=conflicted.then(inspect(false).fail())
  run freshInspectionDoesNotGrantUseTest=inspected.expect(safety and s.calls==0 and not(s.allowed))
  run originalPendingIntentIsRetainedTest=committed.expect(safety and s.staged.contains(original))
  run continuationRequiresFreshAuthorizationTest=inspected.then(approve(continuation,v1,false,true).fail())
  run continuationApprovalRequiresDurabilityTest=inspected.then(approve(continuation,v1,true,false).fail())
  run exactContinuationCanPublishTest=committed.expect(safety and s.winner==11 and s.generation==2)
  run staleApprovalAfterLedgerWriteTest=approved.then(ledgerWrite).then(publish(continuation,0,true,true).fail())
  run staleApprovalAfterFenceChangeTest=restarted.then(publish(continuation,1,true,true).fail())
  run staleInspectionAfterFenceChangeTest=inspected.then(restart).then(recover(true)).then(approve(continuation,v1,true,true).fail())
  run publishStillNeedsCurrentPolicyTest=approved.then(publish(continuation,0,true,false).fail())
  run publishNeedsDurableDecisionTest=approved.then(publish(continuation,0,false,true).fail())
  run changedContentCannotContinueTest=conflicted.then(inspect(true)).then(stage(continuation.with("content",999),true))
    .then(approve(continuation.with("content",999),v1,true,true).fail())
  run changedProfileCannotContinueTest=conflicted.then(inspect(true)).then(stage(continuation.with("profile",21),true))
    .then(approve(continuation.with("profile",21),v1,true,true).fail())
  run changedBudgetCannotContinueTest=conflicted.then(inspect(true)).then(stage(continuation.with("budget",99),true))
    .then(approve(continuation.with("budget",99),v1,true,true).fail())
  run changedHistoryCannotContinueTest=conflicted.then(inspect(true)).then(stage(continuation.with("history",99),true))
    .then(approve(continuation.with("history",99),v1,true,true).fail())
  run changedClaimCannotContinueTest=conflicted.then(inspect(true)).then(stage(continuation.with("claim",12),true))
    .then(approve(continuation.with("claim",12),v1,true,true).fail())
  run sameIDCannotReplacePendingTest=conflicted.then(stage(original.with("parent",1),true).fail())
  run wrongParentCannotAuthorizeTest=conflicted.then(inspect(true)).then(stage(continuation.with("parent",0),true))
    .then(approve(continuation.with("parent",0),v1,true,true).fail())
  run wrongTipCannotAuthorizeTest=conflicted.then(inspect(true)).then(stage(continuation.with("tip",999),true))
    .then(approve(continuation.with("tip",999),v1,true,true).fail())
  run unknownOriginalCommitCannotBecomeConflictTest=init.then(publish(original,0,true,true)).then(loseReply).then(inspect(true).fail())
  run lostWinnerReplyQueriesSameDecisionTest=committed.then(loseReply).then(queryWinner(true)).expect(safety and s.visibleWinner==11 and s.log.length()==2)
  run originalReplyLossCannotRepublishTest=init.then(publish(original,0,true,true)).then(loseReply).then(publish(original,0,true,true).fail())
  run twoApprovalsStillHaveOneWinnerTest=approved.then(stage(sibling,true)).then(approve(sibling,v1,true,true))
    .then(publish(continuation,0,true,true)).then(publish(sibling,0,true,true).fail())
  run winnerBlocksFreshContinuationTest=committed.then(stage(second,true)).then(approve(second,view,true,true).fail())
  run winnerBlocksNewAbsenceReadTest=committed.then(loseReply).then(inspect(true).fail())
  run lateAcknowledgementIsOnlyHistoryTest=committed.then(loseReply).then(ack(11)).expect(safety and s.winner==11 and s.generation==2)
  run newProtocolAliasPreservesPendingTest=conflicted.then(alias(1,10,10,true)).then(alias(2,11,10,true)).then(alias(3,12,10,true))
    .then(alias(4,12,10,true)).then(alias(5,10,10,true)).expect(safety and s.staged.contains(original) and s.winner == -1)
  run forgedCanonicalProtocolRootTest=conflicted.then(alias(2,12,99,true).fail())
  run aliasRequiresAuthenticatedRegistryTest=conflicted.then(alias(2,12,10,false).fail())
  run unknownCostSurvivesProtocolSwitchTest=unknown.then(alias(1,10,10,true)).then(alias(2,12,10,true)).expect(safety and s.hold==6 and s.spent)
  run reauthorizationDoesNotConsumeTest=approved.expect(safety and s.calls==0 and s.hold==6)
  run missingStageCannotContinueTest=conflicted.then(inspect(true)).then(approve(continuation,v1,true,true).fail())
  run newOwnerCanReauthorizeOriginalIntentTest=inspected.then(restart).then(recover(true)).then(inspect(true)).then(approve(continuation,view,true,true))
    .then(publish(continuation,1,true,true)).expect(safety)
  action unsafePublish(c,observed,authorized)=s'=s.with("generation",s.generation+1).with("allowed",c.allowed).with("winner",c.id)
    .with("log",s.log.append({change:c,generation:s.generation+1,actual:view,approval:observed,reauthorized:authorized}))
  action unsafeApprove(c)=s'=s.with("approvals",s.approvals.union(Set({candidate:c,view:view,authorized:true})))
  action unsafeAckReset=s'=s.with("generation",2).with("allowed",true)
  action unsafeProtocolReset=s'=s.with("spent",false).with("hold",0)
  action unsafeDropOriginal=s'=s.with("staged",s.staged.filter(c=>c.id!=10))
  run silentRebaseContinuationCounterexampleTest=inspected.then(unsafePublish(continuation,v1,false)).expect(not(continuationBound))
  run lostWinnerContinuationCounterexampleTest=init.then(publish(original,0,true,true)).then(loseReply)
    .then(stage(continuation.with("tip",10),true)).then(unsafeApprove(continuation.with("tip",10)))
    .then(unsafePublish(continuation.with("tip",10),view,true)).expect(not(familyUnique))
  run doubleContinuationContinuationCounterexampleTest=committed.then(stage(second,true)).then(unsafeApprove(second))
    .then(unsafePublish(second,view,true)).expect(not(familyUnique))
  run staleApprovalContinuationCounterexampleTest=approved.then(ledgerWrite).then(unsafePublish(continuation,v1,true)).expect(not(continuationBound))
  run semanticSwapContinuationCounterexampleTest=conflicted.then(inspect(true)).then(stage(continuation.with("profile",21),true))
    .then(unsafeApprove(continuation.with("profile",21)))
    .then(unsafePublish(continuation.with("profile",21),view,true)).expect(not(continuationBound))
  run lateAckContinuationCounterexampleTest=committed.then(issue).then(otherPublish(external0.with("id",21).with("parent",2).with("tip",11),true))
    .then(ack(11)).then(unsafeAckReset).then(consume(permit2)).expect(not(usesBound))
  run protocolResetContinuationCounterexampleTest=unknown.then(alias(2,12,10,true)).then(unsafeProtocolReset).expect(not(accounting))
  run droppedIntentContinuationCounterexampleTest=approved.then(unsafeDropOriginal).expect(not(originalRetained))
}
