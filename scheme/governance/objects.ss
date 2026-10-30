;;; Semantic scope: no transport, ledger, scheduling or execution capability.
(import (only-in :clan/poo/object .o) "./func.ss")
(export Governance.)
(def Governance. (.o assess: assess-governance! open: governor-open-nodes))
