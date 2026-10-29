package StreamingExecution {
    doc /* Finite logical messages, durable range consumption and private synchronous transport custody. */
    private import ScalarValues::*;
    requirement def MessageScopedAuthority {
        doc /* Original input, manifest, message, destination, payload and cost are bound before reservation. */
    }
    requirement def RangeFinalGuard {
        doc /* Every possible write joins current Policy/history, original claim, reservation and custody under the deciding lock. */
    }
    requirement def UnknownPrefixRecovery {
        doc /* Unknown or partial ranges retain budget and prevent reconnect; only retired zero-call opportunities may reauthorize the original unsent message. */
    }
    requirement def PrivateBufferCustody {
        doc /* The Rust owner keeps the FD and TLS buffers private; complete flush or shutdown happens within the guarded write. */
    }
    requirement def BoundedPerformanceWork {
        doc /* Hash payload once, copy bounded immutable BLOB slices, allocate range sequence in constant work, cache compilation rather than grants. */
    }
    requirement def TrackedWriterDrain {
        doc /* Closing admission cancels incomplete request-body waits and rejects new native jobs. Detached HTTP callers retain tracked writers and admission slots until native completion. Drain acknowledges only an empty tracker; unknown holds survive shutdown. */
    }
    item def MessageProposal;
    item def PayloadCommitment;
    item def RangePermit;
    item def NativeRangeBytes;
    item def TransportObservation;
    port def MessagePort { out item proposal : MessageProposal; }
    port def PermitPort { out item permit : RangePermit; }
    port def BytesPort { out item bytes : NativeRangeBytes; }
    port def ObservationPort { out item observation : TransportObservation; }
    part def GoMessageAdapter { port proposals : MessagePort; }
    part def RustServerRuntime {
        doc /* Authenticated proposal admission, process-signal cancellation, private native task tracking and explicit drain acknowledgment. */
    }
    part def RustMessageLedger {
        port proposals : ~MessagePort;
        port consumed : PermitPort;
        port observations : ~ObservationPort;
    }
    part def RustFinalGuard { port consumed : ~PermitPort; port bytes : BytesPort; }
    part def RustOwnedTransport { port bytes : ~BytesPort; port observations : ObservationPort; }
    part streamingPath {
        part adapter : GoMessageAdapter;
        part server : RustServerRuntime;
        part ledger : RustMessageLedger;
        part guard : RustFinalGuard;
        part transport : RustOwnedTransport;
        connect adapter.proposals to ledger.proposals;
        connect ledger.consumed to guard.consumed;
        connect guard.bytes to transport.bytes;
        connect transport.observations to ledger.observations;
        attribute maximumMessages : Integer = 64;
        attribute maximumMessageBytes : Integer = 1048576;
        attribute maximumPolicyBytes : Integer = 65536;
        attribute compiledPolicySlots : Integer = 8;
        assert constraint { maximumMessages <= 64 and maximumMessageBytes <= 1048576 and compiledPolicySlots <= 8 }
    }
}
