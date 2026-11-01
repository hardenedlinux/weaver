import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { parse, type Font } from 'opentype.js';

function load(weight: 400 | 600): Font {
  const path = fileURLToPath(import.meta.resolve(`@fontsource/inter/files/inter-latin-${weight}-normal.woff`));
  return parse(Uint8Array.from(readFileSync(path)).buffer);
}
const fonts = { regular: load(400), strong: load(600) };
function glyphRun(text: string, size: number, strong: boolean, outlines = false): { width: number; path: string } {
  const font = strong ? fonts.strong : fonts.regular;
  const scale = size / font.unitsPerEm;
  let width = 0;
  let previous: ReturnType<Font['charToGlyph']> | undefined;
  const paths: string[] = [];
  // Architecture sources are English. Use explicit glyph metrics/outlines,
  // without requiring optional font substitution features for Latin labels.
  for (const character of text) {
    const glyph = font.charToGlyph(character);
    if (previous) width += font.getKerningValue(previous, glyph) * scale;
    if (outlines) paths.push(glyph.getPath(width, 0, size).toPathData(2));
    width += (glyph.advanceWidth ?? font.unitsPerEm) * scale;
    previous = glyph;
  }
  return { width, path: paths.join(' ') };
}
export function textWidth(text: string, size: number, strong = false): number {
  return glyphRun(text, size, strong).width;
}
export function wrapText(text: string, width: number, size: number, maxLines = 3, strong = false): string[] {
  const words = text.trim().split(/\s+/).filter(Boolean);
  const lines: string[] = [];
  let line = '';
  for (const word of words) {
    if (line && textWidth(`${line} ${word}`, size, strong) > width) { lines.push(line); line = word; }
    else line = line ? `${line} ${word}` : word;
  }
  if (line) lines.push(line);
  const result = lines.slice(0, maxLines);
  if (lines.length > maxLines && result.length) result[result.length - 1] = `${result[result.length - 1]}…`;
  return result.map(value => {
    let fit = value;
    while (textWidth(fit, size, strong) > width && fit.length > 1) fit = `${fit.slice(0, -2)}…`;
    return fit;
  });
}
export function Lettering({ text, x, y, size = 14, strong = false, fill = '#25334B', anchor = 'start' }: {
  text: string; x: number; y: number; size?: number; strong?: boolean; fill?: string; anchor?: 'start' | 'middle' | 'end';
}) {
  const run = glyphRun(text, size, strong, true);
  const width = run.width;
  const left = anchor === 'middle' ? x - width / 2 : anchor === 'end' ? x - width : x;
  return <path d={run.path} transform={`translate(${left} ${y})`} fill={fill} aria-label={text} />;
}
