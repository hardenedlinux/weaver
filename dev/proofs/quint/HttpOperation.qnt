// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

// HTTP capability binding only. Native SQL, TLS, byte custody and scheduling
// remain runtime obligations covered by their own models and actual transports.
module HttpOperation {
  // consistent abstracts byte-identical bounded caller-supplied values; realm
  // names that one credential. It never unions two independently valid roles.
  type Caller = {realm:int,bearer:int,api:int,consistent:bool}
  type Cut = {generation:int,available:bool,protocol:int}
  type Receipt = {caller:Caller,path:int,actual:Cut,observed:Cut}
  type State = {live:Cut,cached:Cut,history:List[Receipt]}
  var s:State
  pure def authenticated(c:Caller):bool = c.realm==0 and (
    (c.bearer==1 and c.api==0) or (c.bearer==0 and c.api==1) or
    (c.bearer==1 and c.api==1 and c.consistent))
  val safe = s.history.indices().forall(i => {
    val receipt=s.history.nth(i)
    authenticated(receipt.caller) and receipt.actual.available and receipt.path==receipt.actual.protocol
  })
  action init = s'={live:{generation:0,available:true,protocol:0},cached:{generation:0,available:true,protocol:0},history:[]}
  action observe = s'=s.with("cached",s.live)
  action replace(available:bool,protocol:int):bool = s'=s.with("live",{generation:s.live.generation+1,available:available,protocol:protocol})
  action accept(c:Caller,path:int):bool = s'=s.with("history",s.history.append({caller:c,path:path,actual:s.live,observed:s.cached}))
  action admit(c:Caller,path:int):bool = all {authenticated(c),s.live.available,path==s.live.protocol,accept(c,path)}
  action cachedCatalogAdmit(c:Caller,path:int):bool = all {authenticated(c),s.cached.available,path==s.cached.protocol,accept(c,path)}
  action credentialUnionAdmit(c:Caller,path:int):bool = all {c.bearer+c.api>0,s.live.available,path==s.live.protocol,accept(c,path)}
  action explore(strategy:int):bool = {
    nondet realm=0.to(3).oneOf()
    nondet bearer=0.to(2).oneOf()
    nondet api=0.to(2).oneOf()
    nondet consistent=Set(true,false).oneOf()
    nondet path=0.to(2).oneOf()
    nondet available=Set(true,false).oneOf()
    val caller={realm:realm,bearer:bearer,api:api,consistent:consistent}
    any {observe,replace(available,path),
      if(strategy==1) cachedCatalogAdmit(caller,path)
      else if(strategy==2) credentialUnionAdmit(caller,path)
      else admit(caller,path)}
  }
  action step = explore(0)
  action cachedCatalogStep = explore(1)
  action credentialUnionStep = explore(2)
  run dedicatedBearerTest = init.then(admit({realm:0,bearer:1,api:0,consistent:true},0)).expect(safe)
  run dedicatedApiKeyTest = init.then(admit({realm:0,bearer:0,api:1,consistent:true},0)).expect(safe)
  run sourceTokenCannotExecuteTest = init.then(admit({realm:2,bearer:1,api:0,consistent:true},0).fail())
  run ambiguousHeadersCannotExecuteTest = init.then(admit({realm:0,bearer:1,api:1,consistent:false},0).fail())
  run protocolReplacementRejectsOldPathTest = init.then(replace(true,1)).then(admit({realm:0,bearer:1,api:0,consistent:true},0).fail())
  run cachedCatalogMissesWithdrawalTest = init.then(replace(false,0)).then(cachedCatalogAdmit({realm:0,bearer:1,api:0,consistent:true},0)).expect(not(safe))
  run cachedCatalogMissesProtocolReplacementTest = init.then(replace(true,1)).then(cachedCatalogAdmit({realm:0,bearer:1,api:0,consistent:true},0)).expect(not(safe))
  run credentialUnionAcceptsSourceRealmTest = init.then(credentialUnionAdmit({realm:2,bearer:1,api:0,consistent:true},0)).expect(not(safe))
  run matchingEncodingsNameOneIdentityTest = init.then(admit({realm:0,bearer:1,api:1,consistent:true},0)).expect(safe and s.history.length()==1)
  run matchingSourceEncodingStillDeniedTest = init.then(admit({realm:2,bearer:1,api:1,consistent:true},0).fail())
  run repeatedHeaderFieldsStillDeniedTest = init.then(admit({realm:0,bearer:2,api:1,consistent:true},0).fail())
  run acceptingEitherCredentialMissesConflictTest = init.then(credentialUnionAdmit({realm:0,bearer:1,api:1,consistent:false},0)).expect(not(safe))
}
