module SourceOwner {
  import PublicationRecovery as P from "./PublicationRecovery"
  type Owner = {started:bool,live:bool,closing:bool,busy:bool,slot:bool,transaction:bool,receiver:bool,closed:bool,closeOk:bool,failed:bool,ack:bool,command:int,returned:Set[int],decided:Set[int],replies:Set[int],reads:List[{observed:int,actual:int}]}
  var owner:Owner
  val safe = P::safe and owner.busy==owner.slot and
    (owner.transaction implies owner.busy and owner.live) and
    (owner.closed implies owner.started and not(owner.live)) and
    (owner.ack implies owner.closing and owner.closed and owner.closeOk and not(owner.failed) and not(owner.busy) and not(owner.transaction)) and
    owner.replies.forall(id=>owner.returned.contains(id) and owner.decided.contains(id)) and
    owner.reads.indices().forall(i=>owner.reads.nth(i).observed==owner.reads.nth(i).actual)
  action init = all {P::init,owner'={started:false,live:false,closing:false,busy:false,slot:false,transaction:false,receiver:true,closed:false,closeOk:false,failed:false,ack:false,command:0,returned:Set(),decided:Set(),replies:Set(),reads:[]}}
  action inert = P::observe
  action start = all {not(owner.started),not(owner.closing),owner'=owner.with("started",true).with("live",true),inert}
  action admit = all {owner.live,not(owner.closing),not(owner.busy),owner'=owner.with("busy",true).with("slot",true).with("receiver",true).with("command",owner.command+1),inert}
  action begin = all {owner.busy,owner.live,not(owner.failed),owner'=owner.with("transaction",true),inert}
  action callerLost = all {owner'=owner.with("receiver",false),inert}
  action decide(id:int,payload:int,parent:int,fence:int):bool = all {owner.busy,owner.live,owner.transaction,not(owner.failed),
    any {P::publish(id,payload,parent,fence),P::replay(id,payload,parent,fence)},
    owner'=owner.with("transaction",false).with("decided",owner.decided.union(Set(owner.command))).with("reads",owner.reads.append({observed:P::s.head,actual:P::s.head}))}
  action finish = all {owner.busy,not(owner.transaction),owner'=owner.with("busy",false).with("slot",false).with("returned",owner.returned.union(Set(owner.command))),inert}
  action commandReply(id:int):bool = all {owner.decided.contains(id),owner.returned.contains(id),owner'=owner.with("replies",owner.replies.union(Set(id))),inert}
  action close = all {owner'=owner.with("closing",true),inert}
  action storageFailure = all {owner.live,owner'=owner.with("closing",true).with("failed",true),inert}
  action failedWorkDestroyed = all {owner.failed,owner'=owner.with("transaction",false).with("busy",false).with("slot",false).with("returned",owner.returned.union(Set(owner.command))),inert}
  action closeDatabase = all {owner.live,owner.closing,not(owner.busy),not(owner.transaction),
    owner'=owner.with("live",false).with("closed",true).with("closeOk",true),inert}
  action closeError = all {owner.live,owner.closing,not(owner.busy),not(owner.transaction),
    owner'=owner.with("live",false).with("closed",true).with("closeOk",false).with("failed",true),inert}
  action acknowledge = all {owner.closed,owner.closeOk,not(owner.failed),not(owner.busy),not(owner.transaction),owner'=owner.with("ack",true),inert}
  action unsafeReturnOnDisconnect = all {owner.busy,owner'=owner.with("slot",false),inert}
  action unsafeReuseSnapshot = all {owner'=owner.with("reads",owner.reads.append({observed:P::s.head-1,actual:P::s.head})),inert}
  action unsafeSuccessAfterCloseError = all {owner.failed,owner'=owner.with("ack",true),inert}
  action unsafeReplyBeforeCapacity = all {owner.decided.contains(owner.command),owner.busy,owner'=owner.with("replies",owner.replies.union(Set(owner.command))),inert}
  action step = {nondet id=P::ids.oneOf() nondet payload=Set(0,1).oneOf() nondet parent=Set(-1,0,1,2).oneOf() nondet fence=Set(1,2,3).oneOf()
    nondet replyId=owner.returned.union(Set(owner.command)).oneOf()
    any {start,admit,begin,callerLost,decide(id,payload,parent,fence),finish,commandReply(replyId),close,storageFailure,failedWorkDestroyed,closeDatabase,closeError,acknowledge}}
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
  run commandReplyPermitsImmediateReuseTest = active.then(decide(0,0,-1,1)).then(finish).then(commandReply(1)).expect(safe and owner.replies.contains(1)).then(admit).expect(safe)
  run newCommandCanPrecedeOldReplyTest = active.then(decide(0,0,-1,1)).then(finish).then(admit).then(commandReply(1)).expect(safe and owner.busy and owner.replies.contains(1))
  run replyBeforeCapacityCounterexampleTest = active.then(decide(0,0,-1,1)).then(unsafeReplyBeforeCapacity).expect(not(safe))
}
