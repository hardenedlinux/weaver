// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

// Distinct from stream preparation: this challenges POO result lifetime.
// Integers abstract the commitment AND routes; admitted inputs are an
// independent oracle, not reconstructed from the owner after a caller edit.
module RetainedSelection {
  type Cut={generation:int,expected:int,value:int,mode:int,edited:bool}
  type Read={expected:int,actual:int}
  type S={generation:int,inputs:int -> int,cells:int -> int,cuts:List[Cut],reads:List[Read]}
  var s:S
  val safe=s.cells.get(s.generation)==s.inputs.get(s.generation) and
    s.reads.indices().forall(i=>s.reads.nth(i).actual==s.reads.nth(i).expected)
  action init=s'={generation:0,inputs:Map(0 -> 0,1 -> 1,2 -> 0),
    cells:Map(0 -> 0,1 -> 1,2 -> 0),cuts:List(),reads:List()}
  action rebind=all {s.generation<2,s'=s.with("generation",s.generation+1)}
  // 0: eager copy, 1: delayed getter, 2: eager reference without copying.
  action retain(mode:int):bool=all {s.cuts.length()<2,
    s'=s.with("cuts",s.cuts.append({generation:s.generation,
      expected:s.inputs.get(s.generation),value:s.cells.get(s.generation),mode:mode,edited:false}))}
  pure def target(c:Cut,g:int):int=if(c.mode==1) g else c.generation
  pure def actual(c:Cut,g:int,cells:int -> int):int=
    if(c.mode==0) c.value else cells.get(target(c,g))
  action read=all {s.cuts.length()>0,s.reads.length()<4,
    nondet i=s.cuts.indices().oneOf()
    val c=s.cuts.nth(i)
    all {not(c.edited),s'=s.with("reads",s.reads.append({expected:c.expected,
      actual:actual(c,s.generation,s.cells)}))}}
  action edit=all {s.cuts.length()>0,
    nondet i=s.cuts.indices().oneOf()
    val c=s.cuts.nth(i)
    s'=s.with("cuts",s.cuts.replaceAt(i,c.with("value",7).with("edited",true)))
      .with("cells",if(c.mode==0) s.cells else s.cells.set(target(c,s.generation),7))}
  action observe=s'=s
  action step=any {retain(0),rebind,read,edit,observe}
  action delayedStep=any {retain(1),rebind,read,edit,observe}
  action aliasStep=any {retain(2),rebind,read,edit,observe}
  run unreadCutSurvivesRebindTest=init.then(retain(0)).then(rebind).then(read).expect(safe)
  run originalCutSurvivesABATest=init.then(retain(0)).then(rebind).then(rebind).then(read).expect(safe)
  run editedPrivateResultCannotPoisonOwnerTest=init.then(retain(0)).then(edit).then(retain(0)).then(read).expect(safe)
  run delayedGetterCounterexampleTest=init.then(retain(1)).then(rebind).then(read).expect(not(safe))
  run eagerAliasCounterexampleTest=init.then(retain(2)).then(edit).expect(not(safe))
}
