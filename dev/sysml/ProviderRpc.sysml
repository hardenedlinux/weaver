// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package ProviderRpc {
    private import ScalarValues::*;
    requirement def GrpcCallerBinding {
        doc /* Mutual TLS, pinned caller certificate and distinct operation/publication credentials bind all RPC entrypoints. A shared workload name does not grant authority. */
    }
    requirement def SenderBoundProviderOAuth {
        doc /* A configured resource requires the authenticated operation bearer,
           actual TLS sender and independently issued delegated grant. Current
           source custody alone can publish signed evidence or revoke a digest.
           The deciding Turso scope joins active grant status with Cedar and the
           original claim before dispatch or response release. Revocation retains
           unknown holds, and credential renewal cannot reopen consumption.
       Go projects its actual verified ingress certificate. Rust authenticates
       the relay TLS sender and prepares the signed grant lineage before the
       shared-domain lock. Each deciding scope matches the exact deployment,
       root and leaf records, reads both tombstones, checks current time and
       compares the projected witness length with the retained journal. An
       independent witness retains root revocation and issuer epochs across
       store recovery. */
    }
    requirement def TransportSetupIsolation {
        doc /* Connection setup retains caller cancellation and deadlines. Transport reconnects do not issue application RPCs, reauthorize release, reset spent roots or refund unknown holds. Initial connection backoff is distinct from SDK operation retry. Readiness observation uses the caller's existing remaining budget; it never extends that deadline or changes the native reconnect policy after Ready. Native capacity and fresh Cedar guards still decide every effect. */
        doc /* A new HTTP/2 connection, MCP session, A2A task or client ACP handle
           cannot adopt the original stream's cancelled output context, pending
           range or live release token. Recover exact original observations;
           reconnecting a configuration watch is not replaying an effect. */
    }
    requirement def CommittedProviderRouting {
        doc /* Go proposes an exact original task, body and ordered route commitment. Rust selects one permitted configured route before durable consumption. */
    }
    requirement def UnambiguousProviderRequestBounds {
        doc /* Go rejects unsupported request shapes; Rust independently admits exactly one original token cap in the range 1 through 4096 before reservation or dispatch. Source commitments cannot qualify competing caps. Neither cap nor usage observations authorize monetary settlement. */
    }
    requirement def SourceProviderProfileBinding {
        doc /* Rust retains only immutable Cedar literals and parsed subject/
           target identities in BoundProviderPolicy. Each effect constructs a
           fresh official Cedar Context from its actual sequence, format and
           authoritative shared-domain view. No JSON clone/parser is needed for
           this scalar provider context. Checked u64-to-long conversion retains
           rejection above Cedar signed range; missing domains remain missing.
           Current Policy text, owner fence and domain checks are still read
           under the deciding transaction and evaluated on every use.
           Within one deciding transaction, Rust checks complete shared exposure
           once and reads the common Policy/profile/domain image once for a
           bounded batch. Every actual row sequence still receives Cedar
           evaluation before any queue callback. No read image crosses a write,
           capacity wait, transaction boundary, publication cut or owner restart.
           The prepare burn and final release remain distinct durable scopes.
           Go config/publication/Routing and Rust final sends can be qualified
           without Scheme preparation; this does not qualify a new Scheme
           dependency or alter its source-currentness contract. */
        doc /* Authenticated source registration atomically binds an immutable profile artifact and original task. Plans commit the exact profile digest. Fresh Cedar evaluates protocol, profile digest and validated request facts before final sends. */
    }
    requirement def ClosedProviderRequestSchema {
        doc /* Only implemented text/SSE request, message, sampling and response fields are admitted. A source body commitment or Cedar permit cannot reinterpret unknown extensions, tool messages or another response mode as supported semantics. Typed provider tasks cannot fall back to untyped request or raw-stream execution. */
    }
    requirement def RecoverableProfileFloor {
        doc /* Original task artifacts retain the semantic floor after registry projection loss. Indexed floor checks prevent identity rebinding; final dispatch and release recheck registry data. Recovery never reissues spent attempts or refunds unknown holds. */
    }
    requirement def CanonicalProfileConfiguration {
        doc /* Bounded JSON and YAML configuration produce one canonical typed profile commitment. Duplicate fields, aliases, custom tags, multiple documents and unregistered semantics are rejected. Configuration parsing never evaluates Scheme or grants execution authority. */
    }
    requirement def AffineProviderAttempt {
        doc /* Durable consume and dispatch burn precede the only possible provider request. RPC retry, redirect, fallback, restart and cancellation never reopen a consumed root. */
    }
    requirement def TransportAndExecutionLatencySeparation {
        doc /* Go forwards authenticated Protobuf request envelopes over
           gRPC. The streaming response carries either a Protobuf event
           or an Arrow IPC batch inside each Protobuf frame. The Go relay
           forwards frames unchanged. The Go client decodes Arrow only
           when consuming a batch. Rust's SSE decoder belongs to the
           separate provider HTTPS hop. */
        doc /* Measure warm gRPC transport and encoding per frame and per
           row. Compare equal row counts and equal batch shapes to isolate
           codec cost. Compare different batch sizes separately to measure
           fewer frames and deciding scopes. Track queue, native commit,
           upstream wait and terminal wall time as execution intervals. */
    }
    requirement def ProviderSchedulerOwnership {
        doc /* Go owns verified ingress, local admission limits, relay
           backpressure and cancellation propagation. Rust owns provider
           worker admission, authoritative domain contention, resource
           lifetime and every deciding scope. Go has no authority to
           order requests by a cached domain root or revive a durable burn. */
        doc /* Current Rust execution registers exact origin, budget and history
           roots as one ticket. A scheduling grant is transient and
           each subsequent effect rejoins live authority. Queue waiting
           must be distinct from the scope holding budget and publication
           exclusion. Conflicting tickets follow registration order.
           Cancellation and queue measurements remain separate. Waiting tickets
           identify candidate lock sets and own no execution authority. A
           grant must rejoin the owner generation and live roots before
           any mutation or callback. Cancelled or stale tickets are discarded.
           Disjoint tickets may advance independently. Overlapping tickets
           need an explicit order and maximum wait policy. */
        doc /* In WAL, queued provider admission and exact lifecycle work
           close the delivery barrier after acquiring the native writer
           and before any business read, mutation or callback. Accepted
           source, Policy and OAuth mutations close before waiting.
           The existing Tokio reactor polls upstream and delivery readiness.
           Keep the same decoder future across handoff wakeups. The blocking
           owner services ledger work outside reactor polling, without
           draining the output queue or extending either deadline. */
    }
    requirement def EncodingAuthorityEquivalence {
        doc /* Protobuf events and optional Arrow IPC batches use the same row-by-row current Cedar and fence guard before bounded queue admission. */
        doc /* Fix encoding for each live RPC: one Protobuf event or at most 32
           Arrow rows. Validate every row, schema, ordering, null/trailing content
           and actual original-stream binding. An admitted batch is immutable;
           changing encoding, schema, destination or context requires rejection,
           not relabeling. Go checks bounded IPC envelopes before reader allocation,
           applies a per-batch cumulative Arrow-buffer request budget without
           restoring credit on Free, bounds owned returned text and rejects
           sequence overflow. This is not a bound on codec/runtime heap or a
           verifier for arbitrary FlatBuffer graphs. Encoded-byte bounds alone
           are insufficient; batching never increases semantic or monetary budget. */
    }
    requirement def ProviderUnknownRetention {
        doc /* Invocation callbacks return Result. Failure exits before recording
           callback success or entering the final commit window. The private
           production SealedRequest is required for that window; a failed write
           cannot satisfy a seal/crash test by merely returning an error. Native
           commit acknowledgment loss poisons old custody; recovered records
           preserve the original burn and hold without restoring IO capability. */
        doc /* At consumption and each final use, Rust joins the original stream
           claim and exact plan reservation, and requires the shared held amount
           to cover every retained provider reservation in that family. A missing
           or contradictory recovery projection denies use; it never recreates
           the claim, repairs the hold from a caller value or authorizes refund.
           This concretizes SPEC ZeroTrust consumptionCommitted/unknownRetained;
           external identity and rollback-resistant recovery remain separate duties. */
        doc /* Partial request or SSE delivery, lost response and interrupted completion retain the original reservation and canonical identity. Provider usage is observational, not settlement authority. */
        doc /* Queue insertion may occur before its ledger transaction commits.
           A frame can be observed despite a lost/failed release commit; preserve
           the unknown range and original hold. Frame drain, discard, decoder
           success, HTTP/2 ACK and DONE do not prove final account/history outcome.
           Go observations may propose a next step, never execute it directly. */
    }
    requirement def WorkspaceBenchmarkCoverage {
        doc /* Each Rust workspace member declares an executable benchmark target. Dependency versions are inherited from the workspace, and benchmarks remain distinct from safety and deployment qualification. */
    }
    requirement def ReservedAuthorityAdmission {
        doc /* Execution, source publication and canonical observation retain independent bounded native capacity. Authentication precedes lane selection. Caller disconnect does not release a tracked worker's slot. Publication is effective only after its deciding CAS commits. */
        doc /* Reserve output queue capacity outside the deciding lock. Capacity
           credit is not Policy or budget authority: recheck full deciding cut,
           every row and observed cancellation after waiting, inside final queue
           admission. Keep bounded native capacity until the actual worker ends.
           Two private frames do not bound HTTP/2, network or Go application
           buffers; those domains require their own limits and verification. */
        doc /* The local release transaction holds the deciding Turso write
           order through the callback. Original burn and unknown range must
           already be committed; the later release-completion marker is not
           the prerequisite. This does not serialize independent fact stores
           or establish a rollback-resistant global floor. */
    }
    requirement def ConnectionCustodyBound {
        doc /* Every accepted TCP connection owns capacity before TLS and retains it through actual socket destruction. TLS completion and peer loss cannot return capacity early. Stalled handshakes have a fixed deadline; shutdown drops listener reservations and drains owned resources. */
    }
    requirement def SourceIngressBinding {
        doc /* Source publication has a distinct gRPC listener, independent bounded connection capacity, a distinct pinned leaf and credential, and only source methods. Saturated operation connections cannot consume source connection slots. Both listeners close and drain under one runtime owner. */
    }
    requirement def DurablePublicationDecision {
        doc /* Stable publication identity binds exact Policy, schema, original parent and requested fence. One deciding transaction commits authority/schema and a retained committed or rejected outcome. Exact retry observes history; changed identity binding is rejected. NotFound is not abort, and publication never sends or releases held budget. */
    }
    requirement def OwnedSourceConnection {
        doc /* A tracked blocking worker exclusively owns one reusable source connection. Command capacity stays held through SQL completion despite caller loss, then returns before the command acknowledgment is observable. Quiescent boundaries and fresh CAS reads prevent stale snapshot reuse. Storage or close failure terminates the owner and cannot produce successful drain acknowledgment. */
        doc /* Catalogue inspection and published task registration can wait
           in three bounded slots. One separate priority reservation has
           precedence for publication, source rotation and hard-fact work.
           Waiting expires after 50 ms. Cancellation before grant creates
           no command. The owner authenticates each command when it executes.
           The fact preparation acknowledgment returns command capacity
           before Scheme derivation. Its result needs a separate deciding
           source command with current authority and durable barrier checks. */
    }
    requirement def FinalInvocationCancellation {
        doc /* A pre-lock cancellation read is not final send admission. After durable dispatch burn and the final deciding lock/current Cedar guard, Rust rechecks the original output context immediately before transport entry. Unknown execution retains its hold; new contexts cannot reuse the burned invocation. Already admitted transport is not retroactively unsent. */
    }
    requirement def OriginalReleaseCapability {
        doc /* Each affine response-release token binds the immutable original plan commitment, prepared encoding and live ledger session, independently of its response batch digest. Equal payloads cannot transfer release between plans or reinterpret encoding. Reject, restart and stale-owner recovery preserve unknown releases and shared holds. */
        doc /* Final use additionally joins the authenticated current profile,
           shared budget/history and owner context supplied by the existing floor
           owner. A queued request cannot silently adopt a repaired projection.
           Persisting only Arrow bytes/sequence is not recoverable authorization. */
    }
    item def OriginalPlan;
    item def StreamEvent;
    item def EncodedFrame {
        doc /* Logical evidence envelope, not newly implemented wire fields.
           Live authenticated RPC/request context binds the original operation,
           negotiated encoding, fixed schema and ordered sequence range. A cached
           frame detached from that context cannot authorize a new stream/effect.
           Already admitted data can drain after later revocation; that is not a
           fresh release. Exact peer/application delivery is not a queue receipt. */
    }
    item def AuthorityPublication;
    port def PlanPort { out item proposal : OriginalPlan; }
    port def EventPort { out item delta : StreamEvent; }
    port def FramePort { out item encoded : EncodedFrame; }
    port def PublicationPort { out item authority : AuthorityPublication; }
    part def SourcePublisher { port authority : PublicationPort; }
    part def RustSourceIngress { port authority : ~PublicationPort; port published : PublicationPort; }
    part def RustSourceWorker { port command : ~PublicationPort; port decided : PublicationPort; }
    part def GoRoutingControl {
        doc /* RPC view of the existing Go cloud/protocol integration owner.
           Kubernetes watches, SDK health and discovered routes are typed source
           candidates. Go validates/consumes response data under the original
           stream context, applies bounded backpressure and propagates cancellation.
           Compiled route slices, outbound Task maps/slices and the stream
           observer's plan are private typed copies. Copy before invoking RPC or
           receive callbacks; no request/caller alias may rewrite the retained
           route order or completion digest. Input must be stable during copying.
           A receive callback must not directly invoke tools, refund money or
           advance Scheme Session without authoritative terminal/history evidence
           and fresh Rust admission of the next proposal. */
        port proposal : PlanPort;
        port received : ~FramePort;
    }
    part def RustGrpcOwner { port proposal : ~PlanPort; port forwarded : PlanPort; }
    /* Request construction is inert. The fresh deciding scope owns connect,
       TLS and exactly one fixed-length HTTP request. WriteSeal observes accepted
       plaintext plus successful TLS flush, then permanently rejects every new
       application write. The affine owned driver is never spawned or cloned.
       The callback returns a typed Result of the private sealed IO owner. An
       error rolls back the final scope before its commit window; the original
       burn and unknown hold remain. A successful callback enters the deciding
       transaction's completion record in the original burn,
       without certifying remote execution or known usage. Only after its native
       commit is observed may it read headers/body outside
       the guard. Early headers and body EOF cannot forge that seal. A failed
       write, flush or commit drops the driver and retains original unknown
       exposure. Applied commit with lost acknowledgment poisons the old session;
       restart retains the burn but cannot restore the affine socket. A late
       acknowledgment after new authority commits grants reading only, never
       release. Current Cedar/profile/shared-domain/fence guards still decide
       each response release. The service supplies the reactor explicitly. */
    part def RustProviderBroker { port proposal : ~PlanPort; port response : EventPort; port authority : ~PublicationPort; }
    part def RustCedarRelease { port prepared : ~FramePort; port authorized : FramePort; }
    part def ProtobufOrArrowEncoder {
        doc /* Pure bounded owned encoding runs after the durable interval burn
           and outside the final writer/domain guard. Sequence, route, model and
           encoding are frozen. A new final join checks current authority for
           every row before the sole queue insertion. No encoded frame or scalar
           sequence observation is an execution capability. */
        port response : ~EventPort;
        port frames : FramePort;
    }
    part def RustBoundedOutput {
        doc /* Existing private gRPC output queue, not another transport process.
           Reserve capacity before release preparation; the same deciding guard
           spans fresh final row checks and queue insertion of immutable prepared
           bytes. Encoding allocates outside this scope. Queue admission
           is the response-release LP; provider-request socket admission remains
           the distinct LP in WeaverExecution. Observe cancellation immediately
           before enqueue, then retain uncertainty if receiver loss/commit failure
           races that insertion. Transport buffers may drain accepted data. */
        port frames : ~FramePort;
        port stream : FramePort;
    }
    part providerPath {
        part control : GoRoutingControl;
        part source : SourcePublisher;
        part publication : RustSourceIngress;
        part sourceStore : RustSourceWorker;
        part rpc : RustGrpcOwner;
        part broker : RustProviderBroker;
        part guard : RustCedarRelease;
        part encoding : ProtobufOrArrowEncoder;
        part output : RustBoundedOutput;
        connect control.proposal to rpc.proposal;
        connect source.authority to publication.authority;
        connect publication.published to sourceStore.command;
        connect sourceStore.decided to broker.authority;
        connect rpc.forwarded to broker.proposal;
        connect broker.response to encoding.response;
        connect encoding.frames to guard.prepared;
        connect guard.authorized to output.frames;
        connect output.stream to control.received;
        attribute maximumRoutes : Integer = 8;
        attribute maximumRequestBytes : Integer = 1048576;
        attribute maximumSseEventBytes : Integer = 65536;
        attribute maximumResponseBytes : Integer = 4194304;
        attribute maximumResponseEvents : Integer = 4096;
        attribute maximumArrowRows : Integer = 32;
        attribute privateQueueFrames : Integer = 2;
        assert constraint { maximumRoutes <= 8 and maximumArrowRows <= 32 and privateQueueFrames <= 2 }
    }
}
