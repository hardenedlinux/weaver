module ConnectionAdmission {
  type Connections = {live:Set[int],held:Set[int],handshakes:Set[int],peerClosed:Set[int],reserved:bool,closing:bool}
  var c:Connections
  val sockets = Set(0,1,2)
  val occupancy = c.held.size() + (if(c.reserved) 1 else 0)
  val safe = c.live==c.held and c.handshakes.subseteq(c.live) and occupancy<=2
  action init = c'={live:Set(),held:Set(),handshakes:Set(),peerClosed:Set(),reserved:false,closing:false}
  action reserve = all {not(c.closing),not(c.reserved),c.held.size()<2,c'=c.with("reserved",true)}
  action accept(w:int):bool = all {not(c.closing),c.reserved,not(c.live.contains(w)),
    c'=c.with("live",c.live.union(Set(w))).with("held",c.held.union(Set(w)))
      .with("handshakes",c.handshakes.union(Set(w))).with("peerClosed",c.peerClosed.exclude(Set(w))).with("reserved",false)}
  action tlsComplete(w:int):bool = all {c.handshakes.contains(w),c'=c.with("handshakes",c.handshakes.exclude(Set(w)))}
  action peerClose(w:int):bool = all {c.live.contains(w),c'=c.with("peerClosed",c.peerClosed.union(Set(w)))}
  action destroy(w:int):bool = all {c.live.contains(w),
    c'=c.with("live",c.live.exclude(Set(w))).with("held",c.held.exclude(Set(w)))
      .with("handshakes",c.handshakes.exclude(Set(w))).with("peerClosed",c.peerClosed.exclude(Set(w)))}
  action closeListener = c'=c.with("closing",true).with("reserved",false)
  action idle = c'=c
  action unsafeEarlyReturn(w:int):bool = all {c.live.contains(w),c'=c.with("held",c.held.exclude(Set(w)))}
  action unsafeAccept(w:int):bool = all {not(c.live.contains(w)),
    c'=c.with("live",c.live.union(Set(w))).with("held",c.held.union(Set(w))).with("handshakes",c.handshakes.union(Set(w)))}
  action step = {nondet w=sockets.oneOf() any {reserve,accept(w),tlsComplete(w),peerClose(w),destroy(w),closeListener,idle}}
  action full = init.then(reserve).then(accept(0)).then(reserve).then(accept(1))
  run capIncludesIncompleteTlsTest = full.then(reserve.fail())
  run completedTlsStillHoldsCapacityTest = full.then(tlsComplete(0)).then(reserve.fail())
  run peerLossKeepsCustodyTest = full.then(peerClose(0)).expect(safe and c.held.size()==2)
  run handshakeTimeoutDestroysSocketTest = full.then(destroy(0)).then(reserve).then(accept(2)).expect(safe)
  run listenerDropKeepsLiveCustodyTest = full.then(closeListener).expect(safe and c.held.size()==2)
  run shutdownRejectsNewAcceptTest = init.then(reserve).then(closeListener).then(accept(0).fail())
  run idleReservationIsReturnedTest = init.then(reserve).then(closeListener).expect(safe and occupancy==0)
  run earlyReturnCounterexampleTest = full.then(tlsComplete(0)).then(unsafeEarlyReturn(0)).expect(not(safe))
  run acceptBeforeBudgetCounterexampleTest = full.then(unsafeAccept(2)).expect(not(safe))
}
