// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

// Four bounded frames, not a second ledger. The oracle observes preparation
// times and actual handoff receipts. Cedar/SQL/delivery custody remain native.
module PreparedSnapshot {
  type Receipt={frame:int,preparedAt:int,guardAt:int,snapshotPrepared:int,cancelled:bool,version:int,guardVersion:int}
  type S={clock:int,prepared:List[int],guard:int,guardPrepared:int,version:int,guardVersion:int,cancelled:bool,failed:bool,out:List[Receipt]}
  var s:S
  // The weaker per-frame oracle can miss a published prefix followed by a
  // preparation failure. Preserve it as a falsifiable verification alternative.
  val frameOnlySafe=s.out.indices().forall(i=>{
    val r=s.out.nth(i)
    r.frame==i and r.preparedAt<r.guardAt and not(r.cancelled) and r.version==r.guardVersion
  })
  val safe=frameOnlySafe and s.out.indices().forall(i=>s.out.nth(i).snapshotPrepared==4)
  action init=s'={clock:0,prepared:List(),guard: -1,guardPrepared:0,version:0,guardVersion: -1,cancelled:false,failed:false,out:List()}
  action prepare=all {not(s.failed),not(s.cancelled),s.prepared.length()<4,
    s'=s.with("clock",s.clock+1).with("prepared",s.prepared.append(s.clock+1))}
  action guard=all {not(s.failed),not(s.cancelled),s.guard== -1,s.prepared.length()==4,
    s'=s.with("clock",s.clock+1).with("guard",s.clock+1).with("guardPrepared",s.prepared.length()).with("guardVersion",s.version)}
  action emit=all {not(s.failed),not(s.cancelled),s.guard>=0,s.version==s.guardVersion,s.out.length()<s.prepared.length(),
    s'=s.with("out",s.out.append({frame:s.out.length(),preparedAt:s.prepared.nth(s.out.length()),guardAt:s.guard,snapshotPrepared:s.guardPrepared,cancelled:s.cancelled,version:s.version,guardVersion:s.guardVersion}))}
  action failPreparation=s'=s.with("failed",true)
  action cancel=s'=s.with("cancelled",true)
  action withdraw=s'=s.with("version",s.version+1)
  action observe=s'=s
  action step=any {prepare,guard,emit,failPreparation,cancel,withdraw,observe}
  action firstOnlyGuard=all {not(s.failed),not(s.cancelled),s.guard== -1,s.prepared.length()==1,
    s'=s.with("clock",s.clock+1).with("guard",s.clock+1).with("guardPrepared",s.prepared.length()).with("guardVersion",s.version)}
  // Isolate the preparation hypothesis under stable authority. Mixed faults
  // remain a separate campaign, rather than silently dropping their failures.
  action latePreparationStep=any {prepare,firstOnlyGuard,emit,observe}
  action lateMixedFailuresStep=any {prepare,firstOnlyGuard,emit,failPreparation,cancel,withdraw,observe}
  action ready=init.then(prepare).then(prepare).then(prepare).then(prepare)
  run allEncodingPrecedesGuardTest=ready.then(guard).then(emit).then(emit).then(emit).then(emit).expect(safe and s.out.length()==4)
  run failureBeforeWholePreparationCannotPublishTest=init.then(prepare).then(failPreparation).then(guard.fail())
  run cancelAfterPreparationCannotPublishTest=ready.then(cancel).then(guard.fail())
  run withdrawalAfterGuardCannotHandoffTest=ready.then(guard).then(withdraw).then(emit.fail())
  run priorReceiptRemainsHistoricalTest=ready.then(guard).then(emit).then(withdraw).expect(safe)
  run frameOnlyOracleMissesFailedSnapshotPrefixTest=init.then(prepare).then(firstOnlyGuard).then(emit).then(failPreparation).expect(frameOnlySafe and not(safe))
  run firstOnlyGuardAllowsLateEncodingCounterexampleTest=init.then(prepare).then(firstOnlyGuard).then(emit).then(prepare).then(emit).expect(not(safe))
}
