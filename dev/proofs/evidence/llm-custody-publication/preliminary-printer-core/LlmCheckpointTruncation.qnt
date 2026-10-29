module LlmCheckpointTruncation {
  type Key = { root: int, claim: int, profile: int, budget: int, history: int, reservation: int }
  type Balance = { available: int, held: int, charged: int }
  import LlmWalActivation as W from "./LlmWalActivation"
  type Transaction = { id: int, key: Key, bound: int, usage: int, resolution: int, source: int, meter: int }
  pure def prefixOf = ((xs, ys) => and(ilte(length(xs), length(ys)), forall(indices(xs), ((i) => eq(nth(xs, i), nth(ys, i))))))
  type Image = { revision: int, balance: Balance, applications: Set[Transaction], used: Set[int], holds: (int -> int) }
  type Checkpoint = { id: int, parent: int, position: int, basis: W::Receipt }
  pure val empty = Rec("id", 0, "parent", 0, "position", 0, "basis", W::zero)
  pure val cp1 = Rec("id", 1, "parent", 0, "position", 1, "basis", Rec("head", field(W::f0, "after"), "journal", List(W::f0), "epoch", 0, "sourceGeneration", 0))
  pure def tip = ((xs) => ite(eq(length(xs), 0), field(W::zero, "head"), field(nth(xs, isub(length(xs), 1)), "after")))
  pure val txOther = with(with(with(with(with(with(with(field(field(W::f0, "proposal"), "transaction"), "id", 101), "key", with(with(with(field(field(field(W::f0, "proposal"), "transaction"), "key"), "root", 20), "claim", 12), "reservation", 12)), "bound", 2), "usage", 1), "resolution", 2), "source", 2), "meter", 2)
  type Proposal = { transaction: Transaction, before: Image, worker: int, sourceGeneration: int }
  type PubReceipt = { checkpoint: Checkpoint, hasCheckpoint: bool, generation: int, epoch: int, sourceGeneration: int }
  pure val initial = Rec("published", List(), "blobs", Set(), "local", empty, "haveLocal", false, "suffix", List(W::f0), "observed", Rec("checkpoint", empty, "hasCheckpoint", false, "generation", 0, "epoch", 0, "sourceGeneration", 0), "haveObservation", true, "floorSeen", 0)
  def valid = ((cp) => and(and(eq(field(cp, "position"), length(field(field(cp, "basis"), "journal"))), eq(field(field(cp, "basis"), "head"), tip(field(field(cp, "basis"), "journal")))), prefixOf(field(field(cp, "basis"), "journal"), field(W::view, "journal"))))
  pure val pOther = Rec("transaction", txOther, "before", field(W::f0, "after"), "worker", 0, "sourceGeneration", 0)
  type Record = { proposal: Proposal, after: Image, epoch: int }
  pure val fOther = W::frame(pOther)
  type Storage = { published: List[Checkpoint], blobs: Set[Checkpoint], local: Checkpoint, haveLocal: bool, suffix: List[Record], observed: PubReceipt, haveObservation: bool, floorSeen: int }
  pure val cp2 = Rec("id", 2, "parent", 1, "position", 2, "basis", Rec("head", field(fOther, "after"), "journal", List(W::f0, fOther), "epoch", 0, "sourceGeneration", 0))
  var c: Storage
  action unsafeBypassPublicationGate = actionAll(W::activate(true), assign(c, c))
  action unsafePublish = ((cp) => actionAll(W::loseReply, assign(c, with(c, "published", append(field(c, "published"), cp)))))
  action unsafeActivate = actionAll(W::unsafeActivate, assign(c, c))
  action unsafeFloorRollback = actionAll(W::loseReply, assign(c, with(c, "published", List())))
  def latest = ite(eq(length(field(c, "published")), 0), empty, nth(field(c, "published"), isub(length(field(c, "published")), 1)))
  def expanded = concat(ite(field(c, "haveLocal"), field(field(field(c, "local"), "basis"), "journal"), List()), field(c, "suffix"))
  action init = actionAll(W::activated, assign(c, initial))
  action persist = ((cp, durable) => actionAll(valid(cp), durable, W::observe(true), assign(c, with(c, "blobs", union(field(c, "blobs"), Set(cp))))))
  action restore = ((cp, have, frames) => actionAll(W::restoreWal(concat(ite(have, field(field(cp, "basis"), "journal"), List()), frames)), assign(c, with(with(with(c, "local", cp), "haveLocal", have), "suffix", frames))))
  action observeFinancial = actionAll(W::observe(true), assign(c, c))
  action install = actionAll(W::install, assign(c, c))
  action rotate = actionAll(W::rotate, assign(c, c))
  action loseReply = actionAll(W::loseReply, assign(c, with(c, "haveObservation", false)))
  action loseBlob = ((cp) => actionAll(W::loseReply, assign(c, with(c, "blobs", exclude(field(c, "blobs"), Set(cp))))))
  action restoreAccount = ((image) => actionAll(W::restoreImage(image), assign(c, c)))
  action prepareOther = actionAll(W::prepareNext(pOther), assign(c, c))
  action flushOther = actionAll(W::flush(pOther, true), assign(c, with(c, "suffix", append(field(c, "suffix"), fOther))))
  action submitOther = actionAll(W::submit(pOther, true), assign(c, c))
  action commitOther = actionAll(W::anchor(pOther, true, true), assign(c, c))
  val publishedSafe = forall(indices(field(c, "published")), ((i) => and(and(valid(nth(field(c, "published"), i)), eq(field(nth(field(c, "published"), i), "parent"), i)), ite(eq(i, 0), igt(field(nth(field(c, "published"), i), "position"), 0), igt(field(nth(field(c, "published"), i), "position"), field(nth(field(c, "published"), isub(i, 1)), "position"))))))
  action retryOriginal = actionAll(W::anchor(field(W::f0, "proposal"), true, true), assign(c, c))
  def floor = field(latest, "position")
  def represented = eq(expanded, field(W::w, "records"))
  def floorSupported = ite(eq(length(field(c, "published")), 0), not(field(c, "haveLocal")), and(field(c, "haveLocal"), eq(field(c, "local"), latest)))
  def pubView = Rec("checkpoint", latest, "hasCheckpoint", igt(length(field(c, "published")), 0), "generation", length(field(c, "published")), "epoch", field(W::view, "epoch"), "sourceGeneration", field(W::view, "sourceGeneration"))
  action repair = ((cp, frames, authentic) => actionAll(authentic, eq(cp, latest), ite(igt(length(field(c, "published")), 0), contains(field(c, "blobs"), cp), true), eq(concat(ite(igt(length(field(c, "published")), 0), field(field(cp, "basis"), "journal"), List()), frames), field(W::view, "journal")), W::repair(true), assign(c, with(with(with(c, "local", cp), "haveLocal", igt(length(field(c, "published")), 0)), "suffix", frames))))
  action built = then(init, persist(cp1, true))
  action appendOther = then(then(then(prepareOther, flushOther), submitOther), commitOther)
  def publicationCurrent = and(field(c, "haveObservation"), eq(field(c, "observed"), pubView))
  action publish = ((cp, worker, durable, policy) => actionAll(contains(field(c, "blobs"), cp), valid(cp), eq(field(cp, "parent"), length(field(c, "published"))), forall(indices(field(c, "published")), ((i) => neq(field(nth(field(c, "published"), i), "id"), field(cp, "id")))), igt(field(cp, "position"), floor), eq(worker, field(W::view, "epoch")), eq(field(field(cp, "basis"), "epoch"), worker), eq(field(field(cp, "basis"), "sourceGeneration"), field(W::view, "sourceGeneration")), durable, policy, W::loseReply, assign(c, with(with(c, "published", append(field(c, "published"), cp)), "floorSeen", field(cp, "position")))))
  action observe = ((authentic) => actionAll(authentic, W::observe(authentic), assign(c, with(with(c, "observed", pubView), "haveObservation", true))))
  val floorMonotone = igte(floor, field(c, "floorSeen"))
  action trim = ((cp, frames, worker, durable) => actionAll(igt(length(field(c, "published")), 0), eq(cp, latest), publicationCurrent, eq(worker, field(W::view, "epoch")), contains(field(c, "blobs"), cp), durable, eq(concat(field(field(cp, "basis"), "journal"), frames), field(W::w, "records")), W::loseReply, assign(c, with(with(with(c, "local", cp), "haveLocal", true), "suffix", frames))))
  action activate = ((worker, authentic) => actionAll(represented, floorSupported, publicationCurrent, eq(worker, field(W::view, "epoch")), W::activate(authentic), assign(c, c)))
  action published = then(built, publish(cp1, 0, true, true))
  val live = implies(field(W::w, "active"), and(and(represented, floorSupported), publicationCurrent))
  action confirmed = then(published, observe(true))
  val safety = and(and(and(floorMonotone, W::safety), publishedSafe), live)
  action step = nondet cp = oneOf(Set(cp1, cp2)) { nondet frames = oneOf(Set(List(), List(W::f0), List(fOther), field(W::w, "records"))) { actionAny(persist(cp, true), publish(cp, field(W::view, "epoch"), true, true), observe(true), trim(cp, frames, field(W::view, "epoch"), true), restore(empty, false, frames), restore(cp, true, frames), repair(latest, frames, true), activate(field(W::view, "epoch"), true), observeFinancial, install, rotate, loseReply, loseBlob(cp)) } }
  action truncated = then(confirmed, trim(cp1, List(), 0, true))
  action recovered = then(then(then(truncated, observe(true)), observeFinancial), activate(0, true))
  action rolledBack = then(then(then(recovered, rotate), restore(empty, false, List())), restoreAccount(field(W::zero, "head")))
  action twoRecords = then(recovered, appendOther)
  action secondPublished = then(then(twoRecords, persist(cp2, true)), publish(cp2, 0, true, true))
}
