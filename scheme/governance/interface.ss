(import (only-in :yuanxu/module-system/source/declaration .def))
(.def Governance
  identity: 'governance
  core: (.o requires: (.o) scope-contract: GovernanceScopeContract exports: Governance.)
  features: (.o))
