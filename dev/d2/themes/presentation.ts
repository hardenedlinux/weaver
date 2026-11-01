import type { ComponentType } from 'react';
import type { LucideProps } from 'lucide-react';
import { Cloud, Cpu, Database, ShieldCheck, Route, GitBranch, Workflow, Layers, Sigma, FileText, CircleHelp, AlertTriangle, Check, Code, Lambda } from 'lucide-react';
import type { Role } from '../src/source/types';

export const palettes: Record<Role, { ink: string; tint: string; label: string; icon: ComponentType<LucideProps> }> = {
  semantic: { ink: '#167663', tint: '#E5F5EE', label: 'SEMANTICS', icon: Lambda },
  cloud: { ink: '#3377B6', tint: '#E7F2FC', label: 'CONTROL', icon: Cloud },
  runtime: { ink: '#7256B1', tint: '#EFEAFA', label: 'EXECUTION', icon: Cpu },
  ledger: { ink: '#3B6D76', tint: '#E7F2F3', label: 'LEDGER', icon: Database },
  policy: { ink: '#AE7829', tint: '#FFF2DA', label: 'POLICY', icon: ShieldCheck },
  verified: { ink: '#2E8B64', tint: '#E5F5ED', label: 'OUTCOME', icon: Check },
  unknown: { ink: '#AF7B25', tint: '#FFF1D9', label: 'UNKNOWN', icon: CircleHelp },
  deny: { ink: '#BA526A', tint: '#FCECF0', label: 'REFUSAL', icon: AlertTriangle },
  note: { ink: '#728198', tint: '#EEF2F7', label: 'CONTRACT', icon: FileText },
};
export const themes = {
  system: { name: 'SYSTEM CONTEXT', accent: '#4268B2', paper: '#F6F8FC', icon: Layers },
  routing: { name: 'MODEL ROUTING', accent: '#D08736', paper: '#FCF9F4', icon: Route },
  flow: { name: 'EXECUTION FLOW', accent: '#258E89', paper: '#F4FAF8', icon: Workflow },
  sequence: { name: 'INTERACTION', accent: '#3E79BA', paper: '#F5F8FD', icon: Code },
  state: { name: 'STATE TRANSITIONS', accent: '#8760B6', paper: '#F9F6FC', icon: GitBranch },
  data: { name: 'DATA & AUTHORITY', accent: '#397C74', paper: '#F6FAF8', icon: Database },
  assurance: { name: 'ASSURANCE', accent: '#52816B', paper: '#F6FAF7', icon: Sigma },
};
