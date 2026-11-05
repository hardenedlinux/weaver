// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

// Progress is orthogonal to the complete semantic projection. The finite
// instance races two shared families; Lean generalizes finite progress steps.
module ProviderSemanticProgress {
  type State = { cut:int, meaning:int, owner:int, frameOwner:int, frameCut:int,
    frameMeaning:int, prepared:int, released:int, cursor:int, held:int,
    progress:Set[int], semantic:Set[int], used:Set[int], failed:bool,
    acknowledged:bool, expired:bool, sent:int, bad:bool }
  var s:State
  action init = s'={cut:0,meaning:0,owner:1,frameOwner:1,frameCut:0,
    frameMeaning:0,prepared:1,released:1,cursor:0,held:4,
    progress:Set(),semantic:Set(),used:Set(),failed:false,
    acknowledged:true,expired:false,sent:0,bad:false}
  action closeProgress(id:int):bool = all {not(s.failed),not(s.used.contains(id)),
    s'={...s,progress:s.progress.union(Set(id)),used:s.used.union(Set(id))}}
  action closeSemantic(id:int):bool = all {not(s.failed),not(s.used.contains(id)),
    s'={...s,semantic:s.semantic.union(Set(id)),used:s.used.union(Set(id))}}
  action prepare(id:int):bool = all {s.progress.contains(id),s.prepared<5,
    s'={...s,prepared:s.prepared+1,progress:s.progress.exclude(Set(id))}}
  action release(id:int):bool = all {s.progress.contains(id),s.released<s.prepared,
    s'={...s,released:s.released+1,progress:s.progress.exclude(Set(id))}}
  action commitSemantic(id:int):bool = all {s.semantic.contains(id),
    s'={...s,cut:s.cut+1,meaning:s.meaning+1,semantic:s.semantic.exclude(Set(id))}}
  action rollback(id:int):bool = all {s.progress.contains(id) or s.semantic.contains(id),
    s'={...s,progress:s.progress.exclude(Set(id)),semantic:s.semantic.exclude(Set(id))}}
  action unknown(id:int):bool = all {s.progress.contains(id) or s.semantic.contains(id),
    s'={...s,failed:true}}
  action accept = all {not(s.failed),not(s.expired),s.semantic.size()==0,
    s.acknowledged,s.frameOwner==s.owner,s.frameCut==s.cut,s.cursor==0,
    s'={...s,cursor:1,sent:s.sent+1,bad:s.bad or s.frameMeaning!=s.meaning}}
  action loseAcknowledgment = s'={...s,acknowledged:false}
  action expire = s'={...s,expired:true}
  action restart = s'={...s,owner:s.owner+1,cut:s.cut+1,failed:false,
    progress:Set(),semantic:Set()}
  // Deliberately unsafe mutant: misclassify a quota/history/OAuth/claim edit.
  action hiddenSemanticEdit = s'={...s,meaning:s.meaning+1}
  action step = {nondet id=Set(1,2,3,4).oneOf()
    any {closeProgress(id),closeSemantic(id),prepare(id),release(id),
      commitSemantic(id),rollback(id),unknown(id),accept,expire,restart,loseAcknowledgment}}
  val safe=not(s.bad) and s.held==4 and s.sent<=1 and s.released<=s.prepared
  run pendingProgressDoesNotReauthorizeOldFrameTest=init.then(closeProgress(1)).then(accept).expect(safe)
  run appendPreservesExistingFrameTest=init.then(closeProgress(1)).then(prepare(1)).then(accept).expect(safe)
  run anotherRangeReleasePreservesExistingFrameTest=init.then(closeProgress(1)).then(prepare(1))
    .then(closeProgress(2)).then(release(2)).then(accept).expect(safe)
  run semanticPendingStillBlocksTest=init.then(closeProgress(1)).then(closeSemantic(2)).then(accept.fail())
  run progressOutcomeCannotClearSemanticPendingTest=init.then(closeProgress(1)).then(closeSemantic(2))
    .then(prepare(1)).then(accept.fail())
  run semanticCommitInvalidatesOldFrameTest=init.then(closeSemantic(1)).then(commitSemantic(1)).then(accept.fail())
  run ambiguousProgressSealsOwnerTest=init.then(closeProgress(1)).then(unknown(1)).then(accept.fail())
  run lostAcknowledgmentCannotActivateFrameTest=init.then(loseAcknowledgment).then(closeProgress(1))
    .then(prepare(1)).then(accept.fail())
  run restartCannotAdoptOldFrameTest=init.then(restart).then(accept.fail())
  run expiryStillBlocksWithoutWriteTest=init.then(closeProgress(1)).then(expire).then(accept.fail())
  run oldCursorCannotReplayTest=init.then(accept).then(closeProgress(1)).then(prepare(1)).then(accept.fail())
  run hiddenSemanticEditIsCounterexampleTest=init.then(hiddenSemanticEdit).then(accept).expect(not(safe))
}
