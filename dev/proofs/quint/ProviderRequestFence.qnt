// Prospective byte-fence contract, NOT a capability supplied by reqwest.
// Local drain is not provider receipt, settlement, or permission to replay.
module ProviderRequestFence {
 type S={eof:bool,head:bool,tail:bool,sealed:bool,released:bool,cut:int,original:int,held:int,burned:bool,calls:int,rows:List[{admitted:int,current:int}]}
 var s:S
 action init=s'={eof:false,head:false,tail:true,sealed:false,released:false,cut:0,original:0,held:4,burned:true,calls:1,rows:List()}
 action bodyEOF=s'=s.with("eof",true)
 action responseHead=s'=s.with("head",true)
 action localDrain=s'=s.with("tail",false)
 // Requires a native unforgeable receipt plus no remaining application writer.
 action seal=all {not(s.tail),s'=s.with("sealed",true)}
 action unlock=all {s.sealed,s'=s.with("released",true)}
 action authorityChange=all {s.released,s'=s.with("cut",s.cut+1)}
 action releaseRow=all {s.released,s.head,s.cut==s.original,s'=s.with("rows",s.rows.append({admitted:s.original,current:s.cut}))}
 action recoverOrLoseReply=s'=s
 action unsafeEOFUnlock=all {s.eof,s'=s.with("released",true)}
 action unsafeHeadUnlock=all {s.head,s'=s.with("released",true)}
 action unsafeDrainUnlock=all {not(s.tail),s'=s.with("released",true)}
 action unsafeStaleRow=s'=s.with("rows",s.rows.append({admitted:s.original,current:s.cut}))
 action unsafeRefund=s'=s.with("held",0)
 action unsafeRetry=s'=s.with("calls",s.calls+1)
 val safe=(s.released implies s.sealed) and (s.sealed implies not(s.tail)) and s.held==4 and s.burned and s.calls==1 and
   s.rows.indices().forall(i=>s.rows.nth(i).admitted==s.rows.nth(i).current)
 action step=any {bodyEOF,responseHead,localDrain,seal,unlock,authorityChange,releaseRow,recoverOrLoseReply}
 run eofIsNotDrainCounterexampleTest=init.then(bodyEOF).then(unsafeEOFUnlock).expect(not(safe) and s.tail)
 run earlyHeadIsNotDrainCounterexampleTest=init.then(responseHead).then(unsafeHeadUnlock).expect(not(safe) and s.tail)
 run drainWithoutSealingIsNotFenceCounterexampleTest=init.then(localDrain).then(unsafeDrainUnlock).expect(not(safe))
 run sealedWriterCanUnlockBeforeHeadersTest=init.then(bodyEOF).then(localDrain).then(seal).then(unlock).expect(safe and not(s.head))
 run currentRowsAfterSealTest=init.then(localDrain).then(seal).then(unlock).then(responseHead).then(releaseRow).expect(safe)
 run revokedRowsCannotReleaseTest=init.then(localDrain).then(seal).then(unlock).then(authorityChange).then(responseHead).expect(safe).then(releaseRow.fail())
 run staleRowCounterexampleTest=init.then(localDrain).then(seal).then(unlock).then(authorityChange).then(unsafeStaleRow).expect(not(safe))
 run sealLostReplyRetainsUnknownTest=init.then(localDrain).then(seal).then(recoverOrLoseReply).expect(safe and s.held==4 and not(s.released))
 run recoveryDoesNotCertifyDrainTest=init.then(bodyEOF).then(recoverOrLoseReply).expect(safe and s.tail).then(unlock.fail())
 run localDrainCannotRefundCounterexampleTest=init.then(localDrain).then(seal).then(unsafeRefund).expect(not(safe))
 run lateHeaderCannotReplayCounterexampleTest=init.then(responseHead).then(recoverOrLoseReply).then(unsafeRetry).expect(not(safe))
}
