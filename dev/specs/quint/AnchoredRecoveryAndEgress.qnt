// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

// External journal, transport owner and receiver are distinct failure domains.
// The rollbackable host holds correlation/status and an opaque old-range handle.
module AnchoredRecoveryAndEgress {
  type Receipt = {present: bool, command: int, operation: int, expected: int,
    lineage: int, binding: int, sequence: int, committed: bool}
  type World = {
    head: int, lineage: int, epoch: int, online: bool, claims: int, held: int, history: bool,
    operations: int -> Receipt, commands: int -> Receipt, decisions: int -> int,
    localHead: int, localLineage: int, localClaims: int, localHeld: int, localHistory: bool,
    known: int, preflight: bool, handleEpoch: int,
    ownerEpoch: int, ownerOpen: bool, accepted: bool, bufferEpoch: int, originalBufferEpoch: int,
    emitted: bool, wire: int, receiverEpoch: int, applied: bool, applications: int, unsafeAdmissions: int
  }
  var s: World
  pure val ops = Set(0,1)
  pure val commands = Set(0,1,2,3)
  pure val absent = {present:false,command:0,operation:0,expected:0,lineage:0,binding:0,sequence:0,committed:false}
  pure def binding(op) = 100 + op
  action init = s' = {
    head:0,lineage:0,epoch:0,online:true,claims:1,held:1,history:false,
    operations:ops.mapBy(_ => absent),commands:commands.mapBy(_ => absent),decisions:ops.mapBy(_ => 0),
    localHead:0,localLineage:0,localClaims:1,localHeld:1,localHistory:false,
    known:0,preflight:false,handleEpoch:0,ownerEpoch:0,ownerOpen:true,accepted:false,
    bufferEpoch:0,originalBufferEpoch:0,emitted:false,wire:0,receiverEpoch:0,applied:false,applications:0,unsafeAdmissions:0
  }
  def recovered = s.online and s.localHead == s.head and s.localLineage == s.lineage and
    s.localClaims == s.claims and s.localHeld == s.held and s.localHistory == s.history
  def canCommit(cid,op,expected,b) = s.online and not(s.ownerOpen) and expected == s.head and
    b == binding(op) and not(s.operations.get(op).present) and not(s.commands.get(cid).present)
  pure def record(w,cid,op,expected,b,committed) = {
    val receipt = {present:true,command:cid,operation:op,expected:expected,lineage:w.lineage,
      binding:b,sequence:w.head+1,committed:committed}
    w.with("head",w.head+1).with("epoch",if (committed) w.epoch+1 else w.epoch)
      .with("operations",w.operations.set(op,receipt)).with("commands",w.commands.set(cid,receipt))
      .with("decisions",w.decisions.set(op,w.decisions.get(op)+1))
  }
  action seal = s' = s.with("ownerOpen",false)
  action commit(cid,op,expected,b) = all {canCommit(cid,op,expected,b),s' = record(s,cid,op,expected,b,true)}
  action abort(cid,op,expected,b) = all {canCommit(cid,op,expected,b),s' = record(s,cid,op,expected,b,false)}
  action loseReply = s' = s.with("known",0)
  action lookup(op,b) = all {s.online,s.operations.get(op).present,s.operations.get(op).binding == b,
    s' = s.with("known",if (s.operations.get(op).committed) 1 else -1)}
  action lookupMissing(op) = all {s.online,not(s.operations.get(op).present),s' = s.with("known",0)}
  action recover = all {s.online,s' = s.with("localHead",s.head).with("localLineage",s.lineage)
    .with("localClaims",s.claims).with("localHeld",s.held).with("localHistory",s.history)}
  action rollbackHost = s' = s.with("localHead",0).with("localLineage",0).with("localClaims",1)
    .with("localHeld",1).with("localHistory",false).with("known",0).with("preflight",false)
  action foreignImage = s' = s.with("localHead",s.head).with("localLineage",s.lineage+1)
  action partition = s' = s.with("online",false)
  action reconnect = s' = s.with("online",true)
  action activate = all {s.online,not(s.ownerOpen),s.ownerEpoch < s.epoch,
    s' = s.with("ownerEpoch",s.epoch).with("ownerOpen",true)}
  def canHandoff = recovered and s.ownerOpen and s.ownerEpoch == s.epoch and
    s.handleEpoch == s.ownerEpoch and not(s.accepted)
  action preflight = s' = s.with("preflight",canHandoff)
  action handoff = all {canHandoff,s' = s.with("accepted",true).with("bufferEpoch",s.handleEpoch)
    .with("originalBufferEpoch",s.handleEpoch)}
  action drain = all {s.accepted,not(s.emitted),s' = s.with("emitted",true).with("wire",s.wire+1)}
  action receiverBarrier = s' = s.with("receiverEpoch",s.epoch)
  action applyAtReceiver = all {s.emitted,s.bufferEpoch == s.receiverEpoch,not(s.applied),
    s' = s.with("applied",true).with("applications",s.applications+1)}
  action step = {
    nondet cid = commands.oneOf()
    nondet op = ops.oneOf()
    any {seal,commit(cid,op,s.head,binding(op)),abort(cid,op,s.head,binding(op)),loseReply,
      lookup(op,binding(op)),lookupMissing(op),recover,rollbackHost,foreignImage,partition,reconnect,
      activate,preflight,handoff,drain,receiverBarrier,applyAtReceiver}
  }
  val journalSafety = ops.forall(op => s.decisions.get(op) <= 1 and
    (s.operations.get(op).present iff (s.decisions.get(op) == 1)))
  val payloadSafety = s.claims == 1 and s.held == 1 and not(s.history)
  val ownerSafety = s.ownerOpen implies s.ownerEpoch == s.epoch
  val wireSafety = s.wire <= (if (s.emitted) 1 else 0) and (s.emitted implies s.accepted)
  val receiverSafety = s.applications <= (if (s.applied) 1 else 0)
  val epochSafety = s.bufferEpoch == s.originalBufferEpoch
  val mediationSafety = s.unsafeAdmissions == 0
  val safety = journalSafety and payloadSafety and ownerSafety and wireSafety and receiverSafety and epochSafety and mediationSafety

  // Invalid designs, excluded from step. Observational counters survive rollback.
  action retryWithNewCommand(cid,op) = all {not(s.commands.get(cid).present),not(s.ownerOpen),
    s' = record(s,cid,op,s.head,binding(op),true)}
  action clearLocalPayloadAtCurrentHeight = s' = s.with("localHead",s.head).with("localLineage",s.lineage)
    .with("localClaims",0).with("localHeld",0)
  action sequenceOnlyHandoff = all {s.online,s.localHead == s.head,s.ownerOpen,not(s.accepted),
    s' = s.with("accepted",true).with("unsafeAdmissions",s.unsafeAdmissions+(if (canHandoff) 0 else 1))}
  action useCachedPreflight = all {s.preflight,s' = s.with("wire",s.wire+1).with("unsafeAdmissions",s.unsafeAdmissions+1)}
  action rollbackOwnerWithHost = s' = s.with("ownerEpoch",0).with("ownerOpen",true)
    .with("accepted",false).with("emitted",false).with("localHead",0).with("localLineage",0)
    .with("localClaims",1).with("localHeld",1).with("localHistory",false)
  action rollbackAnchorWithHost = s' = s.with("head",0).with("epoch",0)
    .with("operations",ops.mapBy(_ => absent)).with("commands",commands.mapBy(_ => absent))
    .with("localHead",0).with("known",0)
  action relabelAcceptedBuffer = s' = s.with("bufferEpoch",s.receiverEpoch)

  run lostCommitReplyTest = init.then(seal).then(commit(0,0,0,100)).then(loseReply).then(rollbackHost)
    .then(lookup(0,100)).then(recover).then(activate)
    .expect(safety and s.known == 1 and s.head == 1 and s.decisions.get(0) == 1 and not(canHandoff))
  run newCommandSameOperationRejectedTest = init.then(seal).then(commit(0,0,0,100))
    .then(commit(1,0,1,100).fail())
  run bindingSubstitutionRejectedTest = init.then(seal).then(commit(0,0,0,100)).then(lookup(0,101).fail())
  run missingIsNotAbortTest = init.then(seal).then(lookupMissing(0)).then(commit(0,0,0,100))
    .then(lookup(0,100)).expect(safety and s.known == 1)
  run abortBlocksLateCommitTest = init.then(seal).then(abort(0,0,0,100)).then(loseReply)
    .then(lookup(0,100)).expect(s.known == -1 and safety).then(commit(1,0,1,100).fail())
  run anchorOutageRetainsBufferTest = init.then(handoff).then(partition).then(drain)
    .expect(safety and not(canHandoff) and s.wire == 1 and s.held == 1)
  run snapshotRollbackRejectedTest = init.then(seal).then(commit(0,0,0,100)).then(rollbackHost)
    .expect(safety and not(recovered) and s.localHead < s.head)
  run sameHeightMissingPayloadRejectedTest = init.then(clearLocalPayloadAtCurrentHeight)
    .expect(safety and s.localHead == s.head and not(recovered))
  run sameHeightForeignLineageRejectedTest = init.then(foreignImage).then(handoff.fail())
  run sealCannotReopenWithoutCommitTest = init.then(seal).then(activate.fail())
  run postCutDrainWitnessTest = init.then(handoff).then(seal).then(commit(0,0,0,100)).then(activate).then(drain)
    .expect(safety and s.wire == 1 and s.bufferEpoch < s.epoch)
  run receiverFenceDoesNotPreventWireTest = init.then(handoff).then(seal).then(commit(0,0,0,100))
    .then(receiverBarrier).then(activate).then(drain).expect(safety and s.wire == 1)
    .then(applyAtReceiver.fail())
  run receiverDedupSurvivesHostRollbackTest = init.then(handoff).then(drain).then(applyAtReceiver)
    .then(rollbackHost).expect(safety and s.applications == 1).then(applyAtReceiver.fail())
  run newCommandRetryCounterexampleTest = init.then(seal).then(commit(0,0,0,100)).then(loseReply)
    .then(retryWithNewCommand(1,0)).expect(not(journalSafety) and s.decisions.get(0) == 2)
  run sequenceOnlyRecoveryCounterexampleTest = init.then(clearLocalPayloadAtCurrentHeight)
    .then(sequenceOnlyHandoff).expect(not(mediationSafety) and s.localHead == s.head and not(recovered))
  run cachedCheckToSocketCounterexampleTest = init.then(preflight).then(seal).then(commit(0,0,0,100))
    .then(useCachedPreflight).expect(not(mediationSafety) and s.wire == 1 and not(s.accepted))
  run coRollbackTransportOwnerCounterexampleTest = init.then(handoff).then(drain).then(applyAtReceiver)
    .then(rollbackOwnerWithHost).then(handoff).then(drain)
    .expect(not(wireSafety) and s.wire == 2 and s.applications == 1)
  run coRollbackAnchorCounterexampleTest = init.then(seal).then(commit(0,0,0,100)).then(rollbackAnchorWithHost)
    .then(commit(1,0,0,100)).expect(not(journalSafety) and s.decisions.get(0) == 2)
  run unauthenticatedEpochRelabelCounterexampleTest = init.then(handoff).then(seal).then(commit(0,0,0,100))
    .then(receiverBarrier).then(drain).then(relabelAcceptedBuffer).then(applyAtReceiver)
    .expect(not(epochSafety) and s.applications == 1)
}
