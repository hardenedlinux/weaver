// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

module ProviderProfile {
  // Two original tasks and two immutable profile identities. Digest equality
  // abstracts the canonical artifact/hash relation, not cryptographic verification.
  type Effect={original:int,proposal:int,registry:int,closed:bool,provider:bool,current:bool}
  type Registration={proposal:int,original:int,registry:int}
  type State={registry:int->int,profile:int->int,digest:int->int,registered:Set[int],
    claimed:Set[int],burned:Set[int],tickets:Set[int],held:int->int,calls:int->int,
    ticketDigest:int->int,schema:int->bool,mode:int->bool,closed:bool,provider:bool,current:bool,effects:List[Effect],registrations:List[Registration]}
  var s:State
  val identities=Set(0,1)
  def floor(id:int,digest:int):bool=s.registered.forall(k=>s.profile.get(k)!=id or s.digest.get(k)==digest)
  def joined(k:int):bool=s.registered.contains(k) and s.registry.get(s.profile.get(k))==s.digest.get(k) and floor(s.profile.get(k),s.digest.get(k))
  val safe=s.registrations.indices().forall(i=>{val r=s.registrations.nth(i) r.proposal==r.original and r.proposal==r.registry}) and s.held.get(0)+s.held.get(1)<=8 and
    identities.forall(k=>s.calls.get(k)<=1 and (s.claimed.contains(k) implies (s.held.get(k)==4 and s.schema.get(k) and s.mode.get(k)))) and
    s.registered.forall(a=>s.registered.forall(b=>s.profile.get(a)!=s.profile.get(b) or s.digest.get(a)==s.digest.get(b))) and
    s.effects.indices().forall(i=>{val e=s.effects.nth(i) e.original==e.proposal and e.original==e.registry and e.closed and e.provider and e.current})
  action init=s'={registry:Map(-1-> -1,0-> -1,1-> -1),profile:Map(0-> -1,1-> -1),digest:Map(0-> -1,1-> -1),
    registered:Set(),claimed:Set(),burned:Set(),tickets:Set(),held:Map(0->0,1->0),calls:Map(0->0,1->0),
    ticketDigest:Map(0-> -1,1-> -1),schema:Map(0->false,1->false),mode:Map(0->false,1->false),closed:true,provider:true,current:true,effects:[],registrations:[]}
  // Registry and original task are published in the same deciding transaction.
  action register(k:int,id:int,digest:int):bool=all {
    identities.contains(k),identities.contains(id),identities.contains(digest),floor(id,digest),
    not(s.registered.contains(k)) or (s.profile.get(k)==id and s.digest.get(k)==digest),
    s.registry.get(id)== -1 or s.registry.get(id)==digest,
    s'=s.with("registry",s.registry.set(id,digest)).with("profile",s.profile.set(k,id))
      .with("digest",s.digest.set(k,digest)).with("registered",s.registered.union(Set(k)))
      .with("registrations",s.registrations.append({proposal:digest,original:digest,registry:digest}))
  }
  action claim(k:int,proposal:int):bool=all {
    identities.contains(k),joined(k),proposal==s.digest.get(k),s.closed,s.provider,s.current,not(s.claimed.contains(k)),
    s.held.get(0)+s.held.get(1)+4<=8,
    s'=s.with("claimed",s.claimed.union(Set(k))).with("held",s.held.set(k,4)).with("schema",s.schema.set(k,s.closed)).with("mode",s.mode.set(k,s.provider))
  }
  action burn(k:int):bool=all {
    s.claimed.contains(k),not(s.burned.contains(k)),joined(k),s.current,
    s'=s.with("burned",s.burned.union(Set(k))).with("tickets",s.tickets.union(Set(k)))
      .with("ticketDigest",s.ticketDigest.set(k,s.digest.get(k)))
  }
  action send(k:int,checkRegistry:bool):bool=all {
    s.tickets.contains(k),s.current,(checkRegistry implies joined(k)),
    s'=s.with("tickets",s.tickets.exclude(Set(k))).with("calls",s.calls.set(k,s.calls.get(k)+1))
      .with("effects",s.effects.append({original:s.digest.get(k),proposal:s.ticketDigest.get(k),
        registry:s.registry.get(s.profile.get(k)),closed:s.schema.get(k),provider:s.mode.get(k),current:s.current}))
  }
  // Partial projection restoration is permitted as a fault, never as authority.
  action restore(id:int,value:int):bool=s'=s.with("registry",s.registry.set(id,value))
  action restart=s'=s.with("tickets",Set())
  action observe=s'=s
  action revoke=s'=s.with("current",false)
  action unknownField=s'=s.with("closed",false)
  action rawPath=s'=s.with("provider",false)
  action unsafeRegisterWithoutFloor(k:int,id:int,digest:int):bool=all {
    not(s.registered.contains(k)),s.registry.get(id)== -1,
    s'=s.with("registry",s.registry.set(id,digest)).with("profile",s.profile.set(k,id))
      .with("digest",s.digest.set(k,digest)).with("registered",s.registered.union(Set(k)))
  }
  action unsafeSplitRegistrationAck=s'=s.with("registry",s.registry.set(0,0))
    .with("registrations",s.registrations.append({proposal:0,original:if(s.registered.contains(0)) s.digest.get(0) else -1,registry:0}))
  action unsafeReissue(k:int):bool=all {s.burned.contains(k),s'=s.with("tickets",s.tickets.union(Set(k)))}
  action unsafeSchemaClaim(k:int):bool=all {
    joined(k),s.current,not(s.claimed.contains(k)),
    s'=s.with("claimed",s.claimed.union(Set(k))).with("held",s.held.set(k,4)).with("schema",s.schema.set(k,s.closed)).with("mode",s.mode.set(k,s.provider))
  }
  action step={
    nondet k=identities.oneOf()
    nondet id=identities.oneOf()
    nondet digest=identities.oneOf()
    nondet restored=Set(-1,0,1).oneOf()
    any {register(k,id,digest),claim(k,digest),burn(k),send(k,true),restore(id,restored),restart,observe,revoke,unknownField,rawPath}
  }
  action bound=init.then(register(0,0,0))
  action consumed=bound.then(claim(0,0)).then(burn(0))
  action sent=consumed.then(send(0,true))
  run sourceRegistrationDoesNotSendTest=bound.expect(safe and s.calls.get(0)==0 and s.held.get(0)==0)
  run exactLostReplyRegistrationRetainsHoldTest=consumed.then(observe).then(register(0,0,0)).expect(safe and s.held.get(0)==4)
  run wrongProfileDigestCannotClaimTest=bound.then(claim(0,1).fail())
  run immutableProfileIdentityTest=bound.then(register(1,0,1).fail())
  run originalTaskCannotRebindProfileTest=bound.then(register(0,1,1).fail())
  run missingRegistryDoesNotEraseFloorTest=bound.then(restore(0,-1)).then(register(1,0,1).fail())
  run exactFloorRecoveryResumesOriginalClaimTest=bound.then(claim(0,0)).then(restore(0,-1)).then(register(0,0,0)).then(burn(0)).then(send(0,true)).expect(safe and s.held.get(0)==4)
  run cachedTicketCannotBypassRestoredRegistryTest=consumed.then(restore(0,1)).then(send(0,true).fail())
  run cachedTicketRegistryCounterexampleTest=consumed.then(restore(0,1)).then(send(0,false)).expect(not(safe))
  run missingFloorCounterexampleTest=bound.then(restore(0,-1)).then(unsafeRegisterWithoutFloor(1,0,1)).expect(not(safe))
  run splitRegistrationAckCounterexampleTest=init.then(unsafeSplitRegistrationAck).expect(not(safe))
  run unknownExtensionCannotClaimTest=bound.then(unknownField).then(claim(0,0).fail())
  run newProposalCannotRewriteConsumedSchemaTest=consumed.then(unknownField).then(send(0,true)).expect(safe)
  run missingSchemaGuardCounterexampleTest=bound.then(unknownField).then(unsafeSchemaClaim(0)).then(burn(0)).then(send(0,true)).expect(not(safe))
  run restartNeverReissuesOriginalTicketTest=consumed.then(restart).then(register(0,0,0)).expect(safe and s.held.get(0)==4).then(burn(0).fail())
  run replayAfterCompletedSendCannotBurnTest=sent.then(register(0,0,0)).then(burn(0).fail())
  run recoveredTicketCounterexampleTest=sent.then(restart).then(register(0,0,0)).then(unsafeReissue(0)).then(send(0,true)).expect(not(safe))
  run independentProfilesShareBudgetTest=bound.then(register(1,1,1)).then(claim(0,0)).then(claim(1,1)).expect(safe and s.held.get(0)+s.held.get(1)==8)
  run providerCannotUseRawPathTest=bound.then(rawPath).then(claim(0,0).fail())
  run rawFallbackCounterexampleTest=bound.then(rawPath).then(unsafeSchemaClaim(0)).then(burn(0)).then(send(0,true)).expect(not(safe))
}
