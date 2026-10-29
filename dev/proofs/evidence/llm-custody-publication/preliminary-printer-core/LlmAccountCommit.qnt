module LlmAccountCommit {
  type Key = { root: int, claim: int, profile: int, budget: int, history: int, reservation: int }
  type Balance = { available: int, held: int, charged: int }
  pure val key = Rec("root", 10, "claim", 11, "profile", 30, "budget", 5, "history", 9, "reservation", 11)
  import LlmExecutionReconciliation as R from "./LlmExecutionReconciliation"
  type Transaction = { id: int, key: Key, bound: int, usage: int, resolution: int, source: int, meter: int }
  pure val otherKey = with(with(with(key, "root", 20), "claim", 12), "reservation", 12)
  pure val tx0 = Rec("id", 100, "key", key, "bound", 3, "usage", 2, "resolution", 1, "source", 1, "meter", 1)
  pure val genesis = Rec("revision", 0, "balance", Rec("available", 5, "held", 5, "charged", 0), "applications", Set(), "used", Set(), "holds", mapBy(Set(11, 12), ((k) => ite(eq(k, 11), 3, 2))))
  pure def post = ((image, tx) => with(with(with(with(with(image, "revision", iadd(field(image, "revision"), 1)), "balance", Rec("available", isub(iadd(field(field(image, "balance"), "available"), field(tx, "bound")), field(tx, "usage")), "held", isub(field(field(image, "balance"), "held"), field(tx, "bound")), "charged", iadd(field(field(image, "balance"), "charged"), field(tx, "usage")))), "applications", union(field(image, "applications"), Set(tx))), "used", union(field(image, "used"), Set(field(field(tx, "key"), "reservation")))), "holds", set(field(image, "holds"), field(field(tx, "key"), "reservation"), 0)))
  type Image = { revision: int, balance: Balance, applications: Set[Transaction], used: Set[int], holds: (int -> int) }
  pure val tx1 = Rec("id", 101, "key", otherKey, "bound", 2, "usage", 1, "resolution", 2, "source", 2, "meter", 2)
  pure val txFull = with(tx0, "usage", 3)
  pure val p0 = Rec("transaction", tx0, "before", genesis, "worker", 0, "sourceGeneration", 0)
  pure val after0 = post(genesis, tx0)
  pure val initial = Rec("anchor", genesis, "local", genesis, "journal", List(), "epoch", 0, "qualified", true, "prepared", Set(), "observed", Set(), "everReleased", 0, "everCharged", 0, "otherEvidence", true, "sourceGeneration", 0)
  action hold = R::inert
  type Proposal = { transaction: Transaction, before: Image, worker: int, sourceGeneration: int }
  pure val p1 = Rec("transaction", tx1, "before", genesis, "worker", 0, "sourceGeneration", 0)
  type Record = { proposal: Proposal, after: Image, epoch: int }
  type Account = { anchor: Image, local: Image, journal: List[Record], epoch: int, qualified: bool, prepared: Set[Proposal], observed: Set[int], everReleased: int, everCharged: int, otherEvidence: bool, sourceGeneration: int }
  var a: Account
  def originalEvidence = ((tx) => ite(eq(field(tx, "key"), key), and(and(and(and(and(and(eq(field(R::e, "decisions"), List(R::executed)), eq(length(field(R::e, "source")), 1)), eq(field(R::e, "usage"), field(tx, "usage"))), eq(field(tx, "bound"), 3)), eq(field(tx, "resolution"), 1)), eq(field(tx, "source"), 1)), eq(field(tx, "meter"), 1)), and(eq(tx, tx1), field(a, "otherEvidence"))))
  action init = actionAll(R::usageApplied, assign(a, initial))
  action rotate = actionAll(hold, assign(a, with(with(a, "epoch", iadd(field(a, "epoch"), 1)), "qualified", false)))
  action restore = ((image) => actionAll(not(field(a, "qualified")), hold, assign(a, with(a, "local", image))))
  action recover = ((authentic) => actionAll(not(field(a, "qualified")), authentic, eq(field(a, "local"), field(a, "anchor")), hold, assign(a, with(a, "qualified", true))))
  action query = ((tx, authentic) => actionAll(authentic, contains(field(field(a, "anchor"), "applications"), tx), hold, assign(a, with(a, "observed", union(field(a, "observed"), Set(field(tx, "id")))))))
  action loseReply = actionAll(hold, assign(a, with(a, "observed", Set())))
  action lateFull = actionAll(R::lateFull, assign(a, a))
  action conflictUsage = actionAll(R::conflict, assign(a, with(a, "sourceGeneration", iadd(field(a, "sourceGeneration"), 1))))
  action fullyCharged = actionAll(then(then(R::sourceApplied, R::finalUsageReceipt(true)), R::usageCAS(R::executed, 3, 0, true)), assign(a, initial))
  val conservation = and(and(and(eq(iadd(iadd(field(field(field(a, "anchor"), "balance"), "available"), field(field(field(a, "anchor"), "balance"), "held")), field(field(field(a, "anchor"), "balance"), "charged")), 10), eq(field(field(field(a, "anchor"), "balance"), "available"), iadd(5, field(a, "everReleased")))), eq(field(field(field(a, "anchor"), "balance"), "charged"), field(a, "everCharged"))), igte(field(field(field(a, "anchor"), "balance"), "held"), 0))
  val joined = implies(field(a, "qualified"), eq(field(a, "local"), field(a, "anchor")))
  val unique = and(forall(field(field(a, "anchor"), "applications"), ((x) => forall(field(field(a, "anchor"), "applications"), ((y) => or(eq(x, y), and(neq(field(x, "id"), field(y, "id")), neq(field(field(x, "key"), "reservation"), field(field(y, "key"), "reservation")))))))), forall(indices(field(a, "journal")), ((i) => forall(indices(field(a, "journal")), ((j) => or(eq(i, j), neq(field(field(field(field(nth(field(a, "journal"), i), "proposal"), "transaction"), "key"), "reservation"), field(field(field(field(nth(field(a, "journal"), j), "proposal"), "transaction"), "key"), "reservation"))))))))
  val originalHolds = forall(Set(11, 12), ((k) => eq(get(field(field(a, "anchor"), "holds"), k), ite(contains(field(field(a, "anchor"), "used"), k), 0, ite(eq(k, 11), 3, 2)))))
  val paired = and(forall(field(field(a, "anchor"), "applications"), ((t) => contains(field(field(a, "anchor"), "used"), field(field(t, "key"), "reservation")))), forall(field(field(a, "anchor"), "used"), ((k) => exists(field(field(a, "anchor"), "applications"), ((t) => eq(field(field(t, "key"), "reservation"), k))))))
  action unsafeIdOnly = actionAll(hold, assign(a, with(a, "anchor", with(with(field(a, "anchor"), "applications", Set(tx0)), "used", Set(11)))))
  action unsafeDeltaOnly = actionAll(hold, assign(a, with(with(with(a, "anchor", with(with(after0, "applications", Set()), "used", Set())), "everReleased", 1), "everCharged", 2)))
  action unsafeApply = ((p) => actionAll(hold, assign(a, with(with(with(with(with(a, "anchor", post(field(a, "anchor"), field(p, "transaction"))), "journal", append(field(a, "journal"), Rec("proposal", p, "after", post(field(a, "anchor"), field(p, "transaction")), "epoch", field(a, "epoch")))), "qualified", false), "everReleased", isub(iadd(field(a, "everReleased"), field(field(p, "transaction"), "bound")), field(field(p, "transaction"), "usage"))), "everCharged", iadd(field(a, "everCharged"), field(field(p, "transaction"), "usage"))))))
  action unsafeRecover = actionAll(hold, assign(a, with(a, "qualified", true)))
  action unsafeRollback = actionAll(hold, assign(a, with(with(with(with(a, "anchor", genesis), "local", genesis), "journal", List()), "qualified", true)))
  action unsafeResetUsed = actionAll(hold, assign(a, with(a, "anchor", with(field(a, "anchor"), "used", Set()))))
  def gate = ((p) => and(and(and(and(and(and(and(and(and(and(and(and(and(not(field(R::e, "conflict")), field(R::e, "qualified")), eq(field(p, "sourceGeneration"), field(a, "sourceGeneration"))), field(a, "qualified")), eq(field(a, "local"), field(a, "anchor"))), eq(field(p, "worker"), field(a, "epoch"))), eq(field(p, "before"), field(a, "anchor"))), originalEvidence(field(p, "transaction"))), igte(field(field(p, "transaction"), "usage"), 0)), ilte(field(field(p, "transaction"), "usage"), field(field(p, "transaction"), "bound"))), igte(field(field(field(a, "anchor"), "balance"), "held"), field(field(p, "transaction"), "bound"))), eq(get(field(field(a, "anchor"), "holds"), field(field(field(p, "transaction"), "key"), "reservation")), field(field(p, "transaction"), "bound"))), forall(field(field(a, "anchor"), "applications"), ((t) => neq(field(t, "id"), field(field(p, "transaction"), "id"))))), not(contains(field(field(a, "anchor"), "used"), field(field(field(p, "transaction"), "key"), "reservation")))))
  val chain = and(and(eq(field(field(a, "anchor"), "revision"), length(field(a, "journal"))), forall(indices(field(a, "journal")), ((i) => val r = nth(field(a, "journal"), i) { and(and(eq(field(field(r, "proposal"), "worker"), field(r, "epoch")), eq(field(field(r, "proposal"), "before"), ite(eq(i, 0), genesis, field(nth(field(a, "journal"), isub(i, 1)), "after")))), eq(field(r, "after"), post(field(field(r, "proposal"), "before"), field(field(r, "proposal"), "transaction")))) }))), eq(field(a, "anchor"), ite(eq(length(field(a, "journal")), 0), genesis, field(nth(field(a, "journal"), isub(length(field(a, "journal")), 1)), "after"))))
  val evidence = forall(indices(field(a, "journal")), ((i) => originalEvidence(field(field(nth(field(a, "journal"), i), "proposal"), "transaction"))))
  action prepare = ((p) => actionAll(gate(p), hold, assign(a, with(a, "prepared", union(field(a, "prepared"), Set(p))))))
  action commit = ((p, policy, durable) => actionAll(contains(field(a, "prepared"), p), gate(p), policy, durable, hold, val image = post(field(a, "anchor"), field(p, "transaction")) { assign(a, with(with(with(with(with(a, "anchor", image), "journal", append(field(a, "journal"), Rec("proposal", p, "after", image, "epoch", field(a, "epoch")))), "qualified", false), "everReleased", isub(iadd(field(a, "everReleased"), field(field(p, "transaction"), "bound")), field(field(p, "transaction"), "usage"))), "everCharged", iadd(field(a, "everCharged"), field(field(p, "transaction"), "usage")))) }))
  val safety = and(and(and(and(and(and(and(originalHolds, evidence), R::safety), conservation), joined), unique), paired), chain)
  action prepared = then(init, prepare(p0))
  action step = nondet tx = oneOf(Set(tx0, tx1, txFull)) { nondet p = oneOf(union(field(a, "prepared"), Set(p0, p1, Rec("transaction", tx, "before", field(a, "anchor"), "worker", field(a, "epoch"), "sourceGeneration", field(a, "sourceGeneration"))))) { nondet image = oneOf(union(map(indices(field(a, "journal")), ((i) => field(nth(field(a, "journal"), i), "after"))), Set(genesis, field(a, "anchor")))) { actionAny(prepare(p), commit(p, true, true), rotate, restore(image), recover(true), query(tx, true), loseReply, lateFull, conflictUsage) } } }
  action committed = then(prepared, commit(p0, true, true))
  action twoPrepared = then(prepared, prepare(p1))
  action projected = then(then(committed, restore(after0)), recover(true))
  action restarted = then(committed, rotate)
}
