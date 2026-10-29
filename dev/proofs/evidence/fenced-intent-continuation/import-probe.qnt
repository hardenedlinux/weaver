module ContinuationImportProbe {
  import DeviceIsolationRecovery as D from "./DeviceIsolationRecovery"
  import KeyBoundaryQueue as K from "./KeyBoundaryQueue"
  run sharedNativeStateTest = D::boot.expect(K::k.epoch == 1 and D::safety)
}
