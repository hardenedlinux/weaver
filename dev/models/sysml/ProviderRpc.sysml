package ProviderRpc {
    private import ScalarValues::*;
    requirement def GrpcCallerBinding {
        doc /* Mutual TLS, pinned caller certificate and distinct operation/publication credentials bind all RPC entrypoints. A shared workload name does not grant authority. */
    }
    requirement def CommittedProviderRouting {
        doc /* Go proposes an exact original task, body and ordered route commitment. Rust selects one permitted configured route before durable consumption. */
    }
    requirement def UnambiguousProviderRequestBounds {
        doc /* Go rejects unsupported request shapes; Rust independently admits exactly one original token cap in the range 1 through 4096 before reservation or dispatch. Source commitments cannot qualify competing caps. Neither cap nor usage observations authorize monetary settlement. */
    }
    requirement def SourceProviderProfileBinding {
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
    requirement def EncodingAuthorityEquivalence {
        doc /* Protobuf events and optional Arrow IPC batches use the same row-by-row current Cedar and fence guard before bounded queue admission. */
    }
    requirement def ProviderUnknownRetention {
        doc /* Partial request or SSE delivery, lost response and interrupted completion retain the original reservation and canonical identity. Provider usage is observational, not settlement authority. */
    }
    requirement def NativeBenchmarkCoverage {
        doc /* Each Rust workspace member declares an executable benchmark target. Dependency versions are inherited from the workspace, and benchmarks remain distinct from safety and deployment qualification. */
    }
    requirement def ReservedAuthorityAdmission {
        doc /* Execution, source publication and canonical observation retain independent bounded native capacity. Authentication precedes lane selection. Caller disconnect does not release a tracked worker's slot. Publication is effective only after its deciding CAS commits. */
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
    }
    requirement def FinalInvocationCancellation {
        doc /* A pre-lock cancellation read is not final send admission. After durable dispatch burn and the final deciding lock/current Cedar guard, Rust rechecks the original output context immediately before transport entry. Unknown execution retains its hold; new contexts cannot reuse the burned invocation. Already admitted transport is not retroactively unsent. */
    }
    requirement def OriginalReleaseCapability {
        doc /* Each affine response-release token binds the immutable original plan commitment, prepared encoding and live ledger session, independently of its response batch digest. Equal payloads cannot transfer release between plans or reinterpret encoding. Reject, restart and stale-owner recovery preserve unknown releases and shared holds. */
    }
    item def OriginalPlan;
    item def StreamEvent;
    item def EncodedFrame;
    item def AuthorityPublication;
    port def PlanPort { out item proposal : OriginalPlan; }
    port def EventPort { out item delta : StreamEvent; }
    port def FramePort { out item encoded : EncodedFrame; }
    port def PublicationPort { out item authority : AuthorityPublication; }
    part def SourcePublisher { port authority : PublicationPort; }
    part def RustSourceIngress { port authority : ~PublicationPort; port published : PublicationPort; }
    part def RustSourceWorker { port command : ~PublicationPort; port decided : PublicationPort; }
    part def GoRoutingControl { port proposal : PlanPort; }
    part def RustGrpcOwner { port proposal : ~PlanPort; port forwarded : PlanPort; }
    part def RustProviderBroker { port proposal : ~PlanPort; port response : EventPort; port authority : ~PublicationPort; }
    part def RustCedarRelease { port response : ~EventPort; port encoded : FramePort; }
    part def ProtobufOrArrowEncoder { port encoded : ~FramePort; }
    part providerPath {
        part control : GoRoutingControl;
        part source : SourcePublisher;
        part publication : RustSourceIngress;
        part sourceStore : RustSourceWorker;
        part rpc : RustGrpcOwner;
        part broker : RustProviderBroker;
        part guard : RustCedarRelease;
        part encoding : ProtobufOrArrowEncoder;
        connect control.proposal to rpc.proposal;
        connect source.authority to publication.authority;
        connect publication.published to sourceStore.command;
        connect sourceStore.decided to broker.authority;
        connect rpc.forwarded to broker.proposal;
        connect broker.response to guard.response;
        connect guard.encoded to encoding.encoded;
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
