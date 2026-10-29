module SourceOwner {
  import PublicationRecovery as P from "./PublicationRecovery"
  type Owner = {started:bool,live:bool,closing:bool,busy:bool,slot:bool,transaction:bool,receiver:bool,closed:bool,closeOk:bool,failed:bool,ack:bool,reads:List[{observed:int,actual:int}]}
  var owner:Owner
  val safe = P::safe and owner.busy==owner.slot and
    (owner.transaction implies owner.busy and owner.live) and
    (owner.closed implies owner.started and not(owner.live)) and
    (owner.ack implies owner.closing and owner.closed and owner.closeOk and not(owner.failed) and not(owner.busy) and not(owner.transaction)) and
    owner.reads.indices().forall(i=>owner.reads.nth(i).observed==owner.reads.nth(i).actual)
  action init = all {P::init,owner'={started:false,live:false,closing:false,busy:false,slot:false,transaction:false,receiver:true,closed:false,closeOk:false,failed:false,ack:false,reads:[]}}
  action inert = P::observe
  action start = all {not(owner.started),not(owner.closing),owner'=owner.with("started",true).with("live",true),inert}
  action admit = all {owner.live,not(owner.closing),not(owner.busy),owner'=owner.with("busy",true).with("slot",true).with("receiver",true),inert}
  action begin = all {owner.busy,owner.live,not(owner.failed),owner'=owner.with("transaction",true),inert}
  action callerLost = all {owner'=owner.with("receiver",false),inert}
  action decide(id:int,payload:int,parent:int,fence:int):bool = all {owner.busy,owner.live,owner.transaction,not(owner.failed),
    any {P::publish(id,payload,parent,fence),P::replay(id,payload,parent,fence)},
    owner'=owner.with("transaction",false).with("reads",owner.reads.append({observed:P::s.head,actual:P::s.head}))}
  action finish = all {owner.busy,not(owner.transaction),owner'=owner.with("busy",false).with("slot",false),inert}
  action close = all {owner'=owner.with("closing",true),inert}
  action storageFailure = all {owner.live,owner'=owner.with("closing",true).with("failed",true),inert}
  action failedWorkDestroyed = all {owner.failed,owner'=owner.with("transaction",false).with("busy",false).with("slot",false),inert}
  action closeDatabase = all {owner.live,owner.closing,not(owner.busy),not(owner.transaction),
    owner'=owner.with("live",false).with("closed",true).with("closeOk",true),inert}
  action closeError = all {owner.live,owner.closing,not(owner.busy),not(owner.transaction),
    owner'=owner.with("live",false).with("closed",true).with("closeOk",false).with("failed",true),inert}
  action acknowledge = all {owner.closed,owner.closeOk,not(owner.failed),not(owner.busy),not(owner.transaction),owner'=owner.with("ack",true),inert}
  action unsafeReturnOnDisconnect = all {owner.busy,owner'=owner.with("slot",false),inert}
  action unsafeReuseSnapshot = all {owner'=owner.with("reads",owner.reads.append({observed:P::s.head-1,actual:P::s.head})),inert}
  action unsafeSuccessAfterCloseError = all {owner.failed,owner'=owner.with("ack",true),inert}
  action step = {nondet id=P::ids.oneOf() nondet payload=Set(0,1).oneOf() nondet parent=Set(-1,0,1,2).oneOf() nondet fence=Set(1,2,3).oneOf()
    any {start,admit,begin,callerLost,decide(id,payload,parent,fence),finish,close,storageFailure,failedWorkDestroyed,closeDatabase,closeError,acknowledge}}
  action active = init.then(start).then(admit).then(begin)
  run disconnectDoesNotReturnCapacityTest = active.then(callerLost).then(admit.fail())
  run droppedReplyCanStillCommitOriginalTest = active.then(callerLost).then(decide(0,0,-1,1)).then(finish).expect(safe and P::s.head==0)
  run shutdownMustFinishTransactionTest = active.then(close).then(closeDatabase.fail())
  run acceptedWorkCanCommitWhileClosingTest = active.then(close).then(decide(0,0,-1,1)).then(finish).then(closeDatabase).then(acknowledge).expect(safe)
  run storageFailurePreventsReuseTest = active.then(storageFailure).then(failedWorkDestroyed).then(admit.fail())
  run closeErrorCannotAcknowledgeSuccessTest = init.then(start).then(close).then(closeError).then(acknowledge.fail())
  run closedOwnerCannotReopenTest = init.then(start).then(close).then(closeDatabase).then(acknowledge).then(start.fail())
  run earlyDisconnectReturnCounterexampleTest = active.then(unsafeReturnOnDisconnect).expect(not(safe))
  run cachedSnapshotCounterexampleTest = active.then(unsafeReuseSnapshot).expect(not(safe))
  run swallowedCloseErrorCounterexampleTest = init.then(start).then(close).then(closeError).then(unsafeSuccessAfterCloseError).expect(not(safe))
}
