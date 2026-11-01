import { test, expect } from 'bun:test';
import { generatedLifeline } from '../src/source/compile';

test('only exact generated sequence lifelines are decorations', () => {
  const ids = new Set(['adapter']);
  const edge = { id: '(adapter -- )[0]', src: 'adapter', dst: 'adapter-lifeline-end-68165383', label: '', strokeDash: 6, srcArrow: 'none', dstArrow: 'none' } as const;
  expect(generatedLifeline(edge, ids, 'sequence')).toBe(true);
  expect(generatedLifeline(edge, ids, 'flow')).toBe(false);
  expect(generatedLifeline({ ...edge, label: 'Actual message' }, ids, 'sequence')).toBe(false);
  expect(generatedLifeline({ ...edge, dstArrow: 'triangle' }, ids, 'sequence')).toBe(false);
  expect(generatedLifeline(edge, new Set([...ids, edge.dst]), 'sequence')).toBe(false);
});
