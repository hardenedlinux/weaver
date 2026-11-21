// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

// Two files can have the same visible getter and different surviving effects.
// A full plan is a proposed design, not an implemented Magpie capability.
// Per-file compare/replace is abstract here and still needs runtime qualification.
module ConfigRecoveryDesign {
  type Write={beforeId:int,afterId:int}
  type S={live:bool,pending:bool,plan:int,phase:int,primary:int,aux:int,
    primaryId:int,auxId:int,committed:bool,restored:bool,conflict:bool,writes:List[Write]}
  var s:S
  val ownedEffect=s.primaryId==1 or s.auxId==1
  val noOrphan=s.pending or s.committed or s.conflict or not(ownedEffect)
  val noExternalOverwrite=s.writes.indices().forall(i=>s.writes.nth(i).beforeId!=2)
  val safe=noOrphan and noExternalOverwrite
  // Independent recoverability obligation for a live interrupted operation.
  val recoverable=not(s.live and s.pending and ownedEffect) or s.plan==2
  action init=s'={live:true,pending:false,plan:0,phase:0,primary:0,aux:0,
    primaryId:0,auxId:0,committed:false,restored:false,conflict:false,writes:List()}
  action prepare(kind:int):bool=all {s.live,not(s.pending),s.phase==0,
    s'=s.with("plan",kind).with("pending",true).with("phase",1)}
  action fullPlan=prepare(2)
  action fieldOnlyPlan=prepare(1)
  action writeAux=all {s.live,s.pending,s.phase==1,s.auxId==0,
    s'=s.with("aux",1).with("auxId",1).with("phase",2)
      .with("writes",s.writes.append({beforeId:s.auxId,afterId:1}))}
  action writePrimary=all {s.live,s.pending,s.phase==2,s.primaryId==0,
    s'=s.with("primary",1).with("primaryId",1).with("phase",3)
      .with("writes",s.writes.append({beforeId:s.primaryId,afterId:1}))}
  action commit=all {s.live,s.pending,s.phase==3,s.primaryId==1,s.auxId==1,
    s'=s.with("pending",false).with("committed",true)}
  action crash=s'=s.with("live",false)
  action restart=s'=s.with("live",true)
  // Equal bytes are not equal file identity: another writer replaces our file.
  action externalEqualBytes=all {s.pending,s.auxId==1,s'=s.with("auxId",2)}
  action restoreAux=all {s.live,s.pending,s.plan==2,not(s.conflict),
    if (s.auxId==1)
      s'=s.with("aux",0).with("auxId",3).with("writes",s.writes.append({beforeId:s.auxId,afterId:3}))
    else if (s.auxId==2) s'=s.with("conflict",true)
    else s'=s}
  action restorePrimary=all {s.live,s.pending,s.plan==2,not(s.conflict),
    if (s.primaryId==1)
      s'=s.with("primary",0).with("primaryId",3).with("writes",s.writes.append({beforeId:s.primaryId,afterId:3}))
    else s'=s}
  action resolveRestored=all {s.live,s.pending,s.plan==2,not(s.conflict),
    not(ownedEffect),s.auxId!=2,s'=s.with("pending",false).with("restored",true)}
  action observe=s'=s
  action step=any {fullPlan,writeAux,writePrimary,commit,crash,restart,externalEqualBytes,
    restoreAux,restorePrimary,resolveRestored,observe}
  // Competing recovery strategies, without manually marking them unsafe.
  action clearByGetter=all {s.live,s.pending,s.primary==0,
    s'=s.with("pending",false).with("restored",true)}
  action blindRestore=all {s.live,s.pending,s.aux==1,
    s'=s.with("aux",0).with("auxId",3).with("writes",s.writes.append({beforeId:s.auxId,afterId:3}))}
  action checkpointStep=any {fieldOnlyPlan,writeAux,writePrimary,commit,crash,restart,observe}
  action fieldOnlyStep=any {fieldOnlyPlan,writeAux,writePrimary,crash,restart,clearByGetter,observe}
  action blindRestoreStep=any {fullPlan,writeAux,externalEqualBytes,blindRestore,observe}
  run unchangedGetterCanHideAuxiliaryEffectTest=init.then(fieldOnlyPlan).then(writeAux)
    .then(crash).then(restart).expect(s.primary==0 and s.aux==1 and not(recoverable))
    .then(clearByGetter).expect(not(safe))
  run fullPlanCanRestorePartialEditTest=init.then(fullPlan).then(writeAux).then(crash).then(restart)
    .then(restoreAux).then(restorePrimary).then(resolveRestored).expect(safe and s.restored)
  run sameBytesExternalIdentityRefusesRestoreTest=init.then(fullPlan).then(writeAux)
    .then(externalEqualBytes).then(restoreAux).expect(safe and s.conflict and s.auxId==2)
  run blindByteRestoreOverwritesForeignIdentityTest=init.then(fullPlan).then(writeAux)
    .then(externalEqualBytes).then(blindRestore).expect(not(safe))
  run restartDuringRestoreIsIdempotentTest=init.then(fullPlan).then(writeAux).then(writePrimary)
    .then(crash).then(restart).then(restoreAux).then(crash).then(restart)
    .then(restoreAux).then(restorePrimary).then(resolveRestored).expect(safe and s.restored)
}
