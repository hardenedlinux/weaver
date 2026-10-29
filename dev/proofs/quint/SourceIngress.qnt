module SourceIngress {
  type Caller = {ingress:int,certificate:int,credential:int,method:int}
  type Ingress = {operation:Set[int],source:Set[int],closing:bool,shared:bool,publications:List[Caller],executions:List[Caller]}
  var s:Ingress
  val sockets = Set(0,1,2)
  val sourceEnabled = not(s.closing) and s.source.size()<1 and (not(s.shared) or s.operation.size()<2)
  pure def bound(c:Caller,role:int):bool = c.ingress==role and c.certificate==role and c.credential==role and c.method==role
  val safe = s.operation.size()<=2 and s.source.size()<=1 and
    ((not(s.closing) and s.source==Set()) implies sourceEnabled) and
    s.publications.indices().forall(i=>bound(s.publications.nth(i),1)) and
    s.executions.indices().forall(i=>bound(s.executions.nth(i),0))
  action init = s'={operation:Set(),source:Set(),closing:false,shared:false,publications:[],executions:[]}
  action operationConnect(w:int):bool = all {not(s.closing),s.operation.size()<2,not(s.operation.contains(w)),s'=s.with("operation",s.operation.union(Set(w)))}
  action sourceConnect(w:int):bool = all {sourceEnabled,not(s.source.contains(w)),s'=s.with("source",s.source.union(Set(w)))}
  action operationDrop(w:int):bool = s'=s.with("operation",s.operation.exclude(Set(w)))
  action sourceDrop(w:int):bool = s'=s.with("source",s.source.exclude(Set(w)))
  action publish(c:Caller):bool = all {not(s.closing),s.source!=Set(),bound(c,1),s'=s.with("publications",s.publications.append(c))}
  action execute(c:Caller):bool = all {not(s.closing),s.operation!=Set(),bound(c,0),s'=s.with("executions",s.executions.append(c))}
  action close = s'=s.with("closing",true)
  action lostReply = s'=s
  action unsafeShareBudget = s'=s.with("shared",true)
  action unsafeForwardedCredential = s'=s.with("publications",s.publications.append({ingress:1,certificate:0,credential:1,method:1}))
  action step = {nondet w=sockets.oneOf() any {operationConnect(w),sourceConnect(w),operationDrop(w),sourceDrop(w),
    publish({ingress:1,certificate:1,credential:1,method:1}),execute({ingress:0,certificate:0,credential:0,method:0}),close,lostReply}}
  action full = init.then(operationConnect(0)).then(operationConnect(1))
  action source = full.then(sourceConnect(2))
  run saturatedOperationAllowsNewSourceTest = source.then(publish({ingress:1,certificate:1,credential:1,method:1})).expect(safe)
  run forwardedCredentialCannotPublishTest = source.then(publish({ingress:1,certificate:0,credential:1,method:1}).fail())
  run wrongCredentialCannotPublishTest = source.then(publish({ingress:1,certificate:1,credential:0,method:1}).fail())
  run operatorIngressCannotPublishTest = source.then(publish({ingress:0,certificate:1,credential:1,method:1}).fail())
  run sourceIngressCannotExecuteTest = source.then(execute({ingress:1,certificate:1,credential:1,method:0}).fail())
  run sourceCapacityCannotBorrowTest = source.then(sourceConnect(0).fail())
  run lostReplyKeepsBindingTest = source.then(publish({ingress:1,certificate:1,credential:1,method:1})).then(lostReply).expect(safe)
  run shutdownRejectsSourceTest = full.then(close).then(sourceConnect(2).fail())
  run sharedBudgetCounterexampleTest = full.then(unsafeShareBudget).expect(not(safe))
  run forwardedCredentialCounterexampleTest = source.then(unsafeForwardedCredential).expect(not(safe))
}
