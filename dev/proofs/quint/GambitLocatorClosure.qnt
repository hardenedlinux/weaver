// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

module GambitLocatorClosure {
  type State={image0:int,image1:int,entry0:int,entry1:int,source0:int,source1:int,complete:bool,pureBodies:bool,published:bool,init:Set[int],opened:Set[int],closed:Set[int],stopping:bool}
  var s:State
  pure val initial:State={image0:0,image1:1,entry0:7,entry1:7,source0:11,source1:12,complete:false,pureBodies:true,published:false,init:Set(),opened:Set(),closed:Set(),stopping:false}
  val collisionFree:bool=s.image0!=s.image1 or s.entry0!=s.entry1
  val admissible:bool=s.complete and s.pureBodies and collisionFree and s.entry0==7 and s.entry1==7 and s.source0==11 and s.source1==12
  val safe:bool=(not(s.published) or admissible) and s.init.subseteq(s.opened)
  action boot:bool=s'=initial
  action completeBuild:bool=s'=s.with("complete",true)
  action publish:bool=all {admissible,s'=s.with("published",true)}
  action acquire(mid:int):bool=all {s.published,not(s.stopping),not(s.opened.contains(mid)),s'=s.with("opened",s.opened.union(Set(mid)))}
  action initialize(mid:int,image:int,entry:int):bool=all {not(s.stopping),s.opened.contains(mid),not(s.closed.contains(mid)),not(s.init.contains(mid)),image==(if (mid==0) s.image0 else s.image1),entry==(if (mid==0) s.entry0 else s.entry1),s'=s.with("init",s.init.union(Set(mid)))}
  action closeRef(mid:int):bool=all {s.opened.contains(mid),not(s.closed.contains(mid)),s'=s.with("closed",s.closed.union(Set(mid)))}
  action ready:bool=boot.then(completeBuild).then(publish)
  action collide:bool=s'=s.with("image1",0)
  action foreignBody:bool=s'=s.with("pureBodies",false)
  action rewriteEntry:bool=s'=s.with("entry1",8)
  action replaceSource:bool=s'=s.with("source1",99)
  action unsafePublish:bool=s'=s.with("published",true)
  action unsafeBareLookup:bool=s'=s.with("init",s.init.union(Set(0)))
  run replacedSourceRejectedTest=boot.then(completeBuild).then(replaceSource).then(publish.fail())
  run sourceCommitmentBypassCounterexampleTest=boot.then(completeBuild).then(replaceSource).then(unsafePublish).expect(not(safe))
  run sameNameDifferentImagesTest=ready.expect(safe and s.entry0==s.entry1 and s.image0!=s.image1)
  run oneImageCollisionRejectedTest=boot.then(completeBuild).then(collide).then(publish.fail())
  run incompleteProducerRejectedTest=boot.then(publish.fail())
  run foreignBodyRejectedTest=boot.then(completeBuild).then(foreignBody).then(publish.fail())
  run rewrittenEntryRejectedTest=boot.then(completeBuild).then(rewriteEntry).then(publish.fail())
  run wrongHandleRejectedTest=ready.then(acquire(1)).then(initialize(1,0,7).fail())
  run qualifiedHandleInitializesOwnerTest=ready.then(acquire(1)).then(initialize(1,1,7)).expect(s.init==Set(1))
  run mappingIsNotInitializationTest=ready.then(acquire(0)).then(acquire(1)).expect(s.init==Set())
  run closedReferenceCannotInitializeTest=ready.then(acquire(0)).then(closeRef(0)).then(initialize(0,0,7).fail())
  run duplicateInitializationRejectedTest=ready.then(acquire(1)).then(initialize(1,1,7)).then(initialize(1,1,7).fail())
  run collisionBypassCounterexampleTest=boot.then(completeBuild).then(collide).then(unsafePublish).expect(not(safe))
  run missingCompletionCounterexampleTest=boot.then(unsafePublish).expect(not(safe))
  run bareLookupWrongOwnerCounterexampleTest=ready.then(acquire(1)).then(unsafeBareLookup).expect(s.init==Set(0) and not(s.opened.contains(0)) and not(safe))
}
