// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

// The stable intent/journal and execution authority are not local snapshot caches.
module LlmRegistryPublication {
  type Blob={tenant:int,commitment:int,vector:int,document:bool,tools:Set[int]}
  type Binding={operation:int,tenant:int,root:int,claim:int,stream:int,input:int,budget:int,history:int,escrow:int,blob:Blob}
  type Image={binding:Binding,position:int,fence:int,revision:int}
  type Permit={id:int,image:Image,worker:int}
  type Use={permit:Permit,actual:Image}
  type Publication={blobs:Set[Blob],readable:Set[Blob],locked:bool,binding:Binding,first:int,journal:int,visible:int,certified:bool,ack:bool,
    fence:int,revision:int,online:bool,projection:Image,hasProjection:bool,active:bool,permits:Set[Permit],uses:Set[Use],
    recovered:bool,offered:bool,allocated:int,calls:int,usage:int,retired:bool,terminal:bool,closed:bool,charged:bool,restricted:bool}
  var s:Publication
  pure val profile={tenant:3,commitment:20,vector:30,document:true,tools:Set(7,8)}
  pure val canonical={operation:40,tenant:3,root:0,claim:11,stream:4,input:10,budget:5,history:9,escrow:20,blob:profile}
  pure val replacement=canonical.with("blob",profile.with("commitment",21).with("document",false))
  pure val emptyImage={binding:canonical,position:-1,fence:-1,revision:-1}
  pure val emptyPermit={id:-1,image:emptyImage,worker:-1}
  pure val activationImage={binding:canonical,position:1,fence:0,revision:0}
  pure val activationPermit={id:0,image:activationImage,worker:0}
  pure val beforeInvokePermit={id:2,image:activationImage.with("revision",2),worker:0}
  pure val initial={blobs:Set(),readable:Set(),locked:false,binding:canonical,first:-1,journal:0,visible:0,certified:false,ack:false,
    fence:0,revision:0,online:true,projection:emptyImage,hasProjection:false,active:false,permits:Set(),uses:Set(),
    recovered:true,offered:false,allocated:0,calls:0,usage:-1,retired:false,terminal:false,closed:false,charged:false,restricted:false}
  def image={binding:s.binding,position:s.journal,fence:s.fence,revision:s.revision}
  def ready=s.locked and s.binding==canonical and s.journal==1 and s.visible==1 and s.certified and
    s.readable.contains(s.binding.blob) and s.online and s.recovered
  def gate(p)=s.permits.contains(p) and s.active and ready and s.hasProjection and s.projection==image and p.image==image and p.worker==s.fence
  def permit=s.permits.fold(emptyPermit,(a,b)=>if(b.image==image and b.worker==s.fence)b else a)
  action init=s'=initial
  action storeBlob(b,durable)=all {durable,s.blobs.forall(old=>not(old.tenant==b.tenant and old.commitment==b.commitment) or old==b),
    s'=s.with("blobs",s.blobs.union(Set(b))).with("readable",s.readable.union(Set(b)))}
  action reserveIntent(b,worker,sourceValid,publishPolicy)=all {not(s.locked),s.blobs.contains(b.blob),b==canonical,sourceValid,publishPolicy,
    s.online,s.recovered,worker==s.fence,s'=s.with("locked",true).with("binding",b).with("first",b.blob.commitment)}
  action commitRoot(b,worker,durable)=all {s.locked,b==s.binding,s.journal==0,s.online,worker==s.fence,durable,
    s'=s.with("journal",1).with("visible",1)}
  action certify(b,worker,durable)=all {s.locked,b==s.binding,s.journal==1,s.visible==1,s.online,worker==s.fence,durable,
    s'=s.with("certified",true)}
  action queryCertified(b)=all {s.locked,b==s.binding,s.certified,s'=s.with("ack",true)}
  action loseReply=s'=s.with("ack",false)
  action restoreJournal(b,qualified)=all {s.locked,b==s.binding,s.journal==1,qualified,s'=s.with("visible",1)}
  action restoreBlob(b,qualified)=all {s.blobs.contains(b),qualified,s'=s.with("readable",s.readable.union(Set(b)))}
  action loseJournal=s'=s.with("visible",0).with("active",false)
  action loseBlob=s'=s.with("readable",Set()).with("active",false)
  action offline=s'=s.with("online",false).with("active",false)
  action reconnect=s'=s.with("online",true)
  action installSnapshot(i)=all {not(s.active),s'=s.with("projection",i).with("hasProjection",true)}
  action activate(i,worker,currentRead)=all {ready,s.hasProjection,s.projection==image,i==image,worker==s.fence,currentRead,
    s'=s.with("active",true)}
  action issuePermit(worker,session)=all {ready,s.active,s.hasProjection,s.projection==image,worker==s.fence,session,
    s'=s.with("permits",s.permits.union(Set({id:s.permits.size(),image:image,worker:worker})))}
  // Every authority mutation changes execution revision, including data-only writes.
  action offer(p)=all {gate(p),not(s.offered),s'=s.with("offered",true).with("revision",s.revision+1).with("active",false).with("hasProjection",false)}
  action allocate(p)=all {gate(p),s.offered,s.allocated==0,not(s.closed),not(s.charged),
    s'=s.with("allocated",6).with("revision",s.revision+1).with("active",false).with("hasProjection",false)}
  action invoke(p,policy)=all {gate(p),s.offered,s.allocated==6,s.calls==0,not(s.closed),not(s.restricted),policy,
    s'=s.with("calls",1).with("revision",s.revision+1).with("active",false).with("hasProjection",false)
      .with("uses",s.uses.union(Set({permit:p,actual:image})))}
  action restrictHistory=s'=s.with("restricted",true).with("revision",s.revision+1).with("active",false).with("hasProjection",false)
  action finalUsage(amount,qualified)=all {s.calls==1,s.usage == -1,amount>=0,amount<=6,qualified,
    s'=s.with("usage",amount).with("terminal",true).with("retired",true).with("revision",s.revision+1).with("active",false).with("hasProjection",false)}
  action close=all {s.retired,s.terminal,s.usage>=0,s'=s.with("closed",true).with("revision",s.revision+1).with("active",false).with("hasProjection",false)}
  action settle(p)=all {gate(p),s.closed,s.usage>=0,s'=s.with("charged",true).with("revision",s.revision+1).with("active",false).with("hasProjection",false)}
  action restart=s'=s.with("fence",s.fence+1).with("revision",s.revision+1).with("recovered",false).with("retired",true)
    .with("active",false).with("hasProjection",false).with("ack",false)
  action recoverSource(qualified)=all {qualified,s'=s.with("recovered",true).with("revision",s.revision+1).with("active",false).with("hasProjection",false)}
  def validImage(i)=i.binding==canonical and i.position==1
  val bindingBound=(s.locked implies s.binding==canonical) and (s.first>=0 implies s.locked and s.binding.blob.commitment==s.first)
  val journalBound=s.journal<=1 and (s.journal>0 implies s.locked) and (s.certified implies s.locked and s.journal==1)
  val activeBound=s.active implies ready and s.hasProjection and s.projection==image
  val usesBound=s.uses.forall(u=>u.permit.image==u.actual and u.permit.worker==u.actual.fence and validImage(u.actual))
  val ledgerBound=s.calls<=1 and s.allocated<=20 and (s.charged implies s.closed and s.usage>=0) and (s.closed implies s.retired and s.terminal and s.usage>=0)
  val safety=bindingBound and journalBound and activeBound and usesBound and ledgerBound
  action step={
    nondet amount=0.to(6).oneOf()
    any {storeBlob(profile,true),reserveIntent(canonical,s.fence,true,true),commitRoot(canonical,s.fence,true),certify(canonical,s.fence,true),
      queryCertified(canonical),loseReply,restoreJournal(canonical,true),restoreBlob(profile,true),loseJournal,loseBlob,offline,reconnect,
      installSnapshot(image),activate(image,s.fence,true),issuePermit(s.fence,true),offer(permit),allocate(permit),invoke(permit,true),
      restrictHistory,finalUsage(amount,true),close,settle(permit),restart,recoverSource(true)}
  }
  action pending=init.then(storeBlob(profile,true)).then(reserveIntent(canonical,0,true,true))
  action committed=pending.then(commitRoot(canonical,0,true))
  action certified=committed.then(certify(canonical,0,true))
  action join=installSnapshot(image).then(activate(image,s.fence,true)).then(issuePermit(s.fence,true))
  action activated=certified.then(join)
  action invoked=activated.then(offer(permit)).then(join).then(allocate(permit)).then(join).then(invoke(permit,true))
  action recovered=invoked.then(restart).then(recoverSource(true)).then(restoreJournal(canonical,true)).then(restoreBlob(profile,true)).then(join)
  run pendingIntentIsStickyTest=pending.then(loseReply).then(reserveIntent(replacement,0,true,true).fail())
  run blobMustBeDurableTest=init.then(storeBlob(profile,false).fail())
  run blobPrecedesIntentTest=init.then(reserveIntent(canonical,0,true,true).fail())
  run commitmentCannotForkTest=init.then(storeBlob(profile,true)).then(storeBlob(profile.with("document",false),true).fail())
  run sourceSubjectMustMatchTest=init.then(storeBlob(profile,true)).then(reserveIntent(canonical,0,false,true).fail())
  run publicationPolicyRequiredTest=init.then(storeBlob(profile,true)).then(reserveIntent(canonical,0,true,false).fail())
  run foreignClaimCannotPublishTest=init.then(storeBlob(profile,true)).then(reserveIntent(canonical.with("claim",12),0,true,true).fail())
  run sourceVectorMustMatchTest=init.then(storeBlob(profile.with("vector",31),true)).then(reserveIntent(canonical.with("blob",profile.with("vector",31)),0,true,true).fail())
  run journalCannotPrecedeIntentTest=init.then(commitRoot(canonical,0,true).fail())
  run lostCommitReplyQueriesSameDecisionTest=committed.then(loseReply).then(certify(canonical,0,true)).then(queryCertified(canonical)).expect(safety and s.journal==1)
  run lostCertificationReplyIsNotAbsenceTest=certified.then(loseReply).then(queryCertified(canonical)).then(commitRoot(canonical,0,true).fail())
  run emptyLocalSnapshotCannotRecommitTest=committed.then(loseJournal).then(commitRoot(canonical,0,true).fail())
  run unconfirmedJournalCannotActivateTest=committed.then(installSnapshot(image)).then(activate(image,0,true).fail())
  run anchorCannotCertifyMissingRootTest=pending.then(certify(canonical,0,true).fail())
  run exactJournalReceiptRequiredTest=committed.then(certify(canonical,0,false).fail())
  run mismatchedSnapshotCannotActivateTest=certified.then(installSnapshot(image.with("binding",replacement))).then(activate(image,0,true).fail())
  run missingBlobCannotActivateTest=certified.then(loseBlob).then(installSnapshot(image)).then(activate(image,0,true).fail())
  run wrongBlobCannotRestoreTest=certified.then(loseBlob).then(restoreBlob(profile.with("document",false),true).fail())
  run staleJournalPrefixCannotActivateTest=certified.then(loseJournal).then(installSnapshot(image)).then(activate(image,0,true).fail())
  run restoredJournalAndBlobRejoinTest=certified.then(loseJournal).then(loseBlob).then(restoreJournal(canonical,true)).then(restoreBlob(profile,true)).then(join).expect(safety)
  run callbackDoesNotActivateTest=certified.then(queryCertified(canonical)).expect(safety and not(s.active))
  run offlineAuthorityCannotIssueTest=activated.then(offline).then(issuePermit(0,true).fail())
  run currentReadRequiredTest=certified.then(installSnapshot(image)).then(activate(image,0,false).fail())
  run oldWorkerCannotCommitTest=pending.then(restart).then(commitRoot(canonical,0,true).fail())
  run oldWorkerCannotCertifyTest=committed.then(restart).then(certify(canonical,0,true).fail())
  run currentWorkerAdoptsExactLateReceiptTest=committed.then(restart).then(certify(canonical,1,true)).then(recoverSource(true)).then(join).expect(safety)
  run sourceRecoveryMustPrecedeActivationTest=certified.then(restart).then(installSnapshot(image)).then(activate(image,1,true).fail())
  run duplicatePermitCannotReplayTest=activated.then(offer(activationPermit)).then(offer(activationPermit).fail())
  run oldWorkerPermitCannotRecoverTest=activated.then(restart).then(recoverSource(true)).then(join).then(offer(activationPermit).fail())
  run oldExecutionSnapshotCannotResetSpendTest=activated.then(offer(activationPermit)).then(join).then(allocate(permit)).then(join).then(invoke(permit,true))
    .then(installSnapshot(activationImage)).expect(safety and s.calls==1 and s.usage == -1).then(activate(activationImage,0,true).fail())
  run historyUpdateInvalidatesQueuedPermitTest=activated.then(offer(permit)).then(join).then(allocate(permit)).then(join)
    .then(restrictHistory).then(invoke(beforeInvokePermit,true).fail())
  run freshImageCannotBypassOriginalHistoryTest=activated.then(offer(permit)).then(join).then(allocate(permit)).then(restrictHistory).then(join).then(invoke(permit,true).fail())
  run unknownUsageCannotSettleTest=recovered.then(settle(permit).fail())
  run registryRecoveryPreservesUnknownBudgetTest=recovered.expect(safety and s.calls==1 and s.allocated==6 and s.usage == -1)
  run lateUsageCanSettleOriginalTaskTest=recovered.then(finalUsage(4,true)).then(close).then(join).then(settle(permit)).expect(safety)
  action unsafeReplaceIntent=s'=s.with("binding",replacement)
  action unsafeDuplicateRoot=s'=s.with("journal",2)
  action unsafePrematureCertificate=s'=s.with("certified",true)
  action unsafeActivate=s'=s.with("active",true)
  action unsafeUseOldPermit(p)=s'=s.with("uses",s.uses.union(Set({permit:p,actual:image})))
  action unsafeRefund=s'=s.with("charged",true)
  run replacedIntentPublicationCounterexampleTest=pending.then(unsafeReplaceIntent).expect(not(bindingBound))
  run localAbsenceReplayPublicationCounterexampleTest=committed.then(loseJournal).then(unsafeDuplicateRoot).expect(not(journalBound))
  run prematureCertificatePublicationCounterexampleTest=pending.then(unsafePrematureCertificate).expect(not(journalBound))
  run foreignSnapshotPublicationCounterexampleTest=certified.then(installSnapshot(image.with("binding",replacement))).then(unsafeActivate).expect(not(activeBound))
  run oldWorkerPublicationCounterexampleTest=activated.then(restart).then(recoverSource(true)).then(join).then(unsafeUseOldPermit(activationPermit)).expect(not(usesBound))
  run staleExecutionPublicationCounterexampleTest=activated.then(offer(activationPermit)).then(installSnapshot(activationImage)).then(unsafeActivate).expect(not(activeBound))
  run missingBlobPublicationCounterexampleTest=certified.then(loseBlob).then(installSnapshot(image)).then(unsafeActivate).expect(not(activeBound))
  run unknownRefundPublicationCounterexampleTest=invoked.then(unsafeRefund).expect(not(ledgerBound))
}
