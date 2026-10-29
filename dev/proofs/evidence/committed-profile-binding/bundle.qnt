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




























  // Faults are excluded from step and expose omitted native contracts.
  action unsafeConfig:bool=all {idle,cfg'=cfg.with("pinned",normal.with("allowance",20))}
  action unsafePinReplacement:bool=all {idle,cfg'=cfg.with("pinned",alternate)}
  action unsafeWireRoot:bool=all {R::unsafeRootRewrite,cfg'=cfg}
  action unsafeRetry:bool=all {R::unsafeSecondDispatch,cfg'=cfg}




}

module SemanticGatewaySlice {
  import LlmRouting as R
  import RoutineRoutingConfig as C
  type Ticket={origin:int,profile:int,response:int,generation:int,epoch:int}
  type Execution={generation:int,epoch:int,recovered:bool,queued:bool,ticket:Ticket,consumed:bool,calls:int,bytes:int,terminal:bool,noExecution:bool,usageKnown:bool,usage:int,held:bool,settled:bool}
  var e:Execution
  pure val original={origin:0,payload:10,profile:11,response:1,allowance:10,history:3,budget:4}
  pure val emptyTicket:Ticket={origin:-1,profile:-1,response:-1,generation:-1,epoch:-1}
  pure val initial:Execution={generation:0,epoch:0,recovered:true,queued:false,ticket:emptyTicket,consumed:false,calls:0,bytes:0,terminal:false,noExecution:false,usageKnown:false,usage:0,held:true,settled:false}
  pure def sameOrigin(t:Ticket):bool=t.origin==original.origin and t.profile==original.profile and t.response==original.response
  def currentTicket:Ticket={origin:original.origin,profile:original.profile,response:original.response,generation:e.generation,epoch:e.epoch}
  val safety:bool=C::invariant and e.calls==R::r.dispatches.size() and e.calls<=1 and e.bytes>=0 and e.bytes<=3 and
    (e.consumed==(e.calls==1)) and (e.bytes>0 implies e.consumed) and
    (e.queued implies sameOrigin(e.ticket)) and
    (not(e.held) implies e.terminal and e.usageKnown and e.settled) and
    (e.noExecution implies e.terminal and e.calls==0 and not(e.queued) and e.usage==0) and
    (e.settled implies e.usageKnown and e.terminal and e.usage>=0 and e.usage<=original.allowance)
  action idle:bool=all {R::r'=R::r,C::cfg'=C::cfg}
  action boot:bool=all {C::boot,e'=initial}
  action configure:bool=all {C::configure(0,C::normal,true,true,true),e'=e}
  action pin:bool=all {C::pin,e'=e}
  action plan:bool=all {C::planRoute(0,100),e'=e}
  action enqueue(t:Ticket):bool=all {e.recovered,not(e.terminal),not(e.consumed),not(e.queued),sameOrigin(t),t==currentTicket,C::cfg.hasPin,C::cfg.plans.size()>0,idle,e'=e.with("queued",true).with("ticket",t)}
  // The same deciding event consumes durable execution identity and calls the prior router.
  // Native atomicity, authenticated current facts and actual transport ownership remain premises.
  action execute(t:Ticket,compilerCurrent:bool,policyCurrent:bool):bool=all {e.recovered,e.queued,not(e.terminal),not(e.consumed),t==e.ticket,t==currentTicket,sameOrigin(t),C::dispatch(0,compilerCurrent,policyCurrent),e'=e.with("queued",false).with("consumed",true).with("calls",e.calls+1)}
  action publishHardChange:bool=all {idle,e'=e.with("generation",e.generation+1)}
  action policyChange:bool=all {C::restrict,e'=e}
  action historyChange:bool=all {C::history,e'=e}
  action restart:bool=all {idle,e'=e.with("epoch",e.epoch+1).with("recovered",false)}
  action recover:bool=all {not(e.recovered),idle,e'=e.with("recovered",true)}
  action rejoin:bool=all {e.recovered,e.queued,not(e.consumed),not(e.terminal),idle,e'=e.with("ticket",currentTicket)}
  action write(worker:int):bool=all {worker==e.epoch,e.recovered,e.ticket==currentTicket,C::eligible(0),R::r.dispatches.forall(d=>d.snapshot==R::currentView),e.consumed,not(e.terminal),e.bytes<3,idle,e'=e.with("bytes",e.bytes+1)}
  action finish(worker:int):bool=all {worker==e.epoch,e.recovered,e.consumed,not(e.terminal),idle,e'=e.with("terminal",true)}
  // This is a deciding no-execution seal, not a source-side zero-call observation.
  action noExecutionSeal:bool=all {e.recovered,not(e.consumed),not(e.terminal),R::r.dispatches.size()==0,idle,e'=e.with("queued",false).with("generation",e.generation+1).with("terminal",true).with("noExecution",true).with("usageKnown",true).with("usage",0)}
  action usageReceipt(origin:int,profile:int,amount:int,authentic:bool):bool=all {authentic,origin==original.origin,profile==original.profile,e.consumed,e.terminal,not(e.usageKnown),amount>=0,amount<=original.allowance,idle,e'=e.with("usageKnown",true).with("usage",amount)}
  action settle:bool=all {e.recovered,e.terminal,e.usageKnown,not(e.settled),idle,e'=e.with("settled",true).with("held",false)}
  action timeout:bool=all {idle,e'=e}
  action ready:bool=boot.then(configure).then(pin).then(plan)
  action queued:bool=ready.then(enqueue(currentTicket))
  action sent:bool=queued.then(execute(e.ticket,true,true))
  action step:bool=any {configure,pin,plan,enqueue(currentTicket),execute(e.ticket,true,true),publishHardChange,policyChange,historyChange,restart,recover,rejoin,write(e.epoch),finish(e.epoch),noExecutionSeal,usageReceipt(0,11,6,true),settle,timeout}





























  // Deliberate faults are excluded from step.
  action unsafeQueueSend:bool=all {idle,e'=e.with("calls",1)}
  action unsafeBudgetRelease:bool=all {idle,e'=e.with("held",false)}
  action unsafeForgetExecution:bool=all {idle,e'=e.with("consumed",false).with("calls",0)}
  action unsafeNoExecution:bool=all {idle,e'=e.with("terminal",true).with("noExecution",true).with("usageKnown",true).with("usage",0)}
  action unsafeForeignTicket:bool=all {idle,e'=e.with("ticket",e.ticket.with("origin",1))}
  action unsafeSecondDispatch:bool=all {C::unsafeRetry,e'=e.with("calls",e.calls+1)}






}

module CommittedSemanticProfile {
  import LlmRouting as R
  import RoutineRoutingConfig as C
  import SemanticGatewaySlice as S
  type Node={id:int,required:Set[int],context:int,region:int}
  type Profile={id:int,response:int,nodes:Set[Node]}
  type Binding={profile:int,node:int,payload:int,history:int,budget:int}
  type Registry={profiles:Set[Profile],bound:bool,binding:Binding,epoch:int,recovered:bool,observed:bool,readEpoch:int}
  var p:Registry
  pure val node:Node={id:7,required:Set(1),context:8,region:0}
  pure val profile:Profile={id:11,response:1,nodes:Set(node)}
  pure val other:Profile=profile.with("id",12)
  pure val binding:Binding={profile:11,node:7,payload:10,history:3,budget:4}
  pure val initial:Registry={profiles:Set(),bound:false,binding:binding,epoch:0,recovered:true,observed:false,readEpoch:-1}
  // The finite commitment oracle stands for authenticated content/identity admission.
  pure def admitted(x:Profile):bool=x==profile or x==other
  pure def uniqueNodes(x:Profile):bool=x.nodes.forall(n=>x.nodes.filter(m=>m.id==n.id).size()==1)
  def known(x:Profile):bool=p.profiles.contains(x)
  val safety:bool=S::safety and p.profiles.forall(admitted) and
    p.profiles.forall(x=>p.profiles.filter(y=>y.id==x.id).size()==1 and uniqueNodes(x)) and
    (p.bound implies p.binding==binding and known(profile))
  action idle:bool=all {R::r'=R::r,C::cfg'=C::cfg,S::e'=S::e}
  action boot:bool=all {S::boot,p'=initial}
  action publish(x:Profile):bool=all {p.recovered,admitted(x),uniqueNodes(x),p.profiles.forall(y=>y.id!=x.id),idle,p'=p.with("profiles",p.profiles.union(Set(x)))}
  // No caller-supplied binding: construct from original admission assignment.
  action bindOriginal:bool=all {p.recovered,not(p.bound),known(profile),profile.nodes.exists(n=>n.id==binding.node),idle,p'=p.with("bound",true).with("binding",binding)}
  action configure:bool=all {p.bound,known(profile),C::configure(0,C::normal,true,true,true),S::e'=S::e,p'=p}
  action pin:bool=all {C::pin,S::e'=S::e,p'=p}
  action plan:bool=all {C::planRoute(0,100),S::e'=S::e,p'=p}
  action observe:bool=all {p.recovered,p.bound,known(profile),idle,p'=p.with("observed",true).with("readEpoch",p.epoch)}
  action enqueue:bool=all {p.recovered,p.bound,p.observed,p.readEpoch==p.epoch,p.binding==binding,known(profile),S::enqueue(S::currentTicket),p'=p}
  action execute:bool=all {p.recovered,p.bound,p.observed,p.readEpoch==p.epoch,p.binding==binding,known(profile),S::execute(S::e.ticket,true,true),p'=p}
  action restart:bool=all {S::restart,p'=p.with("epoch",p.epoch+1).with("recovered",false)}
  action recover:bool=all {not(p.recovered),S::recover,p'=p.with("recovered",true)}
  action rejoin:bool=all {p.recovered,p.observed,p.readEpoch==p.epoch,p.binding==binding,known(profile),S::rejoin,p'=p}
  action timeout:bool=all {S::timeout,p'=p}
  action ready:bool=boot.then(publish(profile)).then(bindOriginal).then(configure).then(pin).then(plan).then(observe)
  action queued:bool=ready.then(enqueue)
  action sent:bool=queued.then(execute)
  action step:bool=any {publish(profile),publish(other),bindOriginal,configure,pin,plan,observe,enqueue,execute,restart,recover,rejoin,timeout}
  run completeProfileReachesActualDispatchTest=sent.expect(safety and S::e.calls==1 and R::r.dispatches.size()==1)
  run missingPublicationCannotBindTest=boot.then(bindOriginal.fail())
  run forgedCommitmentContentRejectedTest=boot.then(publish(profile.with("response",2)).fail())
  run droppedCapabilityRejectedTest=boot.then(publish(profile.with("nodes",Set(node.with("required",Set())))).fail())
  run changedContextRejectedTest=boot.then(publish(profile.with("nodes",Set(node.with("context",1)))).fail())
  run changedRegionRejectedTest=boot.then(publish(profile.with("nodes",Set(node.with("region",1)))).fail())
  run changedNodeRejectedTest=boot.then(publish(profile.with("nodes",Set(node.with("id",8)))).fail())
  run duplicateNodeIdentityRejectedTest=boot.then(publish(profile.with("nodes",Set(node,node.with("context",16)))).fail())
  run otherPublishedProfileDoesNotAuthorizeOriginalTest=boot.then(publish(other)).then(bindOriginal.fail())
  run duplicatePublicationDoesNotOverwriteTest=ready.then(publish(profile).fail())
  run duplicateBindingDoesNotRecreateClaimTest=ready.then(bindOriginal.fail())
  run lostPublicationReplyRecoversSameRecordTest=boot.then(publish(profile)).then(timeout).then(bindOriginal).expect(safety and p.binding==binding)
  run lostBindingReplyRetainsOriginalTest=ready.then(timeout).expect(safety and p.bound and S::e.held and S::e.calls==0)
  run unrelatedPublicationDoesNotRepinOriginalTest=queued.then(publish(other)).then(execute).expect(safety and p.binding.profile==11 and S::e.calls==1)
  run restartPreservesProfileAndBindingTest=queued.then(restart).expect(safety and known(profile) and p.bound)
  run oldReadCannotEnqueueAfterRestartTest=ready.then(restart).then(recover).then(enqueue.fail())
  run oldReadCannotConsumeAfterRestartTest=queued.then(restart).then(recover).then(execute.fail())
  run recoveredReadAndRejoinProgressTest=queued.then(restart).then(recover).then(observe).then(rejoin).then(execute).expect(safety and S::e.calls==1)
  run postConsumptionRestartCannotRetryTest=sent.then(restart).then(recover).then(observe).then(execute.fail())
  run unknownSendRetainsBudgetTest=sent.then(timeout).expect(safety and S::e.held and not(S::e.usageKnown))
  action unsafeReplaceProfile:bool=all {idle,p'=p.with("profiles",Set(profile.with("response",2)))}
  action unsafeReplaceBinding:bool=all {idle,p'=p.with("binding",binding.with("node",8))}
  action unsafeDropProfile:bool=all {idle,p'=p.with("profiles",Set())}
  action unsafeForgetConsumption:bool=all {R::r'=R::r,C::cfg'=C::cfg,S::e'=S::e.with("consumed",false).with("calls",0),p'=p}
  run replacementProfileCounterexampleTest=queued.then(unsafeReplaceProfile).expect(not(safety))
  run replacementBindingCounterexampleTest=queued.then(unsafeReplaceBinding).expect(not(safety))
  run rollbackPublicationCounterexampleTest=queued.then(unsafeDropProfile).expect(not(safety))
  run forgottenConsumptionCounterexampleTest=sent.then(restart).then(unsafeForgetConsumption).expect(not(safety))
}
