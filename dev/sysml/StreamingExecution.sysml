// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

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
    requirement def DurableRangeProgressJoin {
        doc /* Before custody, connect, resume, consume or final write, join each
           relevant message projection to the durable range tail under the same
           deciding transaction. State, cursor and next sequence must match
           complete, not-sent, partial or unknown observations. A stale queued
           projection cannot hide a spent range or release its original hold.
           Use one indexed tail lookup per selected message, not a range-history
           scan; custody/connect also validate the bounded sibling manifest.
           Coherent rollback of both tables still requires an independent anchor. */
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
    item def ExecutorRangeBytes;
    item def TransportObservation;
    item def HeldExposure;
    port def MessagePort { out item proposal : MessageProposal; }
    port def PermitPort { out item permit : RangePermit; }
    port def BytesPort { out item bytes : ExecutorRangeBytes; }
    port def ObservationPort { out item observation : TransportObservation; }
    port def HoldPort { out item held : HeldExposure; }
    part def GoMessageAdapter {
        attribute streamName : String = "Bound message";
        attribute streamSummary : String = "Task + payload";
        attribute displayName : String = "Go / Bound message";
        attribute responsibility : String = "Original task and manifest\nMessage, payload and cost\nNo direct provider writer";
        attribute glyph : String = "message";
        port proposals : MessagePort;
    }
    part def RustServerRuntime {
        attribute streamName : String = "Admit proposal";
        attribute streamSummary : String = "Authenticate caller";
        attribute displayName : String = "Rust / Gateway admission";
        attribute responsibility : String = "Authenticate the gRPC caller\nBound work and track writers\nForward proposals, not grants";
        attribute glyph : String = "authentication";
        port proposals : ~MessagePort;
        port checked : MessagePort;
        doc /* Authenticated proposal admission, process-signal cancellation, private native task tracking and explicit drain acknowledgment. */
    }
    part def RustMessageLedger {
        attribute streamName : String = "Consume range";
        attribute streamSummary : String = "Keep claim + hold";
        attribute displayName : String = "Rust / Durable progress join";
        attribute responsibility : String = "Compare message to range tail\nKeep original claim and hold\nBurn before any write opportunity";
        attribute glyph : String = "ledger";
        port proposals : ~MessagePort;
        port consumed : PermitPort;
        port observations : ~ObservationPort;
        port held : HoldPort;
    }
    part def RustFinalGuard {
        attribute streamName : String = "Current-use gate";
        attribute streamSummary : String = "Policy + owner";
        attribute displayName : String = "Rust / Final-use gate";
        attribute responsibility : String = "Exact permit and spent range\nCurrent Policy, owner and fence\nSerialize the bounded write";
        attribute glyph : String = "authorization";
        port consumed : ~PermitPort;
        port bytes : BytesPort;
    }
    part def RustOwnedTransport {
        attribute streamName : String = "Write bytes";
        attribute streamSummary : String = "Record observation";
        attribute displayName : String = "Rust / Private writer";
        attribute responsibility : String = "Exact authorized byte slice\nRetire on partial or unknown\nLocal completion is not settlement";
        attribute glyph : String = "writer";
        port bytes : ~BytesPort;
        port observations : ObservationPort;
    }
    part def RetainedStreamExposure {
        attribute streamName : String = "Unknown exposure";
        attribute streamSummary : String = "Hold + stop";
        attribute displayName : String = "Original exposure stays held";
        attribute responsibility : String = "Mismatch blocks new opportunities\nUnknown cannot reopen the prefix\nNo automatic budget refund";
        attribute glyph : String = "unknown";
        doc /* Logical ledger outcome, not a separate service or new account. */
        port held : ~HoldPort;
    }
    part streamingPath {
        part adapter : GoMessageAdapter;
        part server : RustServerRuntime;
        part ledger : RustMessageLedger;
        part guard : RustFinalGuard;
        part transport : RustOwnedTransport;
        part retained : RetainedStreamExposure;
        connection propose connect adapter.proposals to server.proposals;
        connection admit connect server.checked to ledger.proposals;
        connection consume connect ledger.consumed to guard.consumed;
        connection writeRange connect guard.bytes to transport.bytes;
        connection observe connect transport.observations to ledger.observations;
        connection retain connect ledger.held to retained.held;
        attribute maximumMessages : Integer = 64;
        attribute maximumMessageBytes : Integer = 1048576;
        attribute maximumPolicyBytes : Integer = 65536;
        attribute compiledPolicySlots : Integer = 8;
        assert constraint { maximumMessages <= 64 and maximumMessageBytes <= 1048576 and compiledPolicySlots <= 8 }
    }
}
