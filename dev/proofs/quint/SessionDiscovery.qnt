// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

// Observations are historical reads, not reusable send permission. The oracle
// compares receipt/effect histories; competing actions never set an unsafe flag.
module SessionDiscovery {
  type Cut={reader:bool,operation:bool,source:int,publication:int,facts:int,prefix:int,
    available:bool,pending:bool,published:bool}
  type Key={source:int,publication:int,facts:int,prefix:int}
  type View={key:Key,cut:Cut}
  type Effect={admitted:bool,cut:Cut,facts:int,prefix:int}
  type S={cut:Cut,observed:bool,seen:Cut,admitted:bool,admitFacts:int,admitPrefix:int,
    admissions:int,rows:int,views:List[View],effects:List[Effect]}
  var s:S
  pure def permitted(c:Cut):bool=c.reader and c.operation and c.source==0 and c.publication==0 and
    c.published and c.available and not(c.pending)
  pure def version(c:Cut):Key={source:c.source,publication:c.publication,facts:c.facts,prefix:c.prefix}
  val current=permitted(s.cut)
  val fresh=s.observed and current and version(s.seen)==version(s.cut)
  val safe=s.rows==s.admissions and
    s.views.indices().forall(i=>permitted(s.views.nth(i).cut)) and
    s.views.indices().forall(i=>s.views.indices().forall(j=>
      s.views.nth(i).key!=s.views.nth(j).key or version(s.views.nth(i).cut)==version(s.views.nth(j).cut))) and
    s.effects.indices().forall(i=>{
      val e=s.effects.nth(i)
      e.admitted and permitted(e.cut) and e.facts==e.cut.facts and e.prefix==e.cut.prefix
    })
  action init={
    val c={reader:true,operation:true,source:0,publication:0,facts:0,prefix:0,
      available:true,pending:false,published:true}
    s'={cut:c,observed:false,seen:c,admitted:false,admitFacts: -1,admitPrefix: -1,
      admissions:0,rows:0,views:List(),effects:List()}
  }
  action readWith(key:Key):bool=all {current,s'=s.with("observed",true).with("seen",s.cut)
    .with("views",s.views.append({key:key,cut:s.cut}))}
  action discover=readWith(version(s.cut))
  action separateAdmission=all {current,not(s.admitted),s'=s.with("admitted",true)
    .with("admitFacts",s.cut.facts).with("admitPrefix",s.cut.prefix)
    .with("admissions",s.admissions+1).with("rows",s.rows+1)}
  action send=all {current,s.admitted,s.admitFacts==s.cut.facts,s.admitPrefix==s.cut.prefix,s.effects.length()==0,
    s'=s.with("effects",s.effects.append({admitted:s.admitted,cut:s.cut,facts:s.admitFacts,prefix:s.admitPrefix}))}
  action stage=s'=s.with("cut",s.cut.with("pending",true).with("prefix",s.cut.prefix+1))
  action resolveUnavailable=all {s.cut.pending,s'=s.with("cut",s.cut.with("pending",false)
    .with("available",false).with("facts",s.cut.facts+1))}
  action resolveAvailable=all {s.cut.pending,s'=s.with("cut",s.cut.with("pending",false)
    .with("available",true).with("facts",s.cut.facts+1))}
  action rotateSource=s'=s.with("cut",s.cut.with("source",s.cut.source+1))
  action replacePublication=s'=s.with("cut",s.cut.with("publication",s.cut.publication+1))
  action pendingPublication=s'=s.with("cut",s.cut.with("published",false))
  action foreignPrincipal=s'=s.with("cut",s.cut.with("reader",false))
  action sourceIngress=s'=s.with("cut",s.cut.with("operation",false))
  action restart=s'=s.with("observed",false)
  action observe=s'=s
  action changes=any {stage,resolveUnavailable,resolveAvailable,rotateSource,replacePublication,
    pendingPublication,foreignPrincipal,sourceIngress,restart,observe}
  action step=any {discover,separateAdmission,send,changes}
  // Scope-only versions, cached visibility, and catalog-as-permit are alternatives
  // under challenge, not implementations decorated with an unsafe=true marker.
  action coarseRead=readWith({source:0,publication:0,facts:0,prefix:0})
  action catalogSend=all {s.observed,s.effects.length()==0,
    s'=s.with("effects",s.effects.append({admitted:s.admitted,cut:s.cut,facts:s.seen.facts,prefix:s.seen.prefix}))}
  action cachedRead=all {s.observed,s'=s.with("views",s.views.append({key:version(s.seen),cut:s.cut}))}
  action coarseVersionStep=any {coarseRead,changes}
  action catalogPermitStep=any {discover,catalogSend,changes}
  action cachedViewStep=any {discover,cachedRead,changes}
  run discoveryCreatesNoEffectTest=init.then(discover).then(discover)
    .expect(safe and s.rows==0 and s.effects.length()==0).then(send.fail())
  run foreignPrincipalCannotDiscoverTest=init.then(foreignPrincipal).then(discover.fail())
  run sourceIngressCannotDiscoverTest=init.then(sourceIngress).then(discover.fail())
  run pendingFactsCannotDiscoverTest=init.then(discover).then(stage).then(discover.fail())
  run withdrawnFactsCannotDiscoverTest=init.then(stage).then(resolveUnavailable).then(discover.fail())
  run sourceRotationCannotDiscoverTest=init.then(rotateSource).then(discover.fail())
  run publicationReplacementCannotDiscoverTest=init.then(replacePublication).then(discover.fail())
  run pendingPublicationCannotDiscoverTest=init.then(pendingPublication).then(discover.fail())
  run abaCannotRestoreOldObservationTest=init.then(discover).then(stage).then(resolveUnavailable)
    .then(stage).then(resolveAvailable).expect(not(fresh) and safe)
    .then(discover).expect(fresh and s.seen.facts==2 and s.seen.prefix==2 and safe)
  run restartObservesSameCutTest=init.then(discover).then(restart).then(discover)
    .expect(fresh and s.seen.facts==0 and s.seen.prefix==0 and safe)
  run finalUseRechecksFactsTest=init.then(discover).then(separateAdmission).then(stage).then(send.fail())
  run catalogPermitCounterexampleTest=init.then(discover).then(catalogSend).expect(not(safe))
  run cachedVisibilityCounterexampleTest=init.then(discover).then(stage).then(cachedRead).expect(not(safe))
  run coarseVersionCounterexampleTest=init.then(coarseRead).then(stage).then(resolveAvailable)
    .then(coarseRead).expect(not(safe))
}
