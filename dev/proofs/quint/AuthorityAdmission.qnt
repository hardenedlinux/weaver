module AuthorityAdmission {
  // Finite lane abstraction: native completion returns capacity; caller loss does not.
  type Lanes = {execution:Set[int], publication:Set[int], observation:Set[int], closing:bool, shared:bool}
  var lanes:Lanes
  val workers = Set(0,1,2)
  val canPublish = not(lanes.closing) and lanes.publication.size()<1 and
    (not(lanes.shared) or lanes.execution.size()<2)
  val bounded = lanes.execution.size()<=2 and lanes.publication.size()<=1 and lanes.observation.size()<=2
  val reserved = (not(lanes.closing) and lanes.publication==Set()) implies canPublish
  val safe = bounded and reserved
  action init = lanes'={execution:Set(),publication:Set(),observation:Set(),closing:false,shared:false}
  action execute(w:int):bool = all {not(lanes.closing), lanes.execution.size()<2, not(lanes.execution.contains(w)),
    lanes'=lanes.with("execution",lanes.execution.union(Set(w)))}
  action publish(w:int,source:bool):bool = all {source,canPublish,not(lanes.publication.contains(w)),
    lanes'=lanes.with("publication",lanes.publication.union(Set(w)))}
  action observe(w:int):bool = all {not(lanes.closing),lanes.observation.size()<2,not(lanes.observation.contains(w)),
    lanes'=lanes.with("observation",lanes.observation.union(Set(w)))}
  action finishExecute(w:int):bool = lanes'=lanes.with("execution",lanes.execution.exclude(Set(w)))
  action finishPublish(w:int):bool = lanes'=lanes.with("publication",lanes.publication.exclude(Set(w)))
  action finishObserve(w:int):bool = lanes'=lanes.with("observation",lanes.observation.exclude(Set(w)))
  action disconnect = lanes'=lanes
  action close = lanes'=lanes.with("closing",true)
  action unsafeShared = lanes'=lanes.with("shared",true)
  action step = {nondet w=workers.oneOf() any {execute(w),publish(w,true),observe(w),
    finishExecute(w),finishPublish(w),finishObserve(w),disconnect,close}}
  action full = init.then(execute(0)).then(execute(1))
  run saturatedExecutionStillPublishesTest = full.then(publish(2,true)).expect(safe)
  run saturatedExecutionStillObservesTest = full.then(observe(2)).expect(safe)
  run disconnectKeepsExecutionCapacityTest = full.then(disconnect).then(execute(2).fail())
  run agentCannotUsePublicationLaneTest = full.then(publish(2,false).fail())
  run publicationCapacityIsBoundedTest = full.then(publish(0,true)).then(publish(1,true).fail())
  run shutdownClosesPublicationTest = full.then(close).then(publish(2,true).fail())
  run shutdownClosesObservationTest = full.then(close).then(observe(2).fail())
  run completedWorkerReturnsCapacityTest = full.then(finishExecute(0)).then(execute(2)).expect(safe)
  run sharedLaneStarvationCounterexampleTest = full.then(unsafeShared).expect(not(safe))
}
