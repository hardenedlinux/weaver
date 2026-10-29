// One owner-resolved logical message, four scoped issuance keys, two workers.
// Policy/source admission and authenticated observation are boundary premises.
module LogicalMessageAuthority {
  type State = {
    reserved: bool, history: bool, issued: Set[int], consumes: int -> int,
    revision: int, candidate: int -> int, claims: int, claimed: bool, claimToken: int,
    claimStream: int, stream: int, authority: int, sends: int,
    observed: bool, retired: bool, finalCost: bool, charged: bool
  }
  var s: State
  pure val tokens = Set(0, 1, 2, 3)
  pure val workers = Set(0, 1)
  action init = s' = {
    reserved: false, history: false, issued: Set(), consumes: tokens.mapBy(_ => 0),
    revision: 0, candidate: workers.mapBy(_ => 0), claims: 0, claimed: false, claimToken: 0,
    claimStream: 0, stream: 0, authority: 0, sends: 0,
    observed: false, retired: false, finalCost: false, charged: false
  }
  action register = s' = s.with("reserved", true).with("history", true)
  // t = 2 * issuer incarnation + nonce. Reissuance does not reset the message.
  action issue(t) = all {
    s.reserved, t / 2 == s.authority,
    s' = s.with("issued", s.issued.union(Set(t)))
  }
  action capture(w) = s' = s.with("candidate", s.candidate.set(w, s.revision))
  action consume(w, t) = all {
    s.issued.contains(t), s.candidate.get(w) == s.revision, s.consumes.get(t) == 0,
    s' = s.with("consumes", s.consumes.set(t, s.consumes.get(t) + 1)).with("revision", s.revision + 1)
  }
  action claim(t) = all {
    s.reserved, s.consumes.get(t) == 1, not(s.claimed),
    s' = s.with("claims", s.claims + 1).with("claimed", true).with("claimToken", t).with("claimStream", s.stream)
  }
  action offer = all {
    s.claimed, s.claimStream == s.stream, s.sends == 0, not(s.retired),
    s' = s.with("sends", s.sends + 1)
  }
  action rotate = all { s.authority == 0, s' = s.with("authority", 1) }
  action reconnect = all { s.stream < 2, s' = s.with("stream", s.stream + 1) }
  action observe(t) = all {
    s.claimed, t == s.claimToken, s' = s.with("observed", true)
  }
  action retire(t) = all {
    s.claimed, t == s.claimToken, s' = s.with("retired", true)
  }
  action finalUsage(t) = all {
    s.claimed, t == s.claimToken, s' = s.with("finalCost", true)
  }
  action settle = all {
    s.reserved, s.observed, s.retired, s.finalCost,
    s' = s.with("charged", true)
  }
  action step = {
    nondet t = tokens.oneOf()
    nondet w = workers.oneOf()
    any { register, issue(t), capture(w), consume(w, t), claim(t), offer,
          rotate, reconnect, observe(t), retire(t), finalUsage(t), settle }
  }
  val nonceSafety = tokens.forall(t => s.consumes.get(t) <= 1)
  val messageSafety = s.sends <= (if (s.claimed) 1 else 0)
  val claimSafety = s.claims <= 1 and (s.claimed iff (s.claims == 1)) and
    (s.claimed implies s.reserved)
  val historySafety = s.reserved implies s.history
  val settlementSafety = s.charged implies
    (s.observed and s.retired and s.finalCost and s.reserved)
  val safety = nonceSafety and messageSafety and claimSafety and historySafety and settlementSafety

  // Deliberately invalid transitions. They are never included in step.
  // Root-only admission ignores stale revision and authoritative spent state.
  action rootOnlyConsume(t) = s' = s
    .with("consumes", s.consumes.set(t, s.consumes.get(t) + 1))
    .with("revision", s.revision + 1)
  // Keep the historical send count: otherwise resetting state hides the bug.
  action nonceResetsClaim(t) = s' = s.with("claims", s.claims + 1).with("claimed", true)
    .with("claimToken", t).with("claimStream", s.stream)
  action observationReopens = s' = s.with("observed", true).with("claimed", false)
  action outcomeSettlesEarly = s' = s.with("charged", true).with("observed", true)

  run normalLifecycleTest = init.then(register).then(issue(0)).then(capture(0))
    .then(consume(0, 0)).then(claim(0)).then(offer).then(observe(0))
    .expect(safety and not(s.charged))
    .then(retire(0)).then(finalUsage(0)).then(settle)
    .expect(safety and s.charged)
  run concurrencyTest = init.then(register).then(issue(0)).then(capture(0))
    .then(capture(1)).then(consume(0, 0))
    .expect(s.candidate.get(1) != s.revision and s.consumes.get(0) == 1 and safety)
  run rotationAndReconnectTest = init.then(register).then(issue(0)).then(consume(0, 0))
    .then(claim(0)).then(offer).then(rotate).then(issue(2)).then(capture(1))
    .then(consume(1, 2)).then(reconnect).then(observe(0))
    .expect(safety and s.claimToken == 0 and s.claimStream != s.stream and
      s.sends == 1 and s.reserved and not(s.charged))
  run rootOnlyCounterexampleTest = init.then(register).then(issue(0))
    .then(consume(0, 0)).then(rootOnlyConsume(0)).expect(s.consumes.get(0) == 2 and not(nonceSafety))
  run freshNonceCounterexampleTest = init.then(register).then(issue(0)).then(consume(0, 0))
    .then(claim(0)).then(offer).then(rotate).then(issue(2)).then(capture(1))
    .then(consume(1, 2)).then(nonceResetsClaim(2))
    .expect(not(claimSafety))
  run reconnectCounterexampleTest = init.then(register).then(issue(0)).then(consume(0, 0))
    .then(claim(0)).then(offer).then(reconnect).then(nonceResetsClaim(0))
    .expect(not(claimSafety))
  run lateObservationCounterexampleTest = init.then(register).then(issue(0)).then(consume(0, 0))
    .then(claim(0)).then(offer).then(observationReopens)
    .expect(not(messageSafety) and not(claimSafety))
  run prematureSettlementCounterexampleTest = init.then(register).then(issue(0)).then(consume(0, 0))
    .then(claim(0)).then(outcomeSettlesEarly).expect(not(settlementSafety))
}
