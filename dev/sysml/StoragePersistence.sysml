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
        attribute responsibility:String="One physical storage engine\nWAL, FULL and foreign keys\nSame backend for tests and runtime";
        attribute glyph:String="library";
        attribute visualRole:String="publication";
        port commands:~StoragePort;
        port transaction:ScopePort;
    }
    part def TursoWriteScope {
        attribute displayName:String="One deciding transaction";
        attribute responsibility:String="Claim, budget and fence together\nCommit performs no provider send\nRollback or poison on failure";
        attribute glyph:String="decision";
        attribute visualRole:String="policy";
        port transaction:~ScopePort;
        port guardedUse:ScopePort;
        port unresolved:ExposurePort;
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
        part retained:RetainedExposure;
        connection storage connect ledger.storage to driver.commands;
        connection scope connect driver.transaction to transaction.transaction;
        connection finalUse connect transaction.guardedUse to broker.guardedUse;
        connection unresolved connect transaction.unresolved to retained.unresolved;
    }
}
