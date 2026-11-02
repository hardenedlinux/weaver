package WeaverStorage {
    private import ScalarValues::*;
    doc /* Logical implementation ownership and scoped calls, not new services
       or portable permissions. The native transaction never escapes to Go. */
    item def StorageCommand;
    item def DecidingScope;
    item def UnknownExposure;
    port def StoragePort {out item command:StorageCommand;}
    port def ScopePort {out item scope:DecidingScope;}
    port def ExposurePort {out item exposure:UnknownExposure;}
    part def StorageLedger :> WeaverExecution::RustLedger {
        port storage:StoragePort;
    }
    part def StorageBroker :> WeaverExecution::RustFinalBroker {
        port guardedUse:~ScopePort;
    }

    part def MrrTursoDriver {
        attribute displayName:String="MRR Data / Turso";
        attribute responsibility:String="One physical storage engine\nShared database, private connections\nDurable original outcomes";
        attribute glyph:String="library";
        attribute visualRole:String="publication";
        port commands:~StoragePort;
        port transaction:ScopePort;
    }
    part def TursoWriteScope {
        attribute displayName:String="Original claim admission";
        attribute responsibility:String="Reserve local and shared capacity\nRetain the exact claim and history\nCommit consumption before effects";
        attribute glyph:String="decision";
        attribute visualRole:String="policy";
        port transaction:~ScopePort;
        port guardedUse:ScopePort;
        port unresolved:ExposurePort;
    }
    part def FinalUseCustody {
        attribute displayName:String="Shared-domain execution custody";
        attribute responsibility:String="Resolve roots before the snapshot\nShared budget or history orders use\nCurrent Policy constrains actual bytes";
        attribute glyph:String="decision";
        attribute visualRole:String="policy";
        port admission:~ScopePort;
        port finalUse:ScopePort;
        port publication:~ScopePort;
        port bindings:~ScopePort;
    }
    part def OriginRegistry {
        attribute displayName:String="Original task and origin registry";
        attribute responsibility:String="One stable task, one original origin\nSource changes retain the same scope\nRecover the original commit decision";
        attribute glyph:String="reference";
        attribute visualRole:String="publication";
        port roots:ScopePort;
    }
    part def GlobalPublication {
        attribute displayName:String="Policy and owner publication";
        attribute responsibility:String="Exclusive Policy and domain changes\nDrain all live execution scopes\nLater releases rejoin the new fence";
        attribute glyph:String="decision";
        attribute visualRole:String="publication";
        port publication:ScopePort;
    }
    part def RetainedExposure {
        attribute displayName:String="Unknown stays held";
        attribute responsibility:String="Read the original outcome\nNo new claim on a retry\nNo refund from missing evidence";
        attribute glyph:String="pending";
        attribute visualRole:String="pending";
        port unresolved:~ExposurePort;
    }
    part admission {
        part ledger:StorageLedger;
        part driver:MrrTursoDriver;
        part transaction:TursoWriteScope;
        part broker:StorageBroker;
        part custody:FinalUseCustody;
        part registry:OriginRegistry;
        part publication:GlobalPublication;
        part retained:RetainedExposure;
        connection storage connect ledger.storage to driver.commands;
        connection scope connect driver.transaction to transaction.transaction;
        connection finalUse connect transaction.guardedUse to custody.admission;
        connection actualSend connect custody.finalUse to broker.guardedUse;
        connection rootBinding connect registry.roots to custody.bindings;
        connection authorityOrder connect publication.publication to custody.publication;
        connection unresolved connect transaction.unresolved to retained.unresolved;
    }
}
