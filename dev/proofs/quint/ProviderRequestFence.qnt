// Native WriteSeal refinement: accepted plaintext + TLS flush, no detached driver.
// Local drain is not provider receipt, settlement, or permission to replay.
module ProviderRequestFence {
 type S={eof:bool,head:bool,tail:bool,sealed:bool,released:bool,cut:int,original:int,held:int,burned:bool,calls:int,committed:bool,ack:bool,failed:bool,alive:bool,poisoned:bool,owner:int,worker:int,rows:List[{admitted:int,current:int}]}
 var s:S
 action init=s'={eof:false,head:false,tail:true,sealed:false,released:false,cut:0,original:0,held:4,burned:true,calls:1,committed:false,ack:false,failed:false,alive:true,poisoned:false,owner:0,worker:0,rows:List()}
 action bodyEOF=s'=s.with("eof",true)
 action responseHead=s'=s.with("head",true)
 action localDrain=s'=s.with("tail",false)
 // Requires a native unforgeable receipt plus no remaining application writer.
 action seal=all {not(s.failed),not(s.tail),s'=s.with("sealed",true)}
 action commit=all {s.alive,not(s.failed),not(s.poisoned),s.worker==s.owner,s.sealed,not(s.released),s'=s.with("committed",true).with("ack",true)}
 action loseCommitAck=all {s.alive,not(s.failed),not(s.poisoned),s.sealed,not(s.released),s'=s.with("committed",true).with("ack",false).with("poisoned",true)}
 action unlock=all {s.alive,not(s.failed),not(s.poisoned),s.worker==s.owner,s.sealed,s.committed,s.ack,s'=s.with("released",true)}
 action authorityChange=all {s.committed,s'=s.with("cut",s.cut+1)}
 action releaseRow=all {s.alive,not(s.failed),not(s.poisoned),s.worker==s.owner,s.released,s.head,s.cut==s.original,s'=s.with("rows",s.rows.append({admitted:s.original,current:s.cut}))}
 action recoverOrLoseReply=s'=s
 action failedCallback=all {not(s.committed),not(s.released),s'=s.with("failed",true).with("sealed",false)}
 action unsafeErrorCommit=s'=s.with("committed",true)
 action nativeCommitBeforeAck=all {s.alive,not(s.failed),not(s.poisoned),s.sealed,not(s.committed),s'=s.with("committed",true)}
 action delayedAck=all {s.alive,not(s.failed),not(s.poisoned),s.worker==s.owner,s.committed,s'=s.with("ack",true)}
 action rollbackAfterSeal=all {s.alive,s.sealed,not(s.committed),s'=s.with("poisoned",true)}
 action crash=all {s.alive,s'=s.with("alive",false).with("ack",false).with("released",false).with("sealed",false).with("owner",s.owner+1)}
 action recover=all {not(s.alive),s'=s.with("alive",true)}
 // Restored records cannot recreate a socket or rebind the original worker.
 action unsafeRestoreAck=s'=s.with("ack",true).with("released",true)
 action unsafeEOFUnlock=all {s.eof,s'=s.with("released",true)}
 action unsafeHeadUnlock=all {s.head,s'=s.with("released",true)}
 action unsafeDrainUnlock=all {not(s.tail),s'=s.with("released",true)}
 action unsafeStaleRow=s'=s.with("rows",s.rows.append({admitted:s.original,current:s.cut}))
 action unsafeRefund=s'=s.with("held",0)
 action unsafeRetry=s'=s.with("calls",s.calls+1)
 val safe=(s.released implies s.sealed and s.committed and s.ack) and (s.sealed implies not(s.tail)) and (s.poisoned implies not(s.ack)) and (s.released implies s.alive and s.worker==s.owner) and (s.failed implies not(s.committed) and not(s.released)) and s.held==4 and s.burned and s.calls==1 and
   s.rows.indices().forall(i=>s.rows.nth(i).admitted==s.rows.nth(i).current)
 action step=any {bodyEOF,responseHead,localDrain,seal,commit,loseCommitAck,unlock,authorityChange,releaseRow,recoverOrLoseReply,nativeCommitBeforeAck,delayedAck,rollbackAfterSeal,crash,recover,failedCallback}
 run eofIsNotDrainCounterexampleTest=init.then(bodyEOF).then(unsafeEOFUnlock).expect(not(safe) and s.tail)
 run earlyHeadIsNotDrainCounterexampleTest=init.then(responseHead).then(unsafeHeadUnlock).expect(not(safe) and s.tail)
 run drainWithoutSealingIsNotFenceCounterexampleTest=init.then(localDrain).then(unsafeDrainUnlock).expect(not(safe))
 run sealedWriterCanUnlockBeforeHeadersTest=init.then(bodyEOF).then(localDrain).then(seal).then(commit).then(unlock).expect(safe and not(s.head))
 run currentRowsAfterSealTest=init.then(localDrain).then(seal).then(commit).then(unlock).then(responseHead).then(releaseRow).expect(safe)
 run revokedRowsCannotReleaseTest=init.then(localDrain).then(seal).then(commit).then(unlock).then(authorityChange).then(responseHead).expect(safe).then(releaseRow.fail())
 run staleRowCounterexampleTest=init.then(localDrain).then(seal).then(commit).then(unlock).then(authorityChange).then(unsafeStaleRow).expect(not(safe))
 run sealLostReplyRetainsUnknownTest=init.then(localDrain).then(seal).then(recoverOrLoseReply).expect(safe and s.held==4 and not(s.released))
 run recoveryDoesNotCertifyDrainTest=init.then(bodyEOF).then(recoverOrLoseReply).expect(safe and s.tail).then(unlock.fail())
 run localDrainCannotRefundCounterexampleTest=init.then(localDrain).then(seal).then(unsafeRefund).expect(not(safe))
 run lateHeaderCannotReplayCounterexampleTest=init.then(responseHead).then(recoverOrLoseReply).then(unsafeRetry).expect(not(safe))
 run unacknowledgedCommitCannotStartHeaderReadTest=init.then(localDrain).then(seal).then(loseCommitAck).then(recoverOrLoseReply).expect(safe and s.held==4).then(unlock.fail())
 run sealWithoutCommitCannotStartHeaderReadTest=init.then(localDrain).then(seal).expect(safe).then(unlock.fail())
 run publicationBeforeHeadersCannotReleaseOldResponseTest=init.then(localDrain).then(seal).then(commit).then(unlock).then(authorityChange).then(responseHead).expect(safe and s.held==4).then(releaseRow.fail()) run nativeCommitThenFenceThenLateAckTest=init.then(localDrain).then(seal).then(nativeCommitBeforeAck).then(authorityChange).then(delayedAck).then(unlock).then(responseHead).expect(safe and s.held==4).then(releaseRow.fail())
 run appliedLostAckPoisonsOldWorkerTest=init.then(localDrain).then(seal).then(loseCommitAck).expect(safe and s.committed).then(delayedAck.fail())
 run precommitRollbackRetainsBurnTest=init.then(localDrain).then(seal).then(rollbackAfterSeal).expect(safe and not(s.committed)).then(unlock.fail())
 run crashBeforeCommitRecoveryTest=init.then(localDrain).then(seal).then(crash).then(recover).expect(safe and not(s.committed)).then(unlock.fail())
 run crashAfterCommitRecoveryTest=init.then(localDrain).then(seal).then(nativeCommitBeforeAck).then(crash).then(recover).expect(safe and s.committed).then(unlock.fail())
 run restoredMarkerIsNotPermissionCounterexampleTest=init.then(localDrain).then(seal).then(nativeCommitBeforeAck).then(crash).then(recover).then(unsafeRestoreAck).expect(not(safe))
 run failedCallbackCannotReachCommitTest=init.then(failedCallback).expect(safe and s.held==4).then(nativeCommitBeforeAck.fail())
 run committingFailedCallbackCounterexampleTest=init.then(failedCallback).then(unsafeErrorCommit).expect(not(safe))
}
