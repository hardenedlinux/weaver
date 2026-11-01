module AuthorityPublication {
  import ProviderRpc as E from "./ProviderRpc"
  import PublicationRecovery as A from "./PublicationRecovery"
  // Go activation composes existing publication and execution models. It does
  // not redeclare their CAS, nonce, budget or Cedar semantics.
  // Read witnesses refine the existing owners; they allocate no second ledger.
  // assignment denotes the authenticated original profile/claim/domain tuple.
  // Its native payload authentication is an explicit refinement obligation.
  type ReadView={revision:int,fence:int,assignment:int,stage:int,held:int,next:int,domainCut:int,pending:Set[int]}
  type ReadUse={read:ReadView,actual:ReadView}
  // externalCalls is a trace observer outside the modeled store rollback, not
  // an implemented counter service or a second accounting owner.
  type Control={compiled:int,desired:int,parent:int,capturedParent:int,callerParent:int,requestedFence:int,registered:bool,ack:bool,active:bool,reads:Set[ReadView],uses:List[ReadUse],externalCalls:int,submits:int,effectPending:List[Set[int]],birthUses:List[int]}
  var c:Control
  val original=A::authority.records.get(0)
  val resolved=A::authority.pending==Set()
  val pendingIds=A::authority.pending.map(q=>q.id)
  val taskAuthorized=c.registered and original.outcome==1
  val actualView={revision:A::authority.head,fence:A::authority.fence,assignment:0,stage:E::s.stage,held:E::s.held,next:E::s.next,domainCut:E::s.domainCut,pending:pendingIds}
  val safe=E::safe and A::safe and E::s.calls==c.externalCalls and c.uses.indices().forall(i=>c.uses.nth(i).read==c.uses.nth(i).actual) and
    (c.compiled>=0 implies c.parent==c.capturedParent) and
    c.submits<=1 and c.effectPending.indices().forall(i=>c.effectPending.nth(i)==Set()) and
    c.birthUses.indices().forall(i=>c.birthUses.nth(i)==1) and
    (c.active implies c.compiled>=0 and c.registered and original.outcome==1 and original.payload==c.compiled and c.ack) and
    (A::authority.head>=0 implies E::s.revision==A::authority.head and E::s.fence==A::authority.fence)
  action init=all {E::init,A::init,c'={compiled:-1,desired:0,parent:-1,capturedParent:-1,callerParent:-1,requestedFence:1,registered:false,ack:false,active:false,reads:Set(),uses:List(),externalCalls:0,submits:0,effectPending:List(),birthUses:List()}}
  action stageIntent(id:int):bool=all {A::authority.head>=0,
    A::stage({id:id,payload:1,parent:A::authority.head,fence:A::authority.fence+1}),c'=c,E::observe}
  action decideIntent(id:int):bool={nondet q=A::authority.pending.filter(p=>p.id==id).oneOf()
    all {A::publish(q.id,q.payload,q.parent,q.fence),c'=c,
      if(q.parent==A::authority.head and q.fence>=A::authority.fence) E::publish else E::observe}}
  // Concrete source admission is witnessed by Scheme/FFI/Go tests, not a
  // duplicate Boolean implementation of those validators in this model.
  action compile(accepted:bool):bool=all {accepted,c.compiled<0,c'=c.with("compiled",c.desired).with("parent",A::authority.head).with("capturedParent",A::authority.head).with("callerParent",A::authority.head)
    .with("requestedFence",A::authority.fence+(if(A::authority.head>=0)1 else 0)),E::observe,A::observe}
  action editSource=all {c'=c.with("desired",1),E::observe,A::observe}
  // The caller may change its own storage after the initial stable copy. This
  // cannot rebase the frozen proposal between staging and final CAS.
  action editCallerParent(parent:int):bool=all {c'=c.with("callerParent",parent),E::observe,A::observe}
  action unsafeBorrowedParent=all {c'=c.with("parent",c.callerParent),E::observe,A::observe}
  action stageOriginal=all {c.compiled>=0,A::stage({id:0,payload:c.compiled,parent:c.parent,fence:c.requestedFence}),c'=c,E::observe}
  action register=all {c.compiled>=0,(pendingIds.contains(0) or original.outcome==1),c'=c.with("registered",true),E::observe,A::observe}
  action unsafeRegisterBeforeStage=all {c.compiled>=0,c'=c.with("registered",true),E::observe,A::observe}
  // A known durable outcome is observed, never submitted again by bootstrap.
  action commit=all {c.registered,original.outcome==0,
    A::publish(0,c.compiled,c.parent,c.requestedFence),c'=c.with("submits",c.submits+1),
    if(c.parent==A::authority.head and c.requestedFence>=A::authority.fence and A::authority.head>=0)E::publish else E::observe}
  action inspectMissing=all {c.compiled>=0,original.outcome==0,c'=c,E::observe,A::observe}
  action inspectUnavailable=all {c'=c,E::observe,A::observe}
  action acknowledge=all {original.outcome==1,original.payload==c.compiled,c'=c.with("ack",true),E::observe,A::observe}
  action recover(source:int):bool=all {original.outcome==1,source==c.compiled,A::replay(0,source,c.parent,c.requestedFence),c'=c.with("ack",true),E::observe}
  action activate=all {original.outcome==1,c.ack,original.payload==c.compiled,c'=c.with("active",true),E::observe,A::observe}
  action loseReply=all {c'=c.with("ack",false).with("active",false),E::observe,A::observe}
  action restart=all {c'=c.with("active",false).with("ack",false).with("reads",Set()),E::crash,A::restart}
  action publish={nondet id=Set(1,2).oneOf()
    all {A::authority.head>=0,A::authority.records.get(id).outcome==0,A::publish(id,1,A::authority.head,A::authority.fence+1),c'=c,E::publish}}
  action transport=all {c'=c,E::observe,A::observe}
  action admit=all {c.active,resolved,c'=c,E::admit(0),A::observe}
  action consume=all {c.active,resolved,c'=c,E::consume(0),A::observe}
  action burn=all {c.active,resolved,c'=c,E::burn,A::observe}
  action invoke=all {c.active,resolved,c'=c.with("externalCalls",c.externalCalls+1).with("effectPending",c.effectPending.append(pendingIds)),E::invoke,A::observe}
  action release=all {c.active,resolved,c'=c.with("effectPending",c.effectPending.append(pendingIds)),E::batch(1,0),A::observe}
  action unsafePendingRelease=all {c.active,c'=c.with("effectPending",c.effectPending.append(pendingIds)),E::batch(1,0),A::observe}
  // Another operation-role worker is not gated by this Go process's active flag.
  action operationWorkerAdmit=all {taskAuthorized,resolved,c'=c.with("birthUses",c.birthUses.append(original.outcome)),E::admit(0),A::observe}
  action unsafeTaskBirthOmission=all {c.registered,resolved,c'=c.with("birthUses",c.birthUses.append(original.outcome)),E::admit(0),A::observe}
  action seedOldAllowingImage=all {A::publish(1,0,-1,1),c'=c,E::observe}
  action publishOtherAllowingImage=all {A::publish(2,0,A::authority.head,A::authority.fence+1),c'=c,E::restorePolicy}
  action currentProposal=all {E::observeCurrentProposal,c'=c,A::observe}
  action deliver=all {c'=c,E::deliver,A::observe}
  // Abstract an authenticated non-Policy budget/history deciding-cut change,
  // never a Go watch event. Concrete four-prefix projection remains a premise.
  action domainChange=all {c'=c,E::advanceDomainCut,A::observe}
  action readCurrent=all {c'=c.with("reads",c.reads.union(Set(actualView))),E::observe,A::observe}
  action consumeRead(v:ReadView):bool=all {c.active,resolved,c.reads.contains(v),v==actualView,
    c'=c.with("uses",c.uses.append({read:v,actual:actualView})),E::consume(0),A::observe}
  action releaseRead(v:ReadView):bool=all {c.active,resolved,c.reads.contains(v),v==actualView,
    c'=c.with("uses",c.uses.append({read:v,actual:actualView})),E::batch(1,0),A::observe}
  action unsafeReadUse(v:ReadView):bool=all {c.reads.contains(v),
    c'=c.with("uses",c.uses.append({read:v,actual:actualView})),E::unsafeStaleRelease,A::observe}
  action step={nondet v=c.reads.union(Set(actualView)).oneOf()
    any {compile(true),editSource,editCallerParent(-1),editCallerParent(0),editCallerParent(1),stageOriginal,register,commit,inspectMissing,inspectUnavailable,acknowledge,recover(0),recover(1),activate,loseReply,restart,publish,stageIntent(1),stageIntent(2),decideIntent(1),decideIntent(2),currentProposal,operationWorkerAdmit,domainChange,transport,admit,consume,burn,invoke,release,deliver,readCurrent,consumeRead(v),releaseRead(v)}}
  action prepared=init.then(compile(true)).then(stageOriginal).then(register)
  action ready=prepared.then(commit).then(acknowledge).then(activate)
  action spent=ready.then(admit).then(consume).then(burn).then(invoke)
  action unsafeRecoverDesired=all {original.outcome==1,c'=c.with("compiled",c.desired).with("ack",true).with("active",true),E::observe,A::observe}
  action unsafeActivateWithoutOutcome=all {c'=c.with("active",true),E::observe,A::observe}
  action unsafeRetry=all {c'=c,E::unsafeRetryReset,A::observe}
  action unnecessaryKnownOutcomeReplay=all {original.outcome==1,A::replay(0,c.compiled,-1,1),c'=c.with("submits",c.submits+1),E::observe}
  action unsafeSnapshotRollback=all {E::unsafeRestoreQueuedImage,A::observe,
    c'=c.with("ack",false).with("active",false).with("reads",Set()).with("uses",List())}
  run authorityUncompiledSourceCannotRegisterTest=init.then(register.fail())
  run authorityRejectedSourceCannotCompileTest=init.then(compile(false).fail())
  run authoritySourceCommitNeverSendsTest=prepared.then(commit).expect(safe and E::s.calls==0 and E::s.held==0)
  run authorityLostReplyCannotActivateTest=prepared.then(commit).then(loseReply).then(activate.fail())
  run authorityLostReplyAndOwnerRestartPreserveOutcomeTest=prepared.then(commit).then(loseReply).then(restart).then(recover(0)).then(activate).expect(safe and original.payload==0 and E::s.calls==0)
  run authorityKnownOutcomeRecoveryDoesNotSubmitTest=ready.then(restart).then(recover(0)).then(activate).expect(safe and c.submits==1)
  run authorityMissingInspectionDoesNotAbortLateCommitTest=prepared.then(inspectMissing).then(commit).then(recover(0)).then(activate).expect(safe and c.submits==1)
  run authorityUnavailableInspectionDoesNotActivateTest=prepared.then(commit).then(loseReply).then(inspectUnavailable).expect(safe).then(activate.fail())
  // Rust idempotent replay remains safe. This witnesses a violation of the
  // narrower Go bootstrap contract: recovery of a known decision must be read-only.
  run authorityKnownOutcomeReplayContractCounterexampleTest=ready.then(unnecessaryKnownOutcomeReplay).expect(not(safe) and A::safe and E::safe)
  run authorityChangedCompiledSourceCannotRecoverTest=prepared.then(commit).then(editSource).then(recover(1).fail())
  run authorityEditingFileCannotRewriteFrozenCommandTest=prepared.then(editSource).then(commit).then(acknowledge).then(activate).expect(safe and original.payload==0 and c.desired==1)
  run authorityHistoricalReceiptCannotOverrideRevocationTest=ready.then(publish).then(restart).then(recover(0)).then(activate).then(admit.fail())
  run authorityPartialReleaseRevokeAndDualRestartTest=spent.then(release).then(publish).then(restart).then(recover(0)).then(activate).expect(safe and E::s.held==4 and E::s.calls==1).then(release.fail())
  run authoritySdkRetryDoesNotCreateFreshRootTest=spent.then(transport).then(restart).then(recover(0)).then(activate).then(admit.fail())
  run authorityDesiredSourceRecoveryCounterexampleTest=prepared.then(commit).then(editSource).then(unsafeRecoverDesired).expect(not(safe))
  run authorityActivateWithoutOutcomeCounterexampleTest=prepared.then(unsafeActivateWithoutOutcome).expect(not(safe))
  run authorityRetryResetCounterexampleTest=spent.then(unsafeRetry).then(consume).then(burn).then(invoke).expect(not(safe))
  val queuedView={revision:0,fence:1,assignment:0,stage:1,held:4,next:0,domainCut:0,pending:Set()}
  val streamView={revision:0,fence:1,assignment:0,stage:2,held:4,next:0,domainCut:0,pending:Set()}
  run authorityReadBeforeNewCommitCannotConsumeTest=ready.then(admit).then(readCurrent).then(publish).expect(safe).then(consumeRead(queuedView).fail())
  run authorityReadBeforeClaimAdmissionIsStaleTest=ready.then(readCurrent).then(admit)
    .expect(safe).then(consumeRead({revision:0,fence:1,assignment:0,stage:0,held:0,next:0,domainCut:0,pending:Set()}).fail())
  run authorityRestartDiscardsReadWitnessTest=ready.then(admit).then(readCurrent).then(restart).then(recover(0)).then(activate).expect(safe).then(consumeRead(queuedView).fail())
  run authorityLostReplyRecoveryNeedsFreshReadTest=ready.then(admit).then(readCurrent).then(loseReply).then(restart).then(recover(0)).then(activate).then(readCurrent).then(consumeRead(queuedView)).expect(safe and E::s.calls==0 and E::s.held==4)
  run authorityPartialReleaseChangesHistoryViewTest=spent.then(readCurrent).then(releaseRead(streamView)).expect(safe and E::s.next==1 and E::s.held==4).then(releaseRead(streamView).fail())
  run authorityReadCannotRelabelAssignmentTest=ready.then(admit).then(readCurrent).expect(safe).then(consumeRead(queuedView.with("assignment",1)).fail())
  run authorityBudgetHistoryChangeInvalidatesQueuedReadTest=ready.then(admit).then(readCurrent).then(domainChange).expect(safe).then(consumeRead(queuedView).fail())
  run authorityBudgetHistoryChangeInvalidatesReleaseReadTest=spent.then(readCurrent).then(domainChange).expect(safe).then(releaseRead(streamView).fail())
  run authorityHistoricalReadCounterexampleTest=spent.then(readCurrent).then(publish).then(unsafeReadUse(streamView)).expect(not(safe))
  run authorityPartialHistoryReadCounterexampleTest=spent.then(readCurrent).then(release).then(unsafeReadUse(streamView)).expect(not(safe))
  run authorityWholeStoreRollbackCounterexampleTest=spent.then(unsafeSnapshotRollback).expect(not(safe) and c.externalCalls==1 and E::s.calls==0 and A::authority.head==0)
  run authorityPublicationFloorAloneCounterexampleTest=spent.then(unsafeSnapshotRollback).then(recover(0)).then(activate).then(readCurrent)
    .then(consumeRead(queuedView)).then(burn).then(invoke).expect(not(safe) and A::authority.head==0 and c.externalCalls==2 and E::s.calls==1)
  run authorityPendingBlocksOldReadTest=ready.then(admit).then(readCurrent).then(stageIntent(1))
    .expect(safe).then(consumeRead(queuedView).fail())
  run authorityPendingLostReplyAndRestartRetainBarrierTest=spent.then(stageIntent(1)).then(loseReply).then(restart)
    .then(recover(0)).then(activate).expect(safe and pendingIds==Set(1) and E::s.held==4).then(release.fail())
  run authorityOneDecisionCannotClearSiblingTest=ready.then(stageIntent(1)).then(stageIntent(2)).then(decideIntent(1))
    .expect(safe and pendingIds==Set(2)).then(decideIntent(2))
    .expect(safe and resolved and A::authority.records.get(2).outcome==2)
  run authorityPendingGuardOmissionCounterexampleTest=spent.then(stageIntent(1)).then(unsafePendingRelease).expect(not(safe))
  run authorityTaskCannotRegisterBeforeStageTest=init.then(seedOldAllowingImage).then(compile(true)).then(register.fail())
  run authorityPendingBirthBlocksOldOperationWorkerTest=init.then(seedOldAllowingImage).then(compile(true))
    .then(unsafeRegisterBeforeStage).expect(safe).then(operationWorkerAdmit.fail())
  run authorityRegistrationAsActivationCounterexampleTest=init.then(seedOldAllowingImage).then(compile(true))
    .then(unsafeRegisterBeforeStage).then(unsafeTaskBirthOmission).expect(not(safe))
  action rejectedBirth=init.then(seedOldAllowingImage).then(compile(true)).then(stageOriginal).then(register)
    .then(publishOtherAllowingImage).then(commit).then(currentProposal)
  run authorityRejectedBirthCannotUseOtherCurrentPolicyTest=rejectedBirth.expect(safe and resolved and original.outcome==2)
    .then(operationWorkerAdmit.fail())
  run authorityRejectedBirthGuardOmissionCounterexampleTest=rejectedBirth.then(unsafeTaskBirthOmission).expect(not(safe))
  run authorityCallerMutationCannotRebaseFrozenProposalTest=init.then(compile(true)).then(stageOriginal).then(register)
    .then(editCallerParent(1)).then(commit).then(loseReply).then(recover(0)).then(activate)
    .expect(safe and c.parent == -1 and original.parent == -1 and c.submits==1)
  run authorityBorrowedParentCounterexampleTest=init.then(compile(true)).then(stageOriginal).then(register)
    .then(editCallerParent(1)).then(unsafeBorrowedParent).expect(not(safe))
}
