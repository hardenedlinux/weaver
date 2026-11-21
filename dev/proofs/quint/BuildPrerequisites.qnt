// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

// One shared prerequisite and one consumer output. Artifact authenticity is an
// assumed owner guarantee, not established by a filename or package version.
module BuildPrerequisites {
  type Use = {present:bool,authentic:bool,content:int,artifactContent:int,
    sourceEpoch:int,artifactEpoch:int,boundSource:int,boundArtifact:int}
  type State = {present:bool,authentic:bool,content:int,artifactContent:int,
    sourceEpoch:int,artifactEpoch:int,boundSource:int,boundArtifact:int,
    prepared:bool,privateOutput:bool,cleanedShared:bool,history:List[Use]}
  var s:State
  val fresh=s.present and s.authentic and s.content==s.artifactContent
  val sameCut=s.sourceEpoch==s.boundSource and s.artifactEpoch==s.boundArtifact
  val safe=not(s.cleanedShared) and s.history.indices().forall(i=>{
    val u=s.history.nth(i)
    u.present and u.authentic and u.content==u.artifactContent and
      u.sourceEpoch==u.boundSource and u.artifactEpoch==u.boundArtifact
  })
  action init=s'={present:true,authentic:true,content:0,artifactContent:0,
    sourceEpoch:0,artifactEpoch:0,boundSource:0,boundArtifact:0,
    prepared:false,privateOutput:false,cleanedShared:false,history:[]}
  action bind=s'=s.with("boundSource",s.sourceEpoch).with("boundArtifact",s.artifactEpoch).with("prepared",true)
  action prepare=all{fresh,bind}
  action presenceOnlyPrepare=all{s.present,bind}
  action use=s'=s.with("privateOutput",true).with("history",s.history.append({
    present:s.present,authentic:s.authentic,content:s.content,artifactContent:s.artifactContent,
    sourceEpoch:s.sourceEpoch,artifactEpoch:s.artifactEpoch,
    boundSource:s.boundSource,boundArtifact:s.boundArtifact}))
  action consume=all{s.prepared,fresh,sameCut,use}
  action consumeByPresence=all{s.prepared,s.present,use}
  action consumeByContent=all{s.prepared,s.present,s.content==s.artifactContent,use}
  action changeSource=all{s.sourceEpoch<3,s'=s.with("sourceEpoch",s.sourceEpoch+1).with("content",1-s.content)}
  action rebuild=all{s.artifactEpoch<3,s'=s.with("artifactEpoch",s.artifactEpoch+1)
    .with("artifactContent",s.content).with("authentic",true).with("present",true)}
  action tamper=all{s.artifactEpoch<3,s'=s.with("artifactEpoch",s.artifactEpoch+1).with("authentic",false)}
  action evict=s'=s.with("present",false)
  action cleanPrivate=s'=s.with("privateOutput",false)
  action cleanShared=s'=s.with("privateOutput",false).with("present",false).with("cleanedShared",true)
  action observe=s'=s
  action step=any{prepare,consume,changeSource,rebuild,tamper,evict,cleanPrivate,observe}
  action presenceStep=any{presenceOnlyPrepare,consumeByPresence,changeSource,rebuild,tamper,evict,cleanPrivate,observe}
  action contentStep=any{prepare,consumeByContent,changeSource,rebuild,tamper,evict,cleanPrivate,observe}
  run stableReuseTest=init.then(prepare).then(consume).expect(safe and s.privateOutput)
  run sourceChangeRefusesOldPreparationTest=init.then(prepare).then(changeSource).then(consume.fail())
  run changedArtifactRefusesOldPreparationTest=init.then(prepare).then(tamper).then(consume.fail())
  run presenceCannotProveArtifactSourceTest=init.then(changeSource).then(presenceOnlyPrepare).then(consumeByPresence).expect(not(safe))
  run sameContentCannotProveArtifactIdentityTest=init.then(prepare).then(tamper).then(consumeByContent).expect(not(safe))
  run abaRefusesOldCutTest=init.then(prepare).then(changeSource).then(changeSource).then(consumeByContent).expect(not(safe))
  run abaCanReuseArtifactAfterFreshAdmissionTest=init.then(prepare).then(changeSource).then(changeSource)
    .then(prepare).then(consume).expect(safe and s.artifactEpoch==0)
  run changedContentCannotPrepareTest=init.then(changeSource).then(prepare.fail())
  run changedContentRebuildsTest=init.then(changeSource).then(rebuild).then(prepare).then(consume).expect(safe)
  run cleanupPreservesSharedPrerequisiteTest=init.then(prepare).then(consume).then(cleanPrivate).expect(safe and s.present and not(s.privateOutput))
  run cleanupCannotOwnSharedArtifactTest=init.then(cleanShared).expect(not(safe))
}
