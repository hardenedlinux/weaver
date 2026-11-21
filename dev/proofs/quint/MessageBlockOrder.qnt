// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

// Compare contiguous arrival with the weaker unique-index design. The oracle
// describes final content-array positions, not the decoder's chosen guards.
module MessageBlockOrder {
  type S={open:bool,index:int,stopIndex:int,arrival:List[int],seen:Set[int],
    signature:int,released:int,closed:int,failed:bool,complete:bool,tools:int}
  var s:S
  val live=not(s.failed) and not(s.complete)
  val ordered=s.arrival.indices().forall(i=>s.arrival.nth(i)==i)
  val safe=ordered and s.released<=s.closed and
    (s.tools==0 or (s.complete and not(s.open) and not(s.failed)))
  action init=s'={open:false,index: -1,stopIndex: -1,arrival:List(),seen:Set(),
    signature:0,released:0,closed:0,failed:false,complete:false,tools:0}
  action startAt(index:int):bool=all {live,not(s.open),index>=0,index<2,not(s.seen.contains(index)),
    s'=s.with("open",true).with("index",index).with("stopIndex",index)
      .with("arrival",s.arrival.append(index)).with("seen",s.seen.union(Set(index))).with("signature",0)}
  action startBlock=startAt(s.closed)
  action uniqueStart=any {startAt(0),startAt(1)}
  action signatureFragment=all {live,s.open,s.signature<2,s'=s.with("signature",s.signature+1)}
  action wrongIndex=all {live,s.open,s'=s.with("stopIndex",9)}
  action closeBlock=all {live,s.open,
    if (s.stopIndex==s.index)
      s'=s.with("open",false).with("closed",s.closed+1)
        .with("released",s.released+(if (s.signature>0) 1 else 0))
    else s'=s.with("failed",true)}
  action terminal=all {live,not(s.open),s.closed>0,s'=s.with("complete",true).with("tools",1)}
  action observe=s'=s
  action step=any {startBlock,signatureFragment,wrongIndex,closeBlock,terminal,observe}
  action uniqueIndexStep=any {uniqueStart,signatureFragment,wrongIndex,closeBlock,terminal,observe}
  action earlySignature=all {live,s.open,s.signature>0,s'=s.with("released",s.released+1)}
  run signatureFragmentsRemainPrivateTest=init.then(startBlock).then(signatureFragment).expect(s.released==0 and safe)
  run matchingStopExposesCompleteSignatureTest=init.then(startBlock).then(signatureFragment)
    .then(signatureFragment).then(closeBlock).expect(s.released==1 and s.tools==0 and safe)
  run wrongStopClosesStreamTest=init.then(startBlock).then(wrongIndex).then(closeBlock)
    .expect(s.failed and s.released==0 and safe).then(signatureFragment.fail())
  run openBlockCannotCompleteTurnTest=init.then(startBlock).then(terminal.fail())
  run nextBlockPreservesOrderTest=init.then(startBlock).then(closeBlock).then(startBlock)
    .then(closeBlock).then(terminal).expect(s.closed==2 and s.tools==1 and safe)
  run uniqueIndicesAreInsufficientTest=init.then(startAt(1)).then(closeBlock)
    .then(startAt(0)).then(closeBlock).expect(s.seen==Set(0,1) and not(safe))
  run earlySignatureCounterexampleTest=init.then(startBlock).then(signatureFragment)
    .then(earlySignature).expect(not(safe))
}
