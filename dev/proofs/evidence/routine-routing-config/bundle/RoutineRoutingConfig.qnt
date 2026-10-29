// Product-core baseline: filter hard constraints, rank eligible LLM bindings,
// recheck at final admission. Extra post-dispatch attempts are not enabled.
module LlmRouting {
  type View = {catalog:int,policy:int,history:int,endpoint:int}
  type Plan = {root:int,payload:int,target:int,view:View,ranking:int,manifest:int,advised:bool}
  type Dispatch = {plan:Plan,snapshot:View}
  type Router = {catalog:int,policy:int,history:int,endpoint:int,metrics:int,unavailable:Set[int],
    plans:Set[Plan],dispatches:Set[Dispatch],responses:Set[Plan],unknown:bool}
  var r:Router
  pure val root = 0
  pure val payload = 10
  pure val escrow = 10
  pure val candidates = 0.to(6)
  pure val emptyPlan = {root:-1,payload:-1,target:-1,view:{catalog:-1,policy:-1,history:-1,endpoint:-1},ranking:-1,manifest:-1,advised:false}
  pure val initial = {catalog:0,policy:0,history:0,endpoint:0,metrics:0,unavailable:Set(),plans:Set(),dispatches:Set(),responses:Set(),unknown:false}
  action init = r' = initial
  def currentView = {catalog:r.catalog,policy:r.policy,history:r.history,endpoint:r.endpoint}
  pure def cost(m) = if (m==5) 12 else if (m==6) 8 else if (m==0) 6 else 1
  pure def region(m) = if (m==3) 1 else 0
  pure def supportsTools(m) = m!=1
  pure def contextLimit(m) = if (m==4) 4 else 32
  def permitted(m) = m!=2 and not(r.policy>0 and m==0)
  def historyAllows(m) = not(r.history>0 and m==0)
  def eligible(m) = candidates.contains(m) and supportsTools(m) and contextLimit(m)>=8 and region(m)==0 and
    permitted(m) and historyAllows(m) and cost(m)<=escrow and not(r.unavailable.contains(m))
  def score(m) = if (m==2) 0 else if (r.metrics>0 and m==6) 1 else if (m==0) 10 else 20
  def best(m) = eligible(m) and candidates.forall(n => eligible(n) implies score(m)<=score(n))
  pure def validWire(p) = p.manifest == 100+p.target and p.payload == payload
  action propose(m,manifest) = {
    val p = {root:root,payload:payload,target:m,view:currentView,ranking:r.metrics,manifest:manifest,advised:false}
    all {best(m),r' = r.with("plans",r.plans.union(Set(p)))}
  }
  action proposeAdvised(m,manifest) = {
    val p = {root:root,payload:payload,target:m,view:currentView,ranking:r.metrics,manifest:manifest,advised:true}
    all {eligible(m),r' = r.with("plans",r.plans.union(Set(p)))}
  }
  action dispatch(p,policyValid) = all {policyValid,r.plans.contains(p),p.root==root,p.payload==payload,p.view==currentView,
    eligible(p.target),validWire(p),r.dispatches.size()==0,
    r' = r.with("dispatches",Set({plan:p,snapshot:currentView})).with("unknown",true)}
  action commitResponse(p,releaseValid) = all {releaseValid,r.dispatches.exists(d => d.plan==p),r.responses.size()==0,
    r' = r.with("responses",Set(p))}
  action publishCatalog = r' = r.with("catalog",r.catalog+1)
  action publishPolicy = r' = r.with("policy",r.policy+1)
  action restrictHistory = r' = r.with("history",r.history+1)
  action replaceEndpoint = r' = r.with("endpoint",r.endpoint+1)
  action updateMetrics = r' = r.with("metrics",r.metrics+1)
  action markUnavailable(m) = r' = r.with("unavailable",r.unavailable.union(Set(m)))
  action timeoutOrLostReply = r' = r
  def planAt(m) = r.plans.fold(emptyPlan,(found,p) => if (p.target==m) p else found)
  val dispatchBound = r.dispatches.forall(d => d.plan.root==root and d.plan.payload==payload and d.plan.view==d.snapshot and validWire(d.plan))
  val originalRootOnce = r.dispatches.size()<=1
  val responseBound = r.responses.size()<=1 and r.responses.forall(p => r.dispatches.exists(d => d.plan==p))
  val costBound = r.dispatches.forall(d => cost(d.plan.target)<=escrow)
  val safety = dispatchBound and originalRootOnce and responseBound and costBound
  action step = {
    nondet m = candidates.oneOf()
    nondet p = r.plans.union(Set(emptyPlan)).oneOf()
    any {propose(m,100+m),proposeAdvised(m,100+m),dispatch(p,true),commitResponse(p,true),publishCatalog,publishPolicy,
      restrictHistory,replaceEndpoint,updateMetrics,markUnavailable(m),timeoutOrLostReply}
  }
  action planned = init.then(propose(0,100))
  action dispatched = planned.then(dispatch(planAt(0),true))
  action responded = dispatched.then(commitResponse(planAt(0),true))


























  // Counterexamples deliberately remove one contract; never included in step.
  action unsafeStaleDispatch = r' = r.with("dispatches",Set({plan:planAt(0),snapshot:currentView}))
  action unsafeDeniedDispatch = r' = r.with("dispatches",Set({plan:{root:root,payload:payload,target:5,view:currentView,ranking:r.metrics,manifest:105,advised:false},snapshot:currentView}))
  action unsafeWrongWire = r' = r.with("dispatches",Set({plan:planAt(0).with("manifest",999),snapshot:currentView}))
  action unsafeSecondDispatch = r' = r.with("dispatches",r.dispatches.union(Set({plan:{root:root,payload:payload,target:6,view:currentView,ranking:r.metrics,manifest:106,advised:false},snapshot:currentView})))
  action unsafeForeignResponse = r' = r.with("responses",Set(planAt(0).with("root",1)))
  action unsafeRootRewrite = r' = r.with("dispatches",Set({plan:planAt(0).with("root",1),snapshot:currentView}))






}

module RoutineRoutingConfig {
  import LlmRouting as R
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
