// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

module RuntimeLifecycle {
  import StreamingExecution as E from "./StreamingExecution"
  type Owner = {closing:bool, ack:bool, tracked:Set[int], running:Set[int], detached:Set[int], atAck:int}
  var owner:Owner
  val jobs = Set(0,1)
  val safe = E::safe and owner.running.subseteq(owner.tracked) and
    (owner.ack implies owner.closing and owner.tracked==Set() and E::s.invoked==owner.atAck)
  action init = all {E::init, owner'={closing:false,ack:false,tracked:Set(),running:Set(),detached:Set(),atAck:0}}
  action inert = owner'=owner
  action admit(j:int):bool = all {not(owner.closing),not(owner.tracked.contains(j)),
    owner'=owner.with("tracked",owner.tracked.union(Set(j))),E::lostReply}
  action begin(j:int):bool = all {not(owner.closing),owner.tracked.contains(j),not(owner.running.contains(j)),
    owner'=owner.with("running",owner.running.union(Set(j))),E::lostReply}
  action disconnect(j:int):bool = all {owner.tracked.contains(j),
    owner'=owner.with("detached",owner.detached.union(Set(j))),E::lostReply}
  action close = all {owner'=owner.with("closing",true),E::lostReply}
  action finish(j:int):bool = all {owner.tracked.contains(j),not(E::s.lock),
    owner'=owner.with("tracked",owner.tracked.exclude(Set(j))).with("running",owner.running.exclude(Set(j))),E::lostReply}
  action drain = all {owner.closing,owner.tracked==Set(),
    owner'=owner.with("ack",true).with("atAck",E::s.invoked),E::lostReply}
  action newRange = all {not(owner.closing),owner.running!=Set(),E::burn(0,E::s.generation),inert}
  action enterGuard = all {owner.running!=Set(),E::finalGuard,inert}
  action write = all {owner.running!=Set(),E::fullWrite,inert}
  action commit = all {owner.running!=Set(),E::commit,inert}
  action crash = all {E::crash,inert}
  action prepare = all {not(owner.closing),E::queue(0,true),inert}
  action claim = all {not(owner.closing),E::claim,inert}
  action publish = all {E::publish(false),inert}
  action unsafeUntrack(j:int):bool = all {owner.running.contains(j),
    owner'=owner.with("tracked",owner.tracked.exclude(Set(j))),E::lostReply}
  action unsafeEarlyAck = all {owner.closing,owner'=owner.with("ack",true).with("atAck",E::s.invoked),E::lostReply}
  action step = {nondet j=jobs.oneOf() any {admit(j),begin(j),disconnect(j),close,finish(j),drain,
    newRange,enterGuard,write,commit,crash,prepare,claim,publish}}
  action active = init.then(prepare).then(claim).then(admit(0)).then(begin(0))
  run disconnectedCallerStillTrackedTest = active.then(disconnect(0)).expect(safe and owner.tracked==Set(0))
  run shutdownRejectsNewAdmissionTest = active.then(close).then(admit(1).fail())
  run shutdownRejectsNewRangeTest = active.then(close).then(newRange.fail())
  run inFlightWriteMustDrainTest = active.then(newRange).then(enterGuard).then(close)
    .then(all {owner.tracked!=Set(),inert,E::lostReply}).then(write).then(commit).then(finish(0)).then(drain).expect(safe and E::held==1)
  run noWriteAfterAcknowledgmentTest = active.then(close).then(finish(0)).then(drain).then(write.fail())
  run unknownShutdownRetainsHoldTest = active.then(newRange).then(crash).then(close).then(finish(0)).then(drain)
    .expect(safe and E::held==1 and E::s.status.get(0)==3)
  run detachedUntrackCounterexampleTest = active.then(disconnect(0)).then(unsafeUntrack(0)).expect(not(safe))
  run prematureAckCounterexampleTest = active.then(close).then(unsafeEarlyAck).expect(not(safe))
}
