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
