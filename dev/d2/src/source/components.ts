// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

import type {IconPack} from '@deterministic-engineering/render/icons';

/** Canonical functional glyphs; brands and teaching illustrations have other owners. */
export const componentVocabulary = Object.freeze({
  "routing": {
    "file": "route",
    "label": "LLM routing: choose an eligible provider",
    "source": "https://github.com/lucide-icons/lucide/blob/1980e3d59b0fa1a2aeb566d5902b25ee98204001/icons/route.svg"
  },
  "catalog": {
    "file": "book-open",
    "label": "Model catalog: discover configured bindings",
    "source": "https://github.com/lucide-icons/lucide/blob/1980e3d59b0fa1a2aeb566d5902b25ee98204001/icons/book-open.svg"
  },
  "ledger": {
    "file": "database",
    "label": "Durable ledger: retain original consumption",
    "source": "https://github.com/lucide-icons/lucide/blob/1980e3d59b0fa1a2aeb566d5902b25ee98204001/icons/database.svg"
  },
  "policy": {
    "file": "clipboard-check",
    "label": "Policy: assess the actual request",
    "source": "https://github.com/lucide-icons/lucide/blob/1980e3d59b0fa1a2aeb566d5902b25ee98204001/icons/clipboard-check.svg"
  },
  "authentication": {
    "file": "fingerprint-pattern",
    "label": "Identity: authenticate the actual caller",
    "source": "https://github.com/lucide-icons/lucide/blob/1980e3d59b0fa1a2aeb566d5902b25ee98204001/icons/fingerprint-pattern.svg"
  },
  "authorization": {
    "file": "shield-check",
    "label": "Authorization: permit the actual effect",
    "source": "https://github.com/lucide-icons/lucide/blob/1980e3d59b0fa1a2aeb566d5902b25ee98204001/icons/shield-check.svg"
  },
  "claim": {
    "file": "ticket-check",
    "label": "Claim: one original consumption",
    "source": "https://github.com/lucide-icons/lucide/blob/1980e3d59b0fa1a2aeb566d5902b25ee98204001/icons/ticket-check.svg"
  },
  "budget": {
    "file": "coins",
    "label": "Budget: retain shared reservation",
    "source": "https://github.com/lucide-icons/lucide/blob/1980e3d59b0fa1a2aeb566d5902b25ee98204001/icons/coins.svg"
  },
  "history": {
    "file": "rotate-ccw-clock",
    "label": "History: preserve original observations",
    "source": "https://github.com/lucide-icons/lucide/blob/1980e3d59b0fa1a2aeb566d5902b25ee98204001/icons/rotate-ccw-clock.svg"
  },
  "stream": {
    "file": "waves-horizontal",
    "label": "Stream: bounded continuing use",
    "source": "https://github.com/lucide-icons/lucide/blob/1980e3d59b0fa1a2aeb566d5902b25ee98204001/icons/waves-horizontal.svg"
  },
  "writer": {
    "file": "send",
    "label": "Writer: mediate actual bytes",
    "source": "https://github.com/lucide-icons/lucide/blob/1980e3d59b0fa1a2aeb566d5902b25ee98204001/icons/send.svg"
  },
  "telemetry": {
    "file": "activity",
    "label": "Telemetry: observe runtime operation",
    "source": "https://github.com/lucide-icons/lucide/blob/1980e3d59b0fa1a2aeb566d5902b25ee98204001/icons/activity.svg"
  },
  "recovery": {
    "file": "rotate-ccw",
    "label": "Recovery: reconcile original durable state",
    "source": "https://github.com/lucide-icons/lucide/blob/1980e3d59b0fa1a2aeb566d5902b25ee98204001/icons/rotate-ccw.svg"
  },
  "unknown": {
    "file": "circle-question-mark",
    "label": "Unknown outcome: retain exposure",
    "source": "https://github.com/lucide-icons/lucide/blob/1980e3d59b0fa1a2aeb566d5902b25ee98204001/icons/circle-question-mark.svg"
  },
  "agent": {
    "file": "bot",
    "label": "Agent: submit a task-bound request",
    "source": "https://github.com/lucide-icons/lucide/blob/1980e3d59b0fa1a2aeb566d5902b25ee98204001/icons/bot.svg"
  },
  "provider": {
    "file": "brain",
    "label": "LLM provider: serve a bound model request",
    "source": "https://github.com/lucide-icons/lucide/blob/1980e3d59b0fa1a2aeb566d5902b25ee98204001/icons/brain.svg"
  },
  "routine": {
    "file": "workflow",
    "label": "Routine: declare task semantics",
    "source": "https://github.com/lucide-icons/lucide/blob/1980e3d59b0fa1a2aeb566d5902b25ee98204001/icons/workflow.svg"
  },
  "publication": {
    "file": "file-check",
    "label": "Publication: commit reviewed Policy",
    "source": "https://github.com/lucide-icons/lucide/blob/1980e3d59b0fa1a2aeb566d5902b25ee98204001/icons/file-check.svg"
  },
  "message": {
    "file": "message-square",
    "label": "Message: bind payload and identity",
    "source": "https://github.com/lucide-icons/lucide/blob/1980e3d59b0fa1a2aeb566d5902b25ee98204001/icons/message-square.svg"
  }
} as const);

export const componentAssetPaths=Object.freeze([...new Set(Object.values(componentVocabulary).map(asset=>'docs/architecture/diagrams/assets/components/'+asset.file+'.svg'))]);

export function componentIcons(sources:Readonly<Record<string,string>>):IconPack {
 return Object.fromEntries(Object.entries(componentVocabulary).map(([role,asset])=>{
  const path='docs/architecture/diagrams/assets/components/'+asset.file+'.svg',svg=sources[path];
  if(!svg)throw new Error('Missing canonical component icon: '+role);
  return [role,{svg,label:asset.label}];
 }));
}
