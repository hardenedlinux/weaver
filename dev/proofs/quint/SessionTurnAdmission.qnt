// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

// Design obligation for the Session transaction. Fingerprints abstract
// exact byte commitments. Rust tests check their encoding, not this model.
module SessionTurnAdmission {
  type S = {key:int,body:int,principal:bool,source:int,scope:int,
    factRevision:int,prefix:int,available:bool,pending:bool,
    prepared:bool,preparedKey:int,preparedBody:int,preparedSource:int,
    preparedScope:int,preparedFacts:int,preparedPrefix:int,
    receipts:int -> int,receiptSource:int -> int,receiptScope:int -> int,
    registered:Set[int],maxTurns:int,budget:int,sent:Set[int],held:int,sends:int,unsafe:bool}
  var s:S
  val safe=s.held<=s.budget and s.registered.size()<=s.maxTurns and
    s.sends==s.sent.size() and not(s.unsafe)
  action init=s'={key:0,body:0,principal:true,source:0,scope:0,
    factRevision:0,prefix:0,available:true,pending:false,
    prepared:false,preparedKey:0,preparedBody:0,preparedSource:0,
    preparedScope:0,preparedFacts:0,preparedPrefix:0,
    receipts:Map(0 -> -1,1 -> -1),receiptSource:Map(0 -> -1,1 -> -1),
    receiptScope:Map(0 -> -1,1 -> -1),registered:Set(),maxTurns:2,budget:2,
    sent:Set(),held:0,sends:0,unsafe:false}
  val current=s.principal and s.available and not(s.pending)
  val sameCut=current and s.prepared and s.key==s.preparedKey and
    s.body==s.preparedBody and s.source==s.preparedSource and
    s.scope==s.preparedScope and s.factRevision==s.preparedFacts and
    s.prefix==s.preparedPrefix
  action prepare=all {current,
    s'=s.with("prepared",true).with("preparedKey",s.key)
      .with("preparedBody",s.body).with("preparedSource",s.source)
      .with("preparedScope",s.scope).with("preparedFacts",s.factRevision)
      .with("preparedPrefix",s.prefix)}
  // One write scope rechecks the source/fact cut and retains a unique decision.
  // Replays preserve the original row; changed bodies cannot replace it.
  val sameDecision=s.receipts.get(s.key)==s.body and
    s.receiptSource.get(s.key)==s.source and s.receiptScope.get(s.key)==s.scope
  action admit=all {sameCut,s.receipts.get(s.key)== -1 or sameDecision,
    s.registered.contains(s.key) or s.registered.size()<s.maxTurns,
    s'=s.with("receipts",s.receipts.set(s.key,s.body))
      .with("receiptSource",s.receiptSource.set(s.key,s.source))
      .with("receiptScope",s.receiptScope.set(s.key,s.scope))
      .with("registered",s.registered.union(Set(s.key)))}
  // A recovered projection conveys no permit. Commit still takes the same cut.
  action recover=all {sameCut,sameDecision,s'=s}
  // Reservations belong to the existing final-use owner, not the pure contract.
  // Both turn origins still require the parent Session's current hard facts.
  action send=all {current,sameDecision,
    not(s.sent.contains(s.key)),s.held<s.budget,
    s'=s.with("sent",s.sent.union(Set(s.key))).with("held",s.held+1)
      .with("sends",s.sends+1)}
  action changeBody=s'=s.with("body",1-s.body)
  action nextTurn=s'=s.with("key",1-s.key).with("prepared",false)
  action wrongPrincipal=s'=s.with("principal",false)
  action rotateSource=s'=s.with("source",s.source+1)
  action replaceScope=s'=s.with("scope",s.scope+1)
  action stageFact=s'=s.with("pending",true).with("prefix",s.prefix+1)
  action resolveFact=s'=s.with("pending",false).with("factRevision",s.factRevision+1)
  action withdraw=s'=s.with("available",false).with("factRevision",s.factRevision+1)
  // Restart discards transient derivations and retains decisions/claims/holds.
  action restart=s'=s.with("prepared",false)
  action oneTurnOnly=all {s.registered.size()==0,s'=s.with("maxTurns",1)}
  action oneUnitBudget=all {s.held==0,s'=s.with("budget",1)}
  action observe=s'=s
  action dropParentFactBinding=all {not(current),s.receipts.get(s.key)==s.body,
    not(s.sent.contains(s.key)),s'=s.with("unsafe",true)}
  action step=any {prepare,admit,recover,send,changeBody,nextTurn,wrongPrincipal,
    rotateSource,replaceScope,stageFact,resolveFact,withdraw,restart,
    oneTurnOnly,oneUnitBudget,observe}
  action admitted=init.then(prepare).then(admit)
  run retainedReplayAfterRestartTest=admitted.then(send).then(restart)
    .then(prepare).then(recover).then(admit)
    .expect(safe and s.registered.size()==1 and s.held==1 and s.sends==1)
  run withdrawalAfterRecoveryBlocksCommitTest=admitted.then(prepare)
    .then(recover).then(withdraw).then(admit.fail())
  run changedBytesCannotRecoverTest=admitted.then(changeBody).then(prepare)
    .then(recover.fail())
  run changingTurnsShareBudgetTest=admitted.then(send).then(nextTurn)
    .then(prepare).then(admit).then(send).expect(safe and s.held==2 and s.sends==2)
  run repeatedTriggerCannotSendTwiceTest=admitted.then(send).expect(safe).then(send.fail())
  run changedRetryBodyConflictsTest=admitted.then(changeBody).then(prepare).then(admit.fail())
  run sourceChangedDuringDerivationTest=init.then(prepare).then(rotateSource).then(admit.fail())
  run scopeChangedDuringDerivationTest=init.then(prepare).then(replaceScope).then(admit.fail())
  run pendingIntentBlocksCommitTest=init.then(prepare).then(stageFact).then(admit.fail())
  run resolvedIntentStillInvalidatesCutTest=init.then(prepare).then(stageFact)
    .then(resolveFact).then(admit.fail())
  run withdrawnParentBlocksAdmittedTurnTest=admitted.then(withdraw).then(send.fail())
  run rotatedSourceBlocksAdmittedTurnTest=admitted.then(rotateSource).then(send.fail())
  run replacedScopeBlocksAdmittedTurnTest=admitted.then(replaceScope).then(send.fail())
  run exhaustedTurnLimitBlocksNewDecisionTest=init.then(oneTurnOnly).then(prepare)
    .then(admit).then(nextTurn).then(prepare).then(admit.fail())
  run exhaustedSharedBudgetBlocksSecondTurnTest=init.then(oneUnitBudget).then(prepare)
    .then(admit).then(send).then(nextTurn).then(prepare).then(admit).then(send.fail())
  run restartKeepsOriginalDecisionTest=admitted.then(send).then(restart)
    .then(prepare).then(admit).expect(safe and s.held==1).then(send.fail())
  run restartKeepsSharedBudgetAcrossTurnsTest=admitted.then(send).then(restart)
    .then(nextTurn).then(prepare).then(admit).then(send)
    .expect(safe and s.held==2 and s.sends==2 and s.registered.size()==2)
  run restartedWithdrawalBlocksNextPreparationTest=admitted.then(send).then(restart)
    .then(withdraw).then(nextTurn).then(prepare.fail())
  run restartLosesTransientPreparationTest=init.then(prepare).then(restart).then(admit.fail())
  run forgedPrincipalCannotPrepareTest=init.then(wrongPrincipal).then(prepare.fail())
  run missingParentBindingCounterexampleTest=admitted.then(withdraw)
    .then(dropParentFactBinding).expect(not(safe))
}
