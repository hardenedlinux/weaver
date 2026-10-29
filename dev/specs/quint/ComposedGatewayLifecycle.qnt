// Four admitted canonical messages, two overlapping accounts, one bounded
// exposure range per message. Lean additionally starts from the empty ledger.
module ComposedGatewayLifecycle {
  type Request = {op:int,head:int,source:int,target:int,binding:int}
  type Result = {present:bool,request:Request,committed:bool,head:int}
  type World = {head:int,epoch:int,online:bool,localHead:int,localClaims:int,localHeld:int,
    sealPresent:bool,sealed:Request,ownerOpen:bool,ownerEpoch:int,inc:int,ready:bool,
    results:int -> Result,commands:Set[int],decisions:int -> int,
    claimed:int -> int,token:int -> int,held:int -> int,restricted:int -> bool,
    accepted:Set[int],pending:Set[int],accepts:int -> int,exposures:int -> int,bufferEpoch:int -> int,
    localHistory:int -> bool,known:int,violations:int}
  var s:World
  pure val messages = 0.to(3)
  pure val operations = 0.to(3)
  pure val cmdIds = 0.to(7)
  pure def req(op,h,e) = {op:op,head:h,source:e,target:10+op,binding:100+op}
  pure val emptyRequest = req(0,0,0)
  pure val absent = {present:false,request:emptyRequest,committed:false,head:0}
  pure def account(k) = k % 2
  action init = s' = {head:0,epoch:0,online:true,localHead:0,localClaims:4,localHeld:8,
    sealPresent:false,sealed:emptyRequest,ownerOpen:true,ownerEpoch:0,inc:0,ready:true,
    results:operations.mapBy(_ => absent),commands:Set(),decisions:operations.mapBy(_ => 0),
    claimed:messages.mapBy(_ => 1),token:messages.mapBy(k => k),held:messages.mapBy(_ => 2),
    restricted:Set(0,1).mapBy(_ => false),accepted:Set(),pending:Set(),accepts:messages.mapBy(_ => 0),
    exposures:messages.mapBy(_ => 0),bufferEpoch:messages.mapBy(_ => 0),
    localHistory:Set(0,1).mapBy(_ => false),known:-1,violations:0}
  def recovered = s.online and s.localHead == s.head and s.localClaims == 4 and s.localHeld == 8 and
    s.localHistory == s.restricted
  def ownerReady = recovered and s.ready
  def canSeal(r) = ownerReady and s.ownerOpen and not(s.sealPresent) and
    not(s.results.get(r.op).present) and r.head == s.head and r.source == s.epoch and
    r.target == 10+r.op and r.binding == 100+r.op
  action seal(r) = all {canSeal(r),s' = s.with("ownerOpen",false).with("sealPresent",true).with("sealed",r)}
  def canDecide(cid,r) = s.online and not(s.ownerOpen) and s.sealPresent and s.sealed == r and
    r.head == s.head and r.source == s.epoch and not(s.results.get(r.op).present) and not(s.commands.contains(cid))
  pure def decision(w,cid,r,yes) = w.with("head",w.head+1)
    .with("epoch",if (yes) w.epoch+1 else w.epoch)
    .with("results",w.results.set(r.op,{present:true,request:r,committed:yes,head:w.head+1}))
    .with("commands",w.commands.union(Set(cid))).with("decisions",w.decisions.set(r.op,w.decisions.get(r.op)+1))
  action commit(cid,r) = all {canDecide(cid,r),s' = decision(s,cid,r,true)}
  action abort(cid,r) = all {canDecide(cid,r),s' = decision(s,cid,r,false)}
  def canActivate(r,inc) = ownerReady and not(s.ownerOpen) and s.sealPresent and s.sealed == r and
    s.results.get(r.op).present and s.results.get(r.op).committed and
    s.results.get(r.op).request == r and s.results.get(r.op).head == s.head and
    r.source+1 == s.epoch and s.ownerEpoch < s.epoch and inc == s.inc
  action activate(r,inc) = all {canActivate(r,inc),s' = s.with("ownerOpen",true)
    .with("ownerEpoch",s.epoch).with("sealPresent",false)}
  action recoverHost = all {s.online,s' = s.with("localHead",s.head).with("localClaims",4)
    .with("localHeld",8).with("localHistory",s.restricted)}
  action rollbackHost = s' = s.with("localHead",0).with("localClaims",4).with("localHeld",8)
    .with("localHistory",Set(0,1).mapBy(_ => false)).with("known",-1)
  action restartOwner = s' = s.with("inc",s.inc+1).with("ready",false)
  action recoverOwner = all {recovered,s' = s.with("ready",true)}
  action partition = s' = s.with("online",false)
  action reconnect = s' = s.with("online",true)
  action loseReply = s' = s.with("known",-1)
  action lookup(r) = all {s.online,s.results.get(r.op).present,s.results.get(r.op).request == r,
    s' = s.with("known",r.op)}
  action lookupMissing(op) = all {s.online,not(s.results.get(op).present),s' = s.with("known",-1)}
  def canDelegate(k,t,e,inc) = ownerReady and s.ownerOpen and s.ownerEpoch == s.epoch and
    e == s.epoch and inc == s.inc and not(s.accepted.contains(k)) and s.claimed.get(k) == 1 and
    t == s.token.get(k) and s.held.get(k) == 2 and not(s.restricted.get(account(k)))
  pure def delegated(w,k) = w.with("accepted",w.accepted.union(Set(k)))
    .with("pending",w.pending.union(Set(k))).with("accepts",w.accepts.set(k,w.accepts.get(k)+1)).with("bufferEpoch",w.bufferEpoch.set(k,w.epoch))
  action delegate(k,t,e,inc) = all {canDelegate(k,t,e,inc),s' = delegated(s,k)}
  // Consume the unique original driver capability, never query a send-count oracle.
  action drain(k) = all {s.accepted.contains(k),s.pending.contains(k),
    s' = s.with("pending",s.pending.exclude(Set(k))).with("exposures",s.exposures.set(k,s.exposures.get(k)+1))}
  action restrict(h) = all {s.ownerOpen,s' = s.with("head",s.head+1).with("restricted",s.restricted.set(h,true))}
  // Observation/new issuer/reconnect carry no fresh message, hold or range.
  action observe(k) = all {messages.contains(k),s' = s}
  action step = {
    nondet op = operations.oneOf()
    nondet cid = cmdIds.oneOf()
    nondet k = messages.oneOf()
    nondet h = Set(0,1).oneOf()
    val r = req(op,s.head,s.epoch)
    any {seal(r),commit(cid,s.sealed),abort(cid,s.sealed),activate(s.sealed,s.inc),
      recoverHost,rollbackHost,restartOwner,recoverOwner,partition,reconnect,loseReply,
      lookup(s.sealed),lookupMissing(op),delegate(k,k,s.epoch,s.inc),drain(k),restrict(h),observe(k)}
  }
  val journalSafety = operations.forall(op => s.decisions.get(op) <= 1 and
    (s.results.get(op).present iff s.decisions.get(op) == 1))
  val identitySafety = messages.forall(k => s.claimed.get(k) == 1 and s.token.get(k) == k and s.held.get(k) == 2)
  val budgetSafety = Set(0,1).forall(h => messages.filter(k => account(k) == h).fold(0,(sum,k) => sum+s.held.get(k)) == 4)
  val rangeSafety = messages.forall(k => s.accepts.get(k) <= 1 and s.exposures.get(k) <= s.accepts.get(k) and
    s.exposures.get(k) <= 1 and (s.pending.contains(k) implies s.exposures.get(k) == 0) and (s.accepted.contains(k) iff s.accepts.get(k) > 0))
  val ownerSafety = s.ownerOpen implies (s.ownerEpoch == s.epoch and not(s.sealPresent))
  val safety = journalSafety and identitySafety and budgetSafety and rangeSafety and ownerSafety and s.violations == 0

  // Deliberately excluded transitions. Counters remain historical observations.
  action commitOtherSeal(cid,r) = all {s.sealPresent,not(s.ownerOpen),not(s.results.get(r.op).present),
    s' = decision(s,cid,r,true).with("violations",s.violations+1)}
  action activateOtherReceipt(r) = all {ownerReady,s.results.get(s.sealed.op).committed,
    s' = s.with("ownerOpen",true).with("ownerEpoch",s.epoch).with("sealPresent",false)
      .with("violations",s.violations+(if (r == s.sealed) 0 else 1))}
  action forgetRangesOnRestart = s' = s.with("accepted",Set()).with("ready",true).with("inc",s.inc+1)
  action delegateIgnoringHistory(k) = all {ownerReady,s.ownerOpen,not(s.accepted.contains(k)),
    s' = delegated(s,k).with("violations",s.violations+(if (s.restricted.get(account(k))) 1 else 0))}
  action emptyRecovery = s' = s.with("held",messages.mapBy(_ => 0)).with("localHeld",0)
  action rebindClaim(k,t) = s' = s.with("token",s.token.set(k,t))
  action reopenPendingSeal = s' = s.with("ownerOpen",true)
  action rebuildTransportQueue(k) = s' = s.with("pending",s.pending.union(Set(k)))
  action rawFdBypass(k) = s' = s.with("exposures",s.exposures.set(k,s.exposures.get(k)+1))
  action duplicateCommit(cid,r) = s' = decision(s,cid,r,true)

  run lostCommitReplyTest = init.then(seal(req(0,0,0))).then(commit(0,req(0,0,0)))
    .then(loseReply).then(rollbackHost).then(restartOwner).then(lookup(req(0,0,0)))
    .then(recoverHost).then(recoverOwner).then(activate(req(0,0,0),1)).expect(safety and s.epoch == 1)
  run competingCommitRejectedTest = init.then(seal(req(0,0,0))).then(commit(1,req(1,0,0)).fail())
  run competingSealRejectedTest = init.then(seal(req(0,0,0))).then(seal(req(1,0,0)).fail())
  run wrongActivationRejectedTest = init.then(seal(req(0,0,0))).then(commit(0,req(0,0,0)))
    .then(recoverHost).then(activate(req(1,0,0),0).fail())
  run newCommandRetryRejectedTest = init.then(seal(req(0,0,0))).then(commit(0,req(0,0,0)))
    .then(commit(1,req(0,0,0)).fail())
  run abortAndLateCommitRejectedTest = init.then(seal(req(0,0,0))).then(abort(0,req(0,0,0)))
    .then(loseReply).then(commit(1,req(0,0,0)).fail())
  run missingIsNotAbortTest = init.then(seal(req(0,0,0))).then(lookupMissing(0))
    .then(commit(0,req(0,0,0))).expect(safety and s.results.get(0).committed)
  run restartBeforeCommitTest = init.then(seal(req(0,0,0))).then(restartOwner)
    .then(commit(0,req(0,0,0))).then(recoverHost).then(recoverOwner).then(activate(req(0,0,0),1)).expect(safety)
  run staleActivationIncarnationRejectedTest = init.then(seal(req(0,0,0))).then(commit(0,req(0,0,0)))
    .then(restartOwner).then(recoverHost).then(recoverOwner).then(activate(req(0,0,0),0).fail())
  run restartRetainsDelegationTest = init.then(delegate(0,0,0,0)).then(loseReply).then(restartOwner)
    .then(recoverOwner).then(drain(0)).expect(safety and s.exposures.get(0) == 1)
    .then(delegate(0,0,0,1).fail())
  run restartRejectsOldHandleTest = init.then(restartOwner).then(recoverOwner).then(delegate(0,0,0,0).fail())
  run sharedHistoryBlocksOtherMessageTest = init.then(restrict(0)).then(recoverHost).then(delegate(2,2,0,0).fail())
  run staleHostAfterRestrictionRejectedTest = init.then(restrict(0)).then(rollbackHost).then(delegate(2,2,0,0).fail())
  run oldBufferCanDrainAfterRestartAndMigrationTest = init.then(delegate(0,0,0,0)).then(seal(req(0,0,0)))
    .then(commit(0,req(0,0,0))).then(restartOwner).then(recoverHost).then(recoverOwner)
    .then(activate(req(0,0,0),1)).then(drain(0)).then(observe(0))
    .expect(safety and s.exposures.get(0) == 1 and s.bufferEpoch.get(0) < s.epoch)
  run lostSealReplyAcrossRestartTest = init.then(seal(req(0,0,0))).then(loseReply).then(restartOwner)
    .then(lookupMissing(0)).then(commit(0,req(0,0,0))).then(recoverHost).then(recoverOwner)
    .then(activate(req(0,0,0),1)).expect(safety and s.epoch == 1)
  run lostActivateReplyAcrossRestartTest = init.then(seal(req(0,0,0))).then(commit(0,req(0,0,0)))
    .then(recoverHost).then(activate(req(0,0,0),0)).then(loseReply).then(restartOwner)
    .then(lookup(req(0,0,0))).then(recoverOwner).expect(safety and s.ownerEpoch == 1)
    .then(activate(req(0,0,0),1).fail())
  run sealWinsAgainstDelegationTest = init.then(seal(req(0,0,0))).then(delegate(0,0,0,0).fail())
  run freshNonceCannotReplaceOriginalClaimTest = init.then(delegate(0,100,0,0).fail())
  run wrongSealCounterexampleTest = init.then(seal(req(0,0,0))).then(commitOtherSeal(1,req(1,0,0))).expect(not(safety))
  run wrongReceiptCounterexampleTest = init.then(seal(req(0,0,0))).then(commit(0,req(0,0,0)))
    .then(recoverHost).then(activateOtherReceipt(req(1,0,0))).expect(not(safety))
  run forgettingOwnerRecordsCounterexampleTest = init.then(delegate(0,0,0,0)).then(drain(0))
    .then(forgetRangesOnRestart).then(delegate(0,0,0,1)).expect(not(rangeSafety) and s.accepts.get(0) == 2)
  run historyBypassCounterexampleTest = init.then(restrict(0)).then(recoverHost)
    .then(delegateIgnoringHistory(2)).expect(not(safety))
  run incompleteRecoveryCounterexampleTest = init.then(emptyRecovery).expect(not(budgetSafety))
  run newAuthorityRebindingCounterexampleTest = init.then(observe(0)).then(rebindClaim(0,100)).expect(not(identitySafety))
  run pendingSealReopenCounterexampleTest = init.then(seal(req(0,0,0))).then(restartOwner)
    .then(reopenPendingSeal).expect(not(ownerSafety))
  run duplicateAfterLostReplyCounterexampleTest = init.then(seal(req(0,0,0))).then(commit(0,req(0,0,0)))
    .then(loseReply).then(duplicateCommit(1,req(0,0,0))).expect(not(journalSafety))
  run rebuildingTransportQueueCounterexampleTest = init.then(delegate(0,0,0,0)).then(drain(0))
    .then(restartOwner).then(rebuildTransportQueue(0)).then(drain(0)).expect(not(rangeSafety) and s.exposures.get(0) == 2)
  run rawFdBypassCounterexampleTest = init.then(seal(req(0,0,0))).then(rawFdBypass(0)).expect(not(rangeSafety))

}
