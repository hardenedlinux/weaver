// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

module ProviderAdmissionTurn {
  type State={queued:Set[int],used:Set[int],active:Set[int],closed:bool,hard:bool,reader:bool,
    image:int,qualified:int,owner:int,issuedOwner:int,known:bool,failed:bool,
    held:int,claims:int,history:int,consumed:bool,bad:bool,sourceOpen:bool,runtimeSource:bool,sourceKnown:bool,serving:bool}
  var s:State
  action init=s'={queued:Set(),used:Set(),active:Set(),closed:false,hard:false,reader:true,
    image:0,qualified:0,owner:1,issuedOwner:1,known:true,failed:false,
    held:4,claims:1,history:1,consumed:false,bad:false,sourceOpen:true,runtimeSource:false,sourceKnown:true,serving:true}
  action enqueue(id:int):bool=all{not(s.failed),not(s.used.contains(id)),
    s'={...s,queued:s.queued.union(Set(id)),used:s.used.union(Set(id))}}
  action grant(id:int):bool=all{s.queued.contains(id),s.active==Set(),not(s.reader),not(s.failed),
    s'={...s,queued:s.queued.exclude(Set(id)),active:Set(id)}}
  action close=all{not(s.active==Set()),not(s.failed),s'={...s,closed:true}}
  action commit=all{not(s.active==Set()),s.closed,not(s.failed),s.held+4<=12,
    s'={...s,image:s.image+1,held:s.held+4,claims:s.claims+1,history:s.history+1,active:Set(),closed:false}}
  action reject=all{not(s.active==Set()),s'={...s,active:Set(),closed:false}}
  action cancel(id:int):bool=all{s.queued.contains(id),s'={...s,queued:s.queued.exclude(Set(id))}}
  action drain=all{s.reader,s'={...s,reader:false}}
  action hardIntent=s'={...s,hard:true}
  action publishHard=all{s.hard,s.active==Set(),not(s.reader),
    s'={...s,hard:false,image:s.image+1}}
  action refresh=all{not(s.closed),not(s.hard),not(s.failed),s.owner==s.issuedOwner,s'={...s,qualified:s.image}}
  def ready:bool=s.known and not(s.failed) and not(s.closed) and not(s.hard) and
    s.serving and s.owner==s.issuedOwner and s.qualified==s.image and not(s.consumed)
  action offer=all{ready,s'={...s,consumed:true}}
  action loseOutcome(applied:bool):bool=all{s.closed,not(s.active==Set()),s.held+4<=12,
    s'={...s,known:false,failed:true,active:Set(),closed:true,image:s.image+(if(applied)1 else 0),
      held:s.held+(if(applied)4 else 0),claims:s.claims+(if(applied)1 else 0),history:s.history+(if(applied)1 else 0)}}
  action restart=s'={...s,owner:s.owner+1,queued:Set(),active:Set(),reader:false}
  action eagerQueue(id:int):bool=all{not(s.used.contains(id)),s'={...s,queued:s.queued.union(Set(id)),used:s.used.union(Set(id)),closed:true}}
  action unsafeWrite=all{not(s.active==Set()),not(s.closed),s'={...s,bad:true}}
  action runtimeSelection=all{s.sourceOpen,s'={...s,runtimeSource:true}}
  action unknownActivation=all{s.sourceOpen,s'={...s,sourceKnown:false,serving:false}}
  action closeBootstrapSource=all{s.sourceOpen,not(s.runtimeSource),s.sourceKnown,s'={...s,sourceOpen:false}}
  action cleanupSource=all{not(s.serving),s'={...s,sourceOpen:false}}
  action unsafeSourceClose=all{s.runtimeSource,s'={...s,sourceOpen:false}}
  action step={nondet id=Set(0,1,2,3).oneOf()
    nondet applied=Set(true,false).oneOf()
    any{enqueue(id),grant(id),close,commit,reject,cancel(id),drain,hardIntent,publishHard,refresh,offer,loseOutcome(applied),restart,runtimeSelection,unknownActivation,closeBootstrapSource,cleanupSource}}
  val safe=(s.serving implies s.sourceKnown) and ((s.serving and s.runtimeSource) implies s.sourceOpen) and not(s.bad) and s.held>=4 and s.held<=12 and s.claims==s.history and s.claims>=1
  run queuedAdmissionDoesNotCloseFrameTest=init.then(enqueue(0)).then(enqueue(1)).then(offer).expect(safe)
  run eagerQueueBlocksOldFrameCounterexampleTest=init.then(eagerQueue(0)).then(offer.fail())
  run selectedBeforeCloseStillCannotWriteTest=init.then(drain).then(enqueue(0)).then(grant(0)).then(commit.fail())
  run unclosedWriteCounterexampleTest=init.then(drain).then(enqueue(0)).then(grant(0)).then(unsafeWrite).expect(not(safe))
  run closedWriterBlocksFrameTest=init.then(drain).then(enqueue(0)).then(grant(0)).then(close).then(offer.fail())
  run committedWriterRetiresOldFrameTest=init.then(drain).then(enqueue(0)).then(grant(0)).then(close).then(commit).then(offer.fail())
  run pendingPolicyBlocksQueuedRequestAndFrameTest=init.then(enqueue(0)).then(hardIntent).then(offer.fail())
  run queuedCancellationHasNoReservationTest=init.then(enqueue(0)).then(cancel(0)).then(offer).expect(safe and s.held==4 and s.claims==1)
  run rollbackKeepsOriginalImageTest=init.then(drain).then(enqueue(0)).then(grant(0)).then(close).then(reject).then(offer).expect(safe and s.held==4)
  run lostCommittedResponseKeepsHoldTest=init.then(drain).then(enqueue(0)).then(grant(0)).then(close).then(loseOutcome(true)).expect(safe and s.held==8)
  run unknownAbsentOutcomeStillBlocksTest=init.then(drain).then(enqueue(0)).then(grant(0)).then(close).then(loseOutcome(false)).then(offer.fail())
  run oldOwnerCannotOfferTest=init.then(restart).then(offer.fail())
  run committedRefreshUsesCurrentViewTest=init.then(drain).then(enqueue(0)).then(grant(0)).then(close).then(commit).then(refresh).then(offer).expect(safe)
  run lostOutcomeCannotOfferTest=init.then(drain).then(enqueue(0)).then(grant(0)).then(close).then(loseOutcome(true)).then(offer.fail())  run knownBootstrapSourceCloseKeepsQualifiedFrameTest=init.then(closeBootstrapSource).then(offer).expect(safe and s.held==4)
  run runtimeCatalogMustRetainSourceTest=init.then(runtimeSelection).then(closeBootstrapSource.fail())
  run unknownBootstrapCannotCloseSourceTest=init.then(unknownActivation).then(closeBootstrapSource.fail())
  run prematureSourceCloseCounterexampleTest=init.then(runtimeSelection).then(unsafeSourceClose).expect(not(safe))
  run failedBootstrapCleanupDoesNotActivateIngressTest=init.then(unknownActivation).then(cleanupSource).then(offer.fail())

}
