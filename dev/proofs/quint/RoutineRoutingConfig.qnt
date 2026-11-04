// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

module RoutineRoutingConfig {
  import LlmRouting as R from "./LlmRouting"
  type Normal={root:int,payload:int,profile:int,node:int,response:int,requirements:Set[int],targets:Set[int],allowance:int,contextNeeded:int,region:int}
  type Selection={wire:R::Plan,normal:Normal}
  type Configuration={installed:Normal,source:int,generation:int,hasInstalled:bool,pinned:Normal,pinGeneration:int,hasPin:bool,plans:Set[Selection]}
  var cfg:Configuration
  pure val normal:Normal={root:0,payload:10,profile:11,node:7,response:1,requirements:Set(1),targets:Set(0,6),allowance:10,contextNeeded:8,region:0}
  pure val alternate:Normal=normal.with("targets",Set(6)).with("allowance",8)
  pure def valid(n:Normal):bool=n.root==0 and n.payload==10 and n.profile==11 and n.node==7 and n.response==1 and n.requirements.contains(1) and n.allowance>=0 and n.allowance<=10 and n.contextNeeded>=8 and n.region==0
  pure val initial:Configuration={installed:normal,source:0,generation:0,hasInstalled:false,pinned:normal,pinGeneration:-1,hasPin:false,plans:Set()}
  val joined:bool=(not(cfg.hasInstalled) or valid(cfg.installed)) and (not(cfg.hasPin) or valid(cfg.pinned)) and cfg.plans.forall(p=>cfg.hasPin and p.normal==cfg.pinned and R::r.plans.contains(p.wire))
  val invariant:bool=R::safety and joined
  action idle:bool=R::r'=R::r
  action boot:bool=all {R::init,cfg'=initial}
  // Decoder/closure evidence is authenticated compiler input, never caller flags.
  action configure(surface:int,n:Normal,typed:bool,closure:bool,admitted:bool):bool=all {Set(0,1,2).contains(surface),typed,closure,admitted,valid(n),idle,cfg'=cfg.with("installed",n).with("source",surface).with("generation",cfg.generation+1).with("hasInstalled",true)}
  action pin:bool=all {cfg.hasInstalled,not(cfg.hasPin),invariant,idle,cfg'=cfg.with("hasPin",true).with("pinned",cfg.installed).with("pinGeneration",cfg.generation)}
  pure def supports(m:int,capability:int):bool=if(capability==1) R::supportsTools(m) else if(capability==2) m==6 else false
  def eligible(m:int):bool=cfg.hasPin and cfg.pinned.targets.contains(m) and cfg.pinned.requirements.forall(capability=>supports(m,capability)) and R::eligible(m) and R::cost(m)<=cfg.pinned.allowance and cfg.pinned.contextNeeded<=R::contextLimit(m)
  def best(m:int):bool=eligible(m) and R::candidates.forall(n=>eligible(n) implies R::score(m)<=R::score(n))
  action planRoute(m:int,manifest:int):bool={val p:R::Plan={root:R::root,payload:R::payload,target:m,view:R::currentView,ranking:R::r.metrics,manifest:manifest,advised:true}
    all {invariant,best(m),R::proposeAdvised(m,manifest),cfg'=cfg.with("plans",cfg.plans.union(Set({wire:p,normal:cfg.pinned})))}}
  action advice(m:int,manifest:int):bool={val p:R::Plan={root:R::root,payload:R::payload,target:m,view:R::currentView,ranking:R::r.metrics,manifest:manifest,advised:true}
    all {invariant,eligible(m),R::proposeAdvised(m,manifest),cfg'=cfg.with("plans",cfg.plans.union(Set({wire:p,normal:cfg.pinned})))}}
  action dispatch(m:int,compilerCurrent:bool,policyCurrent:bool):bool=all {invariant,compilerCurrent,eligible(m),cfg.plans.contains({wire:R::planAt(m),normal:cfg.pinned}),R::dispatch(R::planAt(m),policyCurrent),cfg'=cfg}
  action metrics:bool=all {R::updateMetrics,cfg'=cfg}
  action restrict:bool=all {R::publishPolicy,cfg'=cfg}
  action history:bool=all {R::restrictHistory,cfg'=cfg}
  action timeout:bool=all {R::timeoutOrLostReply,cfg'=cfg}
  action response(m:int):bool=all {R::commitResponse(R::planAt(m),true),cfg'=cfg}
  action ready:bool=boot.then(configure(0,normal,true,true,true)).then(pin)
  action planned:bool=ready.then(planRoute(0,100))
  action sent:bool=planned.then(dispatch(0,true,true))
  action step:bool=any {configure(0,normal,true,true,true),configure(1,alternate,true,true,true),pin,planRoute(0,100),planRoute(6,106),advice(6,106),dispatch(0,true,true),dispatch(6,true,true),metrics,restrict,history,timeout,response(0),response(6)}
  run schemeSurfaceUsesSameNormalTest=ready.expect(invariant and cfg.pinned==normal and cfg.source==0)
  run jsonSurfaceUsesSameNormalTest=boot.then(configure(1,normal,true,true,true)).then(pin).then(planRoute(0,100)).then(dispatch(0,true,true)).expect(invariant and cfg.pinned==normal)
  run yamlSurfaceUsesSameNormalTest=boot.then(configure(2,normal,true,true,true)).then(pin).then(planRoute(0,100)).then(dispatch(0,true,true)).expect(invariant and cfg.pinned==normal)
  run typedConfigRequiredTest=boot.then(configure(1,normal,false,true,true).fail())
  run fullSourceClosureRequiredTest=boot.then(configure(0,normal,true,false,true).fail())
  run publisherAdmissionRequiredTest=boot.then(configure(2,normal,true,true,false).fail())
  run droppedCapabilityRejectedTest=boot.then(configure(2,normal.with("requirements",Set()),true,true,true).fail())
  run largerBudgetRejectedTest=boot.then(configure(1,normal.with("allowance",11),true,true,true).fail())
  run forgedProfileRejectedTest=boot.then(configure(2,normal.with("profile",12),true,true,true).fail())
  run changedResponseModeRejectedTest=boot.then(configure(2,normal.with("response",2),true,true,true).fail())
  run forgedRootRejectedTest=boot.then(configure(2,normal.with("root",1),true,true,true).fail())
  run unsupportedCheapRouteRejectedTest=ready.then(advice(1,101).fail())
  run configuredTargetIsNotPermissionTest=boot.then(configure(2,normal.with("targets",Set(2)),true,true,true)).then(pin).then(advice(2,102).fail())
  run emptyCandidateSetFailsClosedTest=boot.then(configure(2,normal.with("targets",Set()),true,true,true)).then(pin).then(planRoute(0,100).fail())
  run narrowedAllowanceConstrainsRouteTest=boot.then(configure(2,normal.with("allowance",5),true,true,true)).then(pin).then(planRoute(0,100).fail())
  run allowedAlternativeKeepsOriginalRootTest=ready.then(advice(6,106)).then(dispatch(6,true,true)).expect(invariant and R::r.dispatches.forall(d=>d.plan.root==0 and R::cost(d.plan.target)<=10))
  run newDefaultDoesNotRewritePinnedRoutineTest=planned.then(configure(2,alternate,true,true,true)).then(dispatch(0,true,true)).expect(invariant and cfg.pinned==normal and cfg.installed==alternate)
  run hardWithdrawalInvalidatesOldSelectionTest=planned.then(configure(2,alternate,true,true,true)).then(restrict).then(dispatch(0,true,true).fail())
  run softTelemetryPreservesHardAuthorityTest=planned.then(metrics).then(dispatch(0,true,true)).expect(invariant)
  run newSelectionUsesCurrentRankingTest=ready.then(metrics).then(planRoute(6,106)).then(dispatch(6,true,true)).expect(invariant and R::r.dispatches.exists(d=>d.plan.target==6))
  run historyRestrictionRecheckedTest=planned.then(history).then(dispatch(0,true,true).fail())
  run currentCompilerArtifactRequiredTest=planned.then(dispatch(0,false,true).fail())
  run finalPolicyRequiredTest=planned.then(dispatch(0,true,false).fail())
  run configCannotRewriteWireTest=ready.then(planRoute(0,999)).then(dispatch(0,true,true).fail())
  run unknownOutcomeKeepsOriginalAdmissionTest=sent.then(timeout).then(advice(6,106)).then(dispatch(6,true,true).fail())
  run routineCannotSpliceResponseSourcesTest=sent.then(response(0)).then(response(0).fail())
  run strengthenedContractFiltersPrimaryTest=boot.then(configure(2,normal.with("requirements",Set(1,2)),true,true,true)).then(pin).then(advice(0,100).fail())
  run strengthenedContractChoosesCapableBackupTest=boot.then(configure(2,normal.with("requirements",Set(1,2)),true,true,true)).then(pin).then(planRoute(6,106)).then(dispatch(6,true,true)).expect(invariant and R::r.dispatches.exists(d=>d.plan.target==6))
  // Faults are excluded from step and expose omitted native contracts.
  action unsafeConfig:bool=all {idle,cfg'=cfg.with("pinned",normal.with("allowance",20))}
  action unsafePinReplacement:bool=all {idle,cfg'=cfg.with("pinned",alternate)}
  action unsafeWireRoot:bool=all {R::unsafeRootRewrite,cfg'=cfg}
  action unsafeRetry:bool=all {R::unsafeSecondDispatch,cfg'=cfg}
  run weakenedConfigCounterexampleTest=planned.then(unsafeConfig).expect(not(invariant) and cfg.pinned.allowance==20)
  run replacedRoutineCounterexampleTest=planned.then(unsafePinReplacement).expect(not(invariant) and cfg.pinned==alternate)
  run rewrittenRootCounterexampleTest=planned.then(unsafeWireRoot).expect(not(invariant) and R::r.dispatches.exists(d=>d.plan.root==1))
  run hiddenRetryCounterexampleTest=sent.then(unsafeRetry).expect(not(invariant) and R::r.dispatches.size()==2 and R::r.unknown)
}
