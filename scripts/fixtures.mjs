// Generates differential test fixtures for a given stylesheet. Each fixture pairs a random class
// list with the order that prettier-plugin-tailwindcss, the reference implementation, gives it.
// Usage: node fixtures.mjs <stylesheet.css> <count> <seed> <out.term>
import * as prettier from 'prettier'
import { __unstable__loadDesignSystem } from '@tailwindcss/node'
import fs from 'node:fs'
import path from 'node:path'

const [cssArg, count, seedArg, out] = process.argv.slice(2)
// Stage the stylesheet next to node_modules so `@import "tailwindcss"` resolves for both
// the design system and prettier-plugin-tailwindcss.
const css = path.resolve('.fixture-input.css')
fs.writeFileSync(css, fs.readFileSync(cssArg, 'utf8'))
let seed = Number(seedArg)
// Seeded mulberry32 generator, so the same seed always gives the same fixtures.
const nextRandom = () => {
  seed |= 0; seed = (seed + 0x6d2b79f5) | 0
  let t = Math.imul(seed ^ (seed >>> 15), 1 | seed)
  t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296
}
const pickRandom = (xs) => xs[Math.floor(nextRandom() * xs.length)]

const d = await __unstable__loadDesignSystem(fs.readFileSync(css, 'utf8'), { base: path.dirname(path.resolve(css)) })
const classList = d.getClassList().map(([c]) => c)
const roots = [...d.utilities.keys('functional')]
const variantNames = [...d.variants.keys()].filter((v) => d.variants.kind(v) === 'static')
const prefix = d.theme.prefix ? `${d.theme.prefix}:` : ''

const values = ['0', '1', '2', '13', '2.5', '0.5', '2.3', '1/2', '3/4', '10%', '12.5%', 'px', 'full', 'auto', 'none',
  'red-500', 'blue-500/50', 'ink-900', 'shadow-sm', 'lg', 'xl', '2xl', 'sm', 'brand', 'huge', 'foo', 'tight',
  '[10px]', '[#fff]', '[url(/x.png)]', '[var(--x)]', '(--x)', '(color:--x)', '[length:var(--x)]', '[1.5]', '[3]',
  '[45deg]', '[50%]', "['Inter']", '[sans-serif]', '[0_0_1px_red]', '[calc(100%-1rem)]', '[16/9]', '[center_top]',
  '[large]', '[thin]', '[repeat(3,1fr)]', '[cover]', '[linear-gradient(red,blue)]', '[foo]']
const modifiers = ['', '', '', '', '/50', '/[0.5]', '/(--o)', '/7', '/tight', '/2.5', '/foo', '/[20px]']
const variants = [...variantNames, 'group-hover', 'peer-focus', 'group-focus/item', 'not-hover', 'not-md', 'has-checked',
  'has-[>img]', 'in-focus', 'aria-checked', 'aria-[sort=asc]', 'data-active', 'data-[state=open]', 'supports-grid',
  'supports-[display:grid]', 'min-[600px]', 'max-md', 'max-[900px]', 'min-md', '@md', '@min-[400px]', '@max-sm',
  '@lg/main', 'tablet', 'desk', 'max-tablet', 'min-desk', '[&>*]', '[&_p]', '[@media(width>=10px)]', 'nth-3', 'nth-[2n+1]', 'group-aria-checked', 'peer-[.x]',
  'not-[.x]', 'group-hover/card', 'foo', 'max-[calc(100%-1rem)]', 'min-[40rem]', 'theme-x', '3xl', 'group-not-hover']
const unknown = ['foo', 'js-toggle', 'card', 'btn-primary', 'x', '...', 'bg-foo-500', 'text-unknown', 'p-2.3']

function buildRandomClass() {
  let r = nextRandom()
  let base
  if (r < 0.45) base = pickRandom(classList)
  else if (r < 0.85) base = `${pickRandom(roots)}-${pickRandom(values)}${pickRandom(modifiers)}`
  else if (r < 0.9) base = pickRandom(['[color:red]', '[mask-type:luminance]', '[--my-var:10px]', '[color:red]/50', '[foo:bar]'])
  else base = pickRandom(unknown)
  if (nextRandom() < 0.08) base = nextRandom() < 0.5 ? `${base}!` : `!${base}`
  if (nextRandom() < 0.05 && !base.startsWith('-') && !base.startsWith('[')) base = `-${base}`
  let vs = []
  let n = nextRandom() < 0.55 ? 0 : nextRandom() < 0.7 ? 1 : nextRandom() < 0.8 ? 2 : 3
  for (let i = 0; i < n; i++) vs.push(pickRandom(variants))
  return prefix + vs.map((v) => v + ':').join('') + base
}

const cases = []
for (let i = 0; i < Number(count); i++) {
  let n = 2 + Math.floor(nextRandom() * 10)
  let cls = []
  for (let j = 0; j < n; j++) cls.push(nextRandom() < 0.08 && cls.length ? pickRandom(cls) : buildRandomClass())
  cases.push(cls.join(' '))
}

const html = cases.map((c) => `<div class="${c.replace(/"/g, '&quot;')}"></div>`).join('\n')
const formatted = await prettier.format(html, {
  parser: 'html', plugins: ['prettier-plugin-tailwindcss'], tailwindStylesheet: path.resolve(css), printWidth: 100000,
})
const results = [...formatted.matchAll(/class="([^"]*)"/g)].map((m) => m[1].replace(/&quot;/g, '"'))
if (results.length !== cases.length) throw new Error(`mismatch ${results.length} vs ${cases.length}`)
const toErlBinary = (s) => '<<"' + s.replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"/utf8>>'
fs.writeFileSync(out, cases.map((c, i) => `{${toErlBinary(c)}, ${toErlBinary(results[i])}}.`).join('\n') + '\n')
console.error(`wrote ${cases.length} cases`)
