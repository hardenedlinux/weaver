// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

module ProviderLifecycleFootprint {
  pure val families=Set(0,1,2)
  type State={whole:int,cut:int,actual:int,origin:int->int,local:int->int,
    certCut:int->int,certView:int->int,certOrigin:int->int,certLocal:int->int,
    pending:Set[int],used:Set[int],writer:int->int,shared:int->bool,
    owner:int,certOwner:int->int,held:int,failed:bool,allowed:bool,
    offers:int->int,bad:bool,calls:int}
  var s:State
  action init=s'={whole:0,cut:0,actual:0,origin:families.mapBy(_=>0),local:families.mapBy(_=>0),
    certCut:families.mapBy(_=>0),certView:families.mapBy(_=>0),
    certOrigin:families.mapBy(_=>0),certLocal:families.mapBy(_=>0),
    pending:Set(),used:Set(),writer:Set(0,1,2,3,4,5).mapBy(_=>0),
    shared:Set(0,1,2,3,4,5).mapBy(_=>false),owner:1,
    certOwner:families.mapBy(_=>1),held:12,failed:false,allowed:true,
    offers:families.mapBy(_=>0),bad:false,calls:3}
  def closed(f:int):bool=s.pending.exists(id=>s.shared.get(id) or s.writer.get(id)==f)
  action begin(id:int,f:int,broad:bool):bool=all {not(s.used.contains(id)),not(s.failed),
    s'={...s,pending:s.pending.union(Set(id)),used:s.used.union(Set(id)),
      writer:s.writer.set(id,f),shared:s.shared.set(id,broad)}}
  action commitLocal(id:int):bool=all {s.pending.contains(id),not(s.shared.get(id)),
    val f=s.writer.get(id)
    s'={...s,whole:s.whole+1,pending:s.pending.exclude(Set(id)),origin:s.origin.set(f,s.origin.get(f)+1),
      local:s.local.set(f,s.local.get(f)+1)}}
  action commitAdmission(id:int):bool=all {s.pending.contains(id),s.shared.get(id),
    s'={...s,whole:s.whole+1,pending:s.pending.exclude(Set(id)),cut:s.cut+1,actual:s.actual+1,held:s.held+4}}
  action rollback(id:int):bool=all {s.pending.contains(id),s'={...s,pending:s.pending.exclude(Set(id))}}
  action unknown(id:int):bool=all {s.pending.contains(id),s'={...s,failed:true}}
  action revoke=s'={...s,whole:s.whole+1,cut:s.cut+1,actual:s.actual+1,allowed:false}
  action migrate=s'={...s,whole:s.whole+1,cut:s.cut+1,actual:s.actual+1}
  action restart=s'={...s,owner:s.owner+1,failed:false,pending:Set()}
  action qualify(f:int):bool=all {not(closed(f)),not(s.failed),s.allowed,s.local.get(f)==0,
    s.certOwner.get(f)==s.owner,
    s'={...s,certCut:s.certCut.set(f,s.cut),certView:s.certView.set(f,s.actual),
      certOrigin:s.certOrigin.set(f,s.origin.get(f)),certLocal:s.certLocal.set(f,s.local.get(f))}}
  action offer(f:int):bool=all {not(closed(f)),not(s.failed),s.allowed,
    s.certOwner.get(f)==s.owner,s.certCut.get(f)==s.cut,s.certOrigin.get(f)==s.origin.get(f),
    s.offers.get(f)==0,
    s'={...s,offers:s.offers.set(f,1),bad:s.bad or s.certView.get(f)!=s.actual or s.certLocal.get(f)!=s.local.get(f)}}
  // Unsafe mutants change an actual dependency without its corresponding cut.
  action unsafeAdmissionAsLocal(id:int):bool=all {s.pending.contains(id),
    s'={...s,pending:s.pending.exclude(Set(id)),actual:s.actual+1,held:s.held+4}}
  action unsafeTerminalWithoutOwnCut(f:int):bool=s'={...s,local:s.local.set(f,s.local.get(f)+1)}
  action wholeOffer=all {s.whole==0,s.pending.size()==0,not(s.failed),s.owner==1,s'=s}
  action step={nondet f=families.oneOf()
    nondet id=Set(0,1,2,3,4,5).oneOf()
    nondet broad=Set(true,false).oneOf()
    any {begin(id,f,broad),commitLocal(id),commitAdmission(id),rollback(id),unknown(id),
      revoke,migrate,restart,qualify(f),offer(f)}}
  val safe=not(s.bad) and s.held>=12 and s.calls==3 and families.forall(f=>s.offers.get(f)<=1)
  run peerFrameCrossesPendingLocalTest=init.then(begin(0,0,false)).then(offer(1)).expect(safe)
  run peerFrameCrossesCommittedLocalTest=init.then(begin(0,0,false)).then(commitLocal(0)).then(offer(1)).expect(safe)
  run ownPendingLocalBlocksTest=init.then(begin(0,0,false)).then(offer(0).fail())
  run ownCommittedLocalBlocksTest=init.then(begin(0,0,false)).then(commitLocal(0)).then(offer(0).fail())
  run sharedAdmissionClosesPeersTest=init.then(begin(0,0,true)).then(offer(1).fail())
  run sharedAdmissionRequiresRefreshTest=init.then(begin(0,0,true)).then(commitAdmission(0)).then(offer(1).fail())
  run newViewResumesPeerTest=init.then(begin(0,0,true)).then(commitAdmission(0)).then(qualify(1)).then(offer(1)).expect(safe)
  run localRollbackPreservesOwnTest=init.then(begin(0,0,false)).then(rollback(0)).then(offer(0)).expect(safe)
  run localUnknownSealsPeersTest=init.then(begin(0,0,false)).then(unknown(0)).then(offer(1).fail())
  run restartCannotAdoptOldPeerTest=init.then(begin(0,0,false)).then(unknown(0)).then(restart).then(offer(1).fail())
  run migrationRetiresPeerTest=init.then(migrate).then(offer(1).fail())
  run revocationRetiresPeerTest=init.then(revoke).then(offer(1).fail())
  run twoLocalWritersRetainThirdTest=init.then(begin(0,0,false)).then(begin(1,1,false)).then(commitLocal(1)).then(offer(2)).expect(safe and closed(0))
  run localCommitRetiresWholeReaderTest=init.then(begin(0,0,false)).then(commitLocal(0)).then(wholeOffer.fail())
  run localPendingBlocksWholeReaderTest=init.then(begin(0,0,false)).then(wholeOffer.fail())
  run unsafeNarrowAdmissionCounterexampleTest=init.then(begin(0,0,false)).then(unsafeAdmissionAsLocal(0)).then(offer(1)).expect(not(safe))
  run unsafeSkipOwnTerminalCounterexampleTest=init.then(unsafeTerminalWithoutOwnCut(0)).then(offer(0)).expect(not(safe))
}
