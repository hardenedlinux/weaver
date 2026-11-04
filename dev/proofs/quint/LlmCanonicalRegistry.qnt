// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

module LlmCanonicalRegistry {
  type Origin={tenant:int,principal:int,issuer:int,operation:int}
  type Registration={origin:Origin,root:int,claim:int,profile:int,input:int,budget:int,history:int}
  type Key={tenant:int,principal:int,issuer:int,peer:int,protocol:int,profile:int,incarnation:int,session:int,task:int,request:int}
  type Alias={key:Key,target:Registration}
  type Image={alias:Alias,revision:int,fence:int,sourceRevision:int,policyGeneration:int,sourceFence:int}
  type Resolution={id:int,image:Image}
  type Use={resolution:Resolution,actual:Image}
  type State={registered:bool,registration:Registration,registrationCount:int,families:Set[int],registryVisible:bool,
    aliases:Set[Alias],aliasVisible:Set[Alias],revision:int,fence:int,online:bool,resolutions:Set[Resolution],uses:List[Use],
    sourceRevision:int,policyGeneration:int,sourceFence:int,pending:bool,spent:bool,everSpent:bool,calls:int,hold:int,usage:int,historyDenied:bool}
  var s:State
  pure val origin={tenant:3,principal:7,issuer:8,operation:10}
  pure val canonical={origin:origin,root:10,claim:11,profile:20,input:30,budget:5,history:9}
  pure val key0={tenant:3,principal:7,issuer:8,peer:40,protocol:1,profile:1,incarnation:0,session:50,task:60,request:70}
  pure val mcp0={key:key0,target:canonical}
  pure val mcp1={key:key0.with("incarnation",1).with("session",51).with("request",71),target:canonical}
  pure val a2a0={key:key0.with("protocol",2).with("peer",41).with("task",61),target:canonical}
  pure val acp0={key:key0.with("protocol",3).with("peer",42).with("session",52),target:canonical}
  pure val image0={alias:mcp0,revision:2,fence:0,sourceRevision:0,policyGeneration:0,sourceFence:0}
  pure val resolution0={id:0,image:image0}
  pure val spentResolution={id:1,image:image0.with("revision",3).with("sourceRevision",1)}
  pure val deniedResolution={id:1,image:image0.with("policyGeneration",1)}
  pure val newTaskResolution={id:1,image:image0.with("alias",a2a0).with("revision",4).with("sourceRevision",1)}
  pure val initial={registered:false,registration:canonical,registrationCount:0,families:Set(10),registryVisible:false,aliases:Set(),aliasVisible:Set(),
    revision:0,fence:0,online:true,resolutions:Set(),uses:List(),sourceRevision:0,policyGeneration:0,sourceFence:0,pending:true,
    spent:false,everSpent:false,calls:0,hold:6,usage:-1,historyDenied:false}
  def image(a)={alias:a,revision:s.revision,fence:s.fence,sourceRevision:s.sourceRevision,policyGeneration:s.policyGeneration,sourceFence:s.sourceFence}
  def visible(a)=s.registered and s.registration==a.target and s.aliases.contains(a) and s.registryVisible and s.aliasVisible.contains(a) and s.online
  def gate(r)=s.resolutions.contains(r) and visible(r.image.alias) and r.image==image(r.image.alias)
  action init=s'=initial
  action register(b,worker,source,durable,policy)=all {not(s.registered),b==canonical,s.pending,source,durable,policy,s.online,worker==s.fence,
    s'=s.with("registered",true).with("registration",b).with("registrationCount",1).with("registryVisible",true).with("revision",s.revision+1)}
  action bind(a,worker,continuity,durable,policy)=all {s.registered,s.registryVisible,a.target==s.registration,
    a.key.tenant==a.target.origin.tenant,a.key.principal==a.target.origin.principal,a.key.issuer==a.target.origin.issuer,
    s.aliases.forall(old=>old.key!=a.key),worker==s.fence,s.online,continuity,durable,policy,
    s'=s.with("aliases",s.aliases.union(Set(a))).with("aliasVisible",s.aliasVisible.union(Set(a))).with("revision",s.revision+1)}
  action resolve(a,qualified)=all {visible(a),qualified,s'=s.with("resolutions",s.resolutions.union(Set({id:s.resolutions.size(),image:image(a)})))}
  action loseProjection=s'=s.with("registryVisible",false).with("aliasVisible",Set())
  action restoreRegistration(b,qualified)=all {s.registered,b==s.registration,qualified,s'=s.with("registryVisible",true)}
  action restoreAlias(a,qualified)=all {s.aliases.contains(a),qualified,s'=s.with("aliasVisible",s.aliasVisible.union(Set(a)))}
  action restart=s'=s.with("fence",s.fence+1).with("revision",s.revision+1).with("online",false).with("registryVisible",false).with("aliasVisible",Set())
  action recover(qualified)=all {qualified,s'=s.with("online",true)}
  action sourceWrite=s'=s.with("sourceRevision",s.sourceRevision+1)
  action sourceRestart=s'=s.with("sourceFence",s.sourceFence+1).with("sourceRevision",s.sourceRevision+1)
  action denyHistory=s'=s.with("historyDenied",true).with("policyGeneration",s.policyGeneration+1)
  action consume(r,policy)=all {gate(r),policy,not(s.historyDenied),not(s.spent),s.pending,
    s'=s.with("spent",true).with("everSpent",true).with("calls",s.calls+1).with("sourceRevision",s.sourceRevision+1).with("revision",s.revision+1)
      .with("uses",s.uses.append({resolution:r,actual:image(r.image.alias)}))}
  val rootBound=(s.registered implies s.registration==canonical and s.registrationCount==1) and s.families==Set(10)
  val aliasesBound=s.aliases.forall(a=>a.target==canonical and a.key.tenant==3 and a.key.principal==7 and a.key.issuer==8) and
    s.aliases.forall(a=>s.aliases.forall(b=>a.key!=b.key or a==b))
  val accounting=s.calls<=1 and (s.everSpent implies s.spent) and s.hold==6 and s.pending
  val usesBound=s.uses.indices().forall(i=>{val u=s.uses.nth(i) u.resolution.image==u.actual and u.actual.alias.target==canonical})
  val safety=rootBound and aliasesBound and accounting and usesBound
  action step={nondet a=Set(mcp0,mcp1,a2a0,acp0).oneOf()
    nondet r=s.resolutions.union(Set(resolution0)).oneOf()
    any {register(canonical,s.fence,true,true,true),bind(a,s.fence,true,true,true),resolve(a,true),loseProjection,
      restoreRegistration(canonical,true),restoreAlias(a,true),restart,recover(true),sourceWrite,sourceRestart,denyHistory,consume(r,true)}}
  action registered=init.then(register(canonical,0,true,true,true))
  action mcp=registered.then(bind(mcp0,0,true,true,true))
  action a2a=mcp.then(bind(a2a0,0,true,true,true))
  action resolved=mcp.then(resolve(mcp0,true))
  action restarted=resolved.then(restart)
  action unknown=resolved.then(consume(resolution0,true))
  run registrationRequiresSourceSubjectTest=init.then(register(canonical,0,false,true,true).fail())
  run registrationRequiresDurabilityTest=init.then(register(canonical,0,true,false,true).fail())
  run registrationRequiresCurrentPolicyTest=init.then(register(canonical,0,true,true,false).fail())
  run rawWireIDCannotRegisterRootTest=init.then(register(canonical.with("root",61),0,true,true,true).fail())
  run changedOriginCannotRegisterTest=init.then(register(canonical.with("origin",origin.with("operation",61)),0,true,true,true).fail())
  run lostRegistrationReplyCannotCreateAgainTest=registered.then(loseProjection).then(register(canonical,0,true,true,true).fail())
  run exactRegistrationQueryRestoresProjectionTest=registered.then(loseProjection).then(restoreRegistration(canonical,true)).expect(safety and s.registrationCount==1)
  run wrongRegistrationCannotRestoreTest=registered.then(loseProjection).then(restoreRegistration(canonical.with("root",99),true).fail())
  run aliasRequiresRegisteredRootTest=init.then(bind(mcp0,0,true,true,true).fail())
  run aliasRequiresContinuityEvidenceTest=registered.then(bind(a2a0,0,false,true,true).fail())
  run aliasRequiresDurabilityTest=registered.then(bind(mcp0,0,true,false,true).fail())
  run aliasRequiresCurrentPolicyTest=registered.then(bind(mcp0,0,true,true,false).fail())
  run aliasCannotReplaceCanonicalTargetTest=mcp.then(bind(mcp0.with("target",canonical.with("root",99)),0,true,true,true).fail())
  run tenantCollisionCannotBindTest=registered.then(bind(mcp0.with("key",key0.with("tenant",4)),0,true,true,true).fail())
  run principalCollisionCannotBindTest=registered.then(bind(mcp0.with("key",key0.with("principal",9)),0,true,true,true).fail())
  run issuerCollisionCannotBindTest=registered.then(bind(mcp0.with("key",key0.with("issuer",9)),0,true,true,true).fail())
  run duplicateAliasUsesLookupTest=mcp.then(bind(mcp0,0,true,true,true).fail())
  run mcpReconnectKeepsOriginalFamilyTest=mcp.then(bind(mcp1,0,true,true,true)).expect(safety and s.registrationCount==1 and s.pending)
  run a2aNewTaskNeedsOriginalContinuityTest=mcp.then(bind(a2a0,0,false,true,true).fail())
  run a2aNewTaskKeepsOriginalFamilyTest=a2a.expect(safety and s.families==Set(10) and s.pending)
  run acpSessionResumeKeepsOriginalFamilyTest=mcp.then(bind(acp0,0,true,true,true)).then(resolve(acp0,true)).expect(safety and s.registrationCount==1)
  run sameTaskDifferentPeerIsSeparateAliasTest=mcp.then(bind(mcp0.with("key",key0.with("peer",41)),0,true,true,true)).expect(safety and s.aliases.size()==2)
  run changedProfileRequiresNewAliasAdmissionTest=mcp.then(bind(mcp0.with("key",key0.with("profile",2)),0,false,true,true).fail())
  run missingProjectionCannotResolveTest=mcp.then(loseProjection).then(resolve(mcp0,true).fail())
  run restoreAliasRequiresExactCommittedRowTest=mcp.then(loseProjection).then(restoreAlias(mcp1,true).fail())
  run ownerRestartRequiresRecoveryTest=restarted.then(resolve(mcp0,true).fail())
  run ownerRecoveryNeedsEvidenceTest=restarted.then(recover(false).fail())
  run recoveredOwnerStillNeedsExactProjectionsTest=restarted.then(recover(true)).then(resolve(mcp0,true).fail())
  run exactJoinCanResolveAfterRecoveryTest=restarted.then(recover(true)).then(restoreRegistration(canonical,true)).then(restoreAlias(mcp0,true))
    .then(resolve(mcp0,true)).expect(safety)
  run oldOwnerCannotBindNewTaskTest=restarted.then(recover(true)).then(restoreRegistration(canonical,true)).then(bind(a2a0,0,true,true,true).fail())
  run oldResolutionCannotConsumeAfterOwnerRestartTest=restarted.then(recover(true)).then(restoreRegistration(canonical,true)).then(restoreAlias(mcp0,true))
    .then(consume(resolution0,true).fail())
  run newAliasInvalidatesOldResolutionTest=resolved.then(bind(a2a0,0,true,true,true)).then(consume(resolution0,true).fail())
  run sourceWriteInvalidatesOldResolutionTest=resolved.then(sourceWrite).then(consume(resolution0,true).fail())
  run sourceRestartInvalidatesOldResolutionTest=resolved.then(sourceRestart).then(consume(resolution0,true).fail())
  run originalHistoryDenialStillAppliesTest=resolved.then(denyHistory).then(resolve(mcp0,true)).expect(gate(deniedResolution) and s.historyDenied).then(consume(deniedResolution,true).fail())
  run resolutionIsNotConsumptionTest=resolved.expect(safety and s.calls==0 and s.hold==6)
  run actualUseRequiresCurrentPolicyTest=resolved.then(consume(resolution0,false).fail())
  run originalClaimCannotBeConsumedTwiceTest=unknown.then(resolve(mcp0,true)).expect(gate(spentResolution) and s.spent).then(consume(spentResolution,true).fail())
  run freshNewTaskResolutionCannotResetClaimTest=unknown.then(bind(a2a0,0,true,true,true)).then(resolve(a2a0,true)).expect(gate(newTaskResolution) and s.spent).then(consume(newTaskResolution,true).fail())
  run unknownUsageSurvivesNewA2ATaskTest=unknown.then(bind(a2a0,0,true,true,true)).expect(safety and s.spent and s.usage == -1 and s.hold==6)
  run oldSnapshotProjectionCannotResetLedgerTest=unknown.then(loseProjection).then(restoreRegistration(canonical,true)).then(restoreAlias(mcp0,true))
    .expect(safety and s.calls==1 and s.pending)
  action unsafeNewRegistration=s'=s.with("registration",canonical.with("root",99)).with("registrationCount",2).with("families",Set(10,99))
  action unsafeBind(a)=s'=s.with("aliases",s.aliases.union(Set(a))).with("families",s.families.union(Set(a.target.root)))
  action unsafeSnapshot=s'=s.with("spent",false).with("calls",0).with("hold",0).with("sourceRevision",0)
  action unsafeConsume(r)=s'=s.with("uses",s.uses.append({resolution:r,actual:image(r.image.alias)}))
  action unsafeResetClaim=s'=s.with("spent",false).with("hold",0)
  action unsafeDropPending=s'=s.with("pending",false)
  run lostRegistrationRegistryCounterexampleTest=registered.then(loseProjection).then(unsafeNewRegistration).expect(not(rootBound))
  run aliasRebindRegistryCounterexampleTest=mcp.then(unsafeBind(mcp0.with("target",canonical.with("root",99)))).expect(not(aliasesBound))
  run newTaskFamilyRegistryCounterexampleTest=unknown.then(unsafeBind(a2a0.with("target",canonical.with("root",61)))).expect(not(rootBound))
  run snapshotRollbackRegistryCounterexampleTest=unknown.then(loseProjection).then(unsafeSnapshot).expect(not(accounting))
  run oldOwnerRegistryCounterexampleTest=restarted.then(recover(true)).then(restoreRegistration(canonical,true)).then(restoreAlias(mcp0,true))
    .then(unsafeConsume(resolution0)).expect(not(usesBound))
  run staleResolutionRegistryCounterexampleTest=resolved.then(bind(a2a0,0,true,true,true)).then(unsafeConsume(resolution0)).expect(not(usesBound))
  run claimResetRegistryCounterexampleTest=unknown.then(bind(a2a0,0,true,true,true)).then(unsafeResetClaim).expect(not(accounting))
  run droppedPendingRegistryCounterexampleTest=a2a.then(loseProjection).then(restoreRegistration(canonical,true)).then(unsafeDropPending).expect(not(accounting))
}
