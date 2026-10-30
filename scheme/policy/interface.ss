(import (only-in :yuanxu/module-system/source/declaration .def))
(.def Policy
  identity: 'policy
  core: (.o requires: (.o) scope-contract: PolicyScopeContract exports: Policy.)
  features: (.o))
