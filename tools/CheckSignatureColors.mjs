#!/usr/bin/env node
import {readFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {dirname, resolve} from 'node:path';

// Validate the shipped assets, independently of the palette generator.
const assets = resolve(dirname(fileURLToPath(import.meta.url)), '../PaperPath/Resources/Assets.xcassets');
const names = [
  'Canvas', 'Surface', 'Elevated', 'SurfaceMuted', 'Border',
  'TextPrimary', 'TextSecondary', 'Accent', 'OnAccent',
  'Cyan', 'Mint', 'Amber', 'Rose', 'Ink', 'OnInk',
  'OnInkSecondary', 'InkAccent', 'Selection',
];
function component(value) {
  return String(value).startsWith('0x') ? Number(value) / 255 : Number(value);
}
function luminance(rgb) {
  const linear = rgb.map(v => v <= .04045 ? v / 12.92 : ((v + .055) / 1.055) ** 2.4);
  return linear[0] * .2126 + linear[1] * .7152 + linear[2] * .0722;
}
const colors = Object.fromEntries(names.map(name => {
  const catalog = JSON.parse(readFileSync(resolve(assets, `PP${name}.colorset/Contents.json`), 'utf8'));
  const variants = {};
  for (const entry of catalog.colors) {
    const theme = entry.appearances?.some(a => a.appearance === 'luminosity' && a.value === 'dark') ? 'dark' : 'light';
    const c = entry.color.components;
    if (component(c.alpha) !== 1) throw new Error(`${name}/${theme} must be opaque`);
    const rgb = [c.red, c.green, c.blue].map(component);
    if (rgb.some(v => !Number.isFinite(v) || v < 0 || v > 1)) throw new Error(`${name}/${theme} invalid sRGB`);
    if (variants[theme]) throw new Error(`${name}/${theme} duplicate appearance`);
    variants[theme] = rgb;
  }
  if (!variants.light || !variants.dark) throw new Error(`${name} lacks an appearance`);
  return [name, variants];
}));
const pairs = [
  ...['Canvas', 'Surface', 'Elevated', 'SurfaceMuted'].flatMap(bg =>
    ['TextPrimary', 'TextSecondary', 'Accent', 'Cyan', 'Mint', 'Amber', 'Rose'].map(fg => [fg, bg])),
  ...['Accent', 'Cyan', 'Mint', 'Amber', 'Rose'].map(bg => ['OnAccent', bg]),
  ...['OnInk', 'OnInkSecondary', 'InkAccent'].map(fg => [fg, 'Ink']),
  ...['Accent', 'TextPrimary', 'TextSecondary'].map(fg => [fg, 'Selection']),
];
const results = [];
for (const theme of ['light', 'dark']) {
  for (const [foreground, background] of pairs) {
    const values = [luminance(colors[foreground][theme]), luminance(colors[background][theme])].sort((a,b) => b-a);
    const ratio = (values[0] + .05) / (values[1] + .05);
    results.push({theme, foreground, background, ratio: Number(ratio.toFixed(2))});
    if (ratio < 4.5) throw new Error(`${theme} ${foreground}/${background}: ${ratio.toFixed(2)} < 4.5`);
  }
}
console.log(JSON.stringify({status: 'passed', adaptiveColors: names.length, textPairs: results.length, results}, null, 2));
