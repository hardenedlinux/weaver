import { test, expect } from 'bun:test';
import { generatedLifeline, localIcon } from '../src/source/compile';

test('SDK icons normalize only recognized representations', () => {
  expect(localIcon('assets/go.svg')).toBe('assets/go.svg');
  expect(localIcon({ Path: 'assets/rust.svg' })).toBe('assets/rust.svg');
  expect(localIcon(null)).toBeUndefined();
  expect(localIcon({ Path: 7 })).toBeUndefined();
});

test('only exact generated sequence lifelines are decorations', () => {
  const ids = new Set(['adapter']);
  const edge = { id: '(adapter -- )[0]', src: 'adapter', dst: 'adapter-lifeline-end-68165383', label: '', strokeDash: 6, srcArrow: 'none', dstArrow: 'none' } as const;
  expect(generatedLifeline(edge, ids, 'sequence')).toBe(true);
  expect(generatedLifeline(edge, ids, 'flow')).toBe(false);
  expect(generatedLifeline({ ...edge, label: 'Actual message' }, ids, 'sequence')).toBe(false);
  expect(generatedLifeline({ ...edge, dstArrow: 'triangle' }, ids, 'sequence')).toBe(false);
  expect(generatedLifeline(edge, new Set([...ids, edge.dst]), 'sequence')).toBe(false);
});
