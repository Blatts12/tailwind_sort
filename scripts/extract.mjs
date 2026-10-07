// Generates the Erlang terms behind priv/tailwind_data.etf from the installed `tailwindcss` package.
// Usage: node extract.mjs <path-to-tailwindcss-src-dir> <out-file>
// You need tailwindcss@4 and @tailwindcss/node@4 at the same version. You also need the matching
// property-order.ts, is-color.ts, theme.ts and utilities.ts, fetched from the git tag.
import { __unstable__loadDesignSystem } from '@tailwindcss/node'
import fs from 'node:fs'

const [srcDir, outFile] = process.argv.slice(2)
const version = JSON.parse(fs.readFileSync('node_modules/tailwindcss/package.json', 'utf8')).version

// ---------- static sources ----------------------------------------------------
const propertyOrder = [...fs.readFileSync(`${srcDir}/property-order.ts`, 'utf8')
  .matchAll(/^\s*'([^']+)',/gm)].map((m) => m[1])
const isColorSrc = fs.readFileSync(`${srcDir}/is-color.ts`, 'utf8')
const namedColors = [...new Set([...isColorSrc.slice(0, isColorSrc.indexOf('])'))
  .matchAll(/'([a-z]+)'/g)].map((m) => m[1]))]

const themeSrc = fs.readFileSync(`${srcDir}/theme.ts`, 'utf8')
const ignoredBlock = themeSrc.slice(themeSrc.indexOf('ignoredThemeKeyMap = new Map(['), themeSrc.indexOf('])', themeSrc.indexOf('ignoredThemeKeyMap')))
const ignoredThemeKeys = [...ignoredBlock.matchAll(/\[\s*'(--[a-z-]+)',\s*\[([^\]]*)\]/g)]
  .map((m) => [m[1], [...m[2].matchAll(/'(--[a-z-]+)'/g)].map((x) => x[1])])
const utilSrc = fs.readFileSync(`${srcDir}/utilities.ts`, 'utf8')
const namespaces = [...new Set([...utilSrc.matchAll(/'(--[a-z][a-z-]*[a-z])'/g)].map((m) => m[1]))]
  .filter((n) => !n.startsWith('--tw-') && !n.startsWith('--default-'))

// ---------- helpers -----------------------------------------------------------
const loadDesignSystemWith = (css) => __unstable__loadDesignSystem(`@import "tailwindcss";\n${css}`, { base: process.cwd() })
const encodeIndex = (i) => { let s = ''; i += 26 * 26; while (i > 0) { s = String.fromCharCode(97 + (i % 26)) + s; i = Math.floor(i / 26) } return s }

// A lower result sorts earlier. Mirrors the compile.ts comparator, minus variants and the class name.
function compareSigs(a, z) {
  let off = 0
  while (off < a[0].length && off < z[0].length && a[0][off] === z[0][off]) off++
  let d = (a[0][off] ?? Infinity) - (z[0][off] ?? Infinity)
  if (d && !Number.isNaN(d)) return d
  return z[1] - a[1]
}

function findSignature(d, base) {
  let best = null
  for (let c of d.parseCandidate(base)) {
    if (c.variants.length) continue
    for (let r of d.compileAstNodes(c, 1)) {
      let s = [r.propertySort.order, r.propertySort.count]
      if (!best || compareSigs(s, best) < 0) best = s
    }
  }
  return best
}
const toSigKey = (s) => JSON.stringify(s)

// ---------- design systems ----------------------------------------------------
const base = await loadDesignSystemWith('')
const singlesCss = '@theme {\n' + namespaces.map((n, i) => {
  let v = n.includes('color') ? 'red' : '1px'
  return `  ${n}-zzs${encodeIndex(i)}: ${v};`
}).join('\n') + '\n}'
const singles = await loadDesignSystemWith(singlesCss)

const functionalRoots = [...base.utilities.keys('functional')]
const staticUtils = [...base.utilities.keys('static')]

// Corpus of arbitrary values, the content between [ ]. We use it to learn how types resolve.
const corpus = [
  '#fff', 'red', 'rgb(0,0,0)', 'oklch(50%_0.2_200)', 'transparent', 'currentColor', 'color-mix(in_oklab,red,blue)',
  '10px', '1.5rem', '0', '1', '1.5', '-2', '50%', '12.5%', 'calc(100%-1rem)', 'min(10px,5vw)', '--spacing(4)',
  'url(/a.png)', 'linear-gradient(red,blue)', 'url(/a.png),linear-gradient(red,blue)', 'image-set(url(a.png)_1x)',
  '45deg', '0.5turn', '1_2_3', '10px_20px', 'center', 'center_top', 'top', 'left_10px', '50%_50%',
  'cover', 'contain', 'auto', 'auto_100%', '10px_auto', 'thin', 'medium', 'thick', '2px_thin',
  'large', 'x-large', 'larger', 'smaller', 'sans-serif', 'monospace', "'Inter'", 'Inter,sans-serif',
  '"Open_Sans"', '16/9', '1/2', 'var(--x)', 'var(--x,10px)', '0_0_1px_red', '0_1px_2px_rgb(0_0_0/0.1)',
  'none', 'inherit', 'fit-content', 'repeat(3,minmax(0,1fr))', '1fr_2fr', 'span_2', 'subgrid', '100', '700',
  'bold', 'italic', 'cubic-bezier(0.4,0,0.2,1)', 'opacity,transform', '0.3s', '200ms', 'blur(4px)', 'foo',
  'foo_bar', '3px_solid', '1px_2px_3px', 'theme(--color-red-500)',
]
const hints = ['color', 'length', 'percentage', 'ratio', 'number', 'integer', 'url', 'position', 'bg-size',
  'line-width', 'image', 'family-name', 'generic-name', 'absolute-size', 'relative-size', 'angle', 'vector',
  'any', 'size', 'shadow', 'zzqhint']

const keywords = ['none', 'auto', 'full', 'screen', 'min', 'max', 'fit', 'px', 'inherit', 'initial', 'current',
  'transparent', 'normal', 'start', 'end', 'center', 'left', 'right', 'top', 'bottom', 'hidden', 'visible', 'clip',
  'scroll', 'contain', 'cover', 'fill', 'stable', 'subgrid', 'dense', 'row', 'col', 'both', 'x', 'y', 'xy',
  'dvh', 'dvw', 'svh', 'svw', 'lvh', 'lvw', 'lh', 'wrap', 'nowrap', 'balance', 'pretty', 'flat', 'square', 'video']
const vprobes = [
  ['none', null], ['zero', '0'], ['int', '13'], ['dec25', '2.5'], ['dec', '2.3'], ['pct', '10%'],
  ['pctdec', '12.5%'], ['frac', '1/3'], ['word', 'zzqword'], ...keywords.map((k) => [['kw', k], k]),
  ...namespaces.map((n, i) => [['ns', n], `zzs${encodeIndex(i)}`]),
  ...corpus.map((v, i) => [['arb', i], `[${v}]`]),
  ...hints.map((h) => [['hint', h], `[${h}:var(--x)]`]),
]

// Returns the value group of a named value. TailwindSort.Utility.to_value_group/2 mirrors it.
function toValueGroup(v) {
  if (v === '0') return 'zero'
  if (/^\d+$/.test(v)) return 'int'
  if (/^\d*\.\d+$/.test(v)) return Number(v) % 0.25 === 0 && String(Number(v)) === v ? 'dec25' : 'dec'
  if (/^\d+%$/.test(v)) return 'pct'
  if (/^\d*\.\d+%$/.test(v)) return 'pctdec'
  if (keywords.includes(v)) return ['kw', v]
  return 'word'
}
const toValueGroupKey = (vc) => typeof vc === 'string' ? (vc === 'word' ? 'word' : vc) : vc
const functional = {}      // Maps root to [[vclass, sig]].
const bases = []           // Holds [root, base, sig, group] candidates for modifier probing.
for (let root of functionalRoots) {
  let rows = []
  for (let [vclass, v] of vprobes) {
    let b = v === null ? root : `${root}-${v}`
    let s = findSignature(singles, b)
    let named = typeof vclass === 'string' || vclass[0] === 'kw'
    if (!s) { if (named && vclass !== 'frac' && vclass !== 'none') bases.push([root, b, null, toValueGroupKey(vclass)]); continue }
    rows.push([vclass, s])
    if (vclass !== 'frac') bases.push([root, b, s, typeof vclass === 'string' || vclass[0] === 'kw' ? toValueGroupKey(vclass) : (Array.isArray(vclass) && vclass[0] === 'ns') ? 'theme' : (Array.isArray(vclass) && (vclass[0] === 'arb' || vclass[0] === 'hint')) ? vclass : 'other'])
  }
  if (rows.length) functional[root] = rows
}

// Namespace priority. It only matters where two namespaces give different sigs.
const pairList = []
for (let [root, rows] of Object.entries(functional)) {
  let ns = rows.filter(([vc]) => Array.isArray(vc) && vc[0] === 'ns')
  for (let i = 0; i < ns.length; i++) for (let j = i + 1; j < ns.length; j++)
    if (toSigKey(ns[i][1]) !== toSigKey(ns[j][1])) pairList.push([root, ns[i], ns[j]])
}
const pairNs = new Map()
for (let [, a, b] of pairList) pairNs.set(`${a[0][1]}|${b[0][1]}`, [a[0][1], b[0][1]])
let pairCss = '@theme {\n'
let pairIdx = 0
const pairKey = new Map()
for (let [k, [a, b]] of pairNs) {
  let key = `zzp${encodeIndex(pairIdx++)}`
  pairKey.set(k, key)
  pairCss += `  ${a}-${key}: 1px;\n  ${b}-${key}: 1px;\n`
}
const pairs = await loadDesignSystemWith(singlesCss.replace(/}\s*$/, '') + pairCss.replace('@theme {', '') + '}')
const before = {} // Maps root to a list of [winner, loser].
for (let [root, a, b] of pairList) {
  let s = findSignature(pairs, `${root}-${pairKey.get(`${a[0][1]}|${b[0][1]}`)}`)
  if (!s) continue
  let k = toSigKey(s)
  if (k === toSigKey(a[1])) (before[root] ??= []).push([a[0][1], b[0][1]])
  else if (k === toSigKey(b[1])) (before[root] ??= []).push([b[0][1], a[0][1]])
}
const nsPriority = {}
for (let [root, rows] of Object.entries(functional)) {
  let ns = rows.filter(([vc]) => Array.isArray(vc) && vc[0] === 'ns').map(([vc]) => vc[1])
  let rel = before[root] ?? []
  // A rough topological sort. The namespace with more wins goes first.
  let score = (n) => rel.filter(([w]) => w === n).length
  ns.sort((a, b) => score(b) - score(a))
  if (ns.length) nsPriority[root] = ns
}

// ---------- exact table from the class list -------------------------------
const theme = [...base.theme.entries()].map(([k, v]) => [k, v.value])
const themeNames = new Set(theme.map(([k]) => k))
const exact = {}
const exactBases = []
const classList = new Set([...base.getClassList().map(([c]) => c), ...staticUtils])
for (let c of classList) {
  let s = findSignature(base, c)
  if (!s) continue
  // Theme variables this class can depend on.
  let deps = new Set()
  for (let cand of base.parseCandidate(c)) {
    if (cand.kind !== 'functional' || !cand.value || cand.value.kind !== 'named') continue
    for (let n of nsPriority[cand.root] ?? []) {
      if (themeNames.has(`${n}-${cand.value.value}`)) deps.add(`${n}-${cand.value.value}`)
    }
  }
  exact[c] = [s, [...deps]]
  if (!c.includes('/')) {
    let cand = base.parseCandidate(c).find((x) => x.kind === 'functional')
    if (cand) exactBases.push([cand.root, c, s, deps.size ? 'theme' : cand.value === null ? 'none' : toValueGroup(cand.value.value)])
  }
}

// ---------- modifiers ----------------------------------------------------------
const mprobes = [['int', '50'], ['dec25', '2.5'], ['dec', '2.3'], ['word', 'zzqword'], ['arb', '[10px]'], ['var', '(--x)']]
// Find out which namespaces ever work as a modifier.
const modNs = []
{
  let seen = new Set()
  for (let [root, b, s] of bases) {
    let k = `${root}|${toSigKey(s)}`
    if (seen.has(k)) continue
    seen.add(k)
    namespaces.forEach((n, i) => { if (!modNs.includes(n) && findSignature(singles, `${b}/zzs${encodeIndex(i)}`)) { modNs.push(n); if (process.env.DBG) console.error("modns", n, b) } })
  }
}
for (let n of modNs) mprobes.push([['ns', n], `zzs${encodeIndex(namespaces.indexOf(n))}`])

const mods = {} // Maps `${root}|${vg}|${toSigKey(sig)}` to {mclassKey: sig or 'invalid'}.
const modConflicts = []
const perBaseCount = new Map()
function probeModifiers(list, probes) {
  for (let [root, b, s, vg] of list) {
    let k = `${root}|${JSON.stringify(vg)}|${toSigKey(s)}`
    let n = perBaseCount.get(k) ?? 0
    if (n >= 4) continue
    perBaseCount.set(k, n + 1)
    let entry = (mods[k] ??= { root, vg, sig: s, m: {} })
    for (let [mclass, m] of probes) {
      let r = findSignature(singles, `${b}/${m}`) ?? 'invalid'
      let mk = JSON.stringify(mclass)
      if (mk in entry.m && JSON.stringify(entry.m[mk]) !== JSON.stringify(r)) modConflicts.push(`${b}/${m}`)
      else entry.m[mk] = r
    }
  }
}
const isArbitraryGroup = ([, , , vg]) => typeof vg !== 'string' && vg[0] !== 'kw'
probeModifiers(bases.filter((x) => !isArbitraryGroup(x)), mprobes)
// Namespaces whose modifier result differs from a plain word somewhere.
const usefulNs = new Set()
for (let e of Object.values(mods)) {
  let w = JSON.stringify(e.m['"word"'])
  for (let mk of Object.keys(e.m)) if (mk.startsWith('["ns"') && JSON.stringify(e.m[mk]) !== w) usefulNs.add(mk)
}
probeModifiers(bases.filter(isArbitraryGroup), mprobes.filter(([mc]) => !Array.isArray(mc) || usefulNs.has(JSON.stringify(mc))))
console.error('useful modifier namespaces:', [...usefulNs].join(' '))

// Per-class overrides, for class list entries that disagree with their group.
const exactMods = {}
for (let [root, b, s, vg] of exactBases) {
  let entry = mods[`${root}|${JSON.stringify(vg)}|${toSigKey(s)}`]
  for (let [mclass, m] of mprobes) {
    let mk = JSON.stringify(mclass)
    if (mk.startsWith('["ns"') && !usefulNs.has(mk)) continue
    let r = findSignature(singles, `${b}/${m}`) ?? 'invalid'
    if (!entry || JSON.stringify(entry.m[mk] ?? 'invalid') !== JSON.stringify(r)) (exactMods[b] ??= {})[mk] = r
  }
}

// ---------- variants ----------------------------------------------------------
const breakpointNames = new Set([...base.theme.namespace('--breakpoint').keys()].filter(Boolean))
const variants = []
let breakpointOrder = null
for (let [name, v] of base.variants.entries()) {
  if (breakpointNames.has(name)) { breakpointOrder = v.order; continue }
  variants.push([name, v.kind, v.order, v.compounds, v.compoundsWith, base.variants.compareFns.has(v.order)])
}
const fvProbes = [['none', null], ['word', 'zzqword'], ['int', '3'], ['arb', '[10px]'], ['arbvar', '[var(--x)]'],
  ['var', '(--x)'], ...namespaces.concat(['--breakpoint', '--container', '--aria', '--data', '--supports'])
    .filter((n, i, a) => a.indexOf(n) === i).map((n) => [['ns', n], null])]
const vsCss = '@theme {\n' + fvProbes.filter(([f]) => Array.isArray(f)).map(([f], i) => `  ${f[1]}-zzv${encodeIndex(i)}: 10px;`).join('\n') + '\n}'
const vds = await loadDesignSystemWith(vsCss)
const fvRules = {}
for (let [name, , , , , ] of variants) {
  let v = base.variants.get(name)
  if (v.kind !== 'functional') continue
  let rules = {}
  let nsI = 0
  for (let [form, val] of fvProbes) {
    let value = val
    if (Array.isArray(form)) value = `zzv${encodeIndex(nsI++)}`
    let prefix = value === null ? name : name === '@' ? `@${value}` : `${name}-${value}`
    let ok = vds.candidatesToCss([`${prefix}:flex`])[0] !== null
    let okMod = vds.candidatesToCss([`${prefix}/zzqmod:flex`])[0] !== null
    rules[JSON.stringify(form)] = [ok, okMod]
  }
  fvRules[name] = rules
}

// ---------- compound chains ---------------------------------------------------
// Whether a chain is valid depends on what the inner variant compiles to.
const compoundRoots = variants.filter(([, k]) => k === 'compound').map(([n]) => n)
const leaves = [
  ...variants.filter(([, k]) => k === 'static').map(([n]) => [n, n]),
  ...[...breakpointNames].map((n) => [n, n]),
  ['aria', 'aria-checked'], ['data', 'data-active'], ['nth', 'nth-3'], ['nth-last', 'nth-last-3'],
  ['nth-of-type', 'nth-of-type-3'], ['nth-last-of-type', 'nth-last-of-type-3'], ['supports', 'supports-grid'],
  ['min', 'min-md'], ['max', 'max-md'], ['@', '@md'], ['@min', '@min-md'], ['@max', '@max-md'],
  ['[sel]', '[.x]'], ['[rel]', '[>img]'], ['[at]', '[@media(width>=10px)]'],
]
const chains = []
const chainCompiles = (raw) => base.candidatesToCss([`${raw}:flex`])[0] != null
for (let c of compoundRoots) {
  for (let [lk, lraw] of leaves) chains.push([[c, lk], chainCompiles(`${c}-${lraw}`)])
  for (let c2 of compoundRoots)
    for (let [lk, lraw] of leaves) chains.push([[c, c2, lk], chainCompiles(`${c}-${c2}-${lraw}`)])
}

// ---------- emit Erlang terms ---------------------------------------------------
const toErlBinary = (s) => '<<"' + s.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n') + '"/utf8>>'
function toVclassTerm(vc) {
  if (typeof vc === 'string') return vc
  if (vc[0] === 'ns') return `{ns,${toErlBinary(vc[1])}}`
  if (vc[0] === 'arb') return `{arb,${vc[1]}}`
  if (vc[0] === 'hint') return `{hint,${toErlBinary(vc[1])}}`
  if (vc[0] === 'kw') return `{kw,${toErlBinary(vc[1])}}`
  throw new Error(vc)
}
const toSigTerm = (s) => s === null ? 'nil' : `{[${s[0].join(',')}],${s[1]}}`
const toErlList = (xs) => `[${xs.join(',\n ')}]`
let out = `%% Generated by extract.mjs from tailwindcss ${version}. Do not edit.\n`
out += `{version, ${toErlBinary(version)}}.\n`
out += `{property_order, ${toErlList(propertyOrder.map(toErlBinary))}}.\n`
out += `{named_colors, ${toErlList(namedColors.map(toErlBinary))}}.\n`
out += `{namespaces, ${toErlList(namespaces.map(toErlBinary))}}.\n`
out += `{theme, ${toErlList(theme.map(([k, v]) => `{${toErlBinary(k)},${toErlBinary(v)}}`))}}.\n`
out += `{static_utilities, ${toErlList(staticUtils.map(toErlBinary))}}.\n`
out += `{functional_roots, ${toErlList(functionalRoots.map(toErlBinary))}}.\n`
out += `{ignored_theme_keys, #{${ignoredThemeKeys.map(([k, v]) => `${toErlBinary(k)} => [${v.map(toErlBinary).join(',')}]`).join(', ')}}}.\n`
out += `{keywords, ${toErlList(keywords.map(toErlBinary))}}.\n`
out += `{hints, ${toErlList(hints.map(toErlBinary))}}.\n`
out += `{corpus, ${toErlList(corpus.map(toErlBinary))}}.\n`
out += `{variants, ${toErlList(variants.map(([n, k, o, c, cw, cmp]) => `{${toErlBinary(n)},${k},${o},${c},${cw},${cmp}}`))}}.\n`
out += `{breakpoint_order, ${breakpointOrder}}.\n`
out += `{functional_variant_rules, #{${Object.entries(fvRules).map(([n, r]) =>
  `${toErlBinary(n)} => #{${Object.entries(r).map(([f, [a, b]]) => `${toVclassTerm(JSON.parse(f))} => {${a},${b}}`).join(', ')}}`).join(',\n ')}}}.\n`
out += `{functional, #{${Object.entries(functional).map(([r, rows]) =>
  `${toErlBinary(r)} => #{${rows.map(([vc, s]) => `${toVclassTerm(vc)} => ${toSigTerm(s)}`).join(', ')}}`).join(',\n ')}}}.\n`
out += `{ns_priority, #{${Object.entries(nsPriority).map(([r, ns]) => `${toErlBinary(r)} => [${ns.map(toErlBinary).join(',')}]`).join(',\n ')}}}.\n`
out += `{exact, #{${Object.entries(exact).map(([c, [s, deps]]) => `${toErlBinary(c)} => {${toSigTerm(s)},[${deps.map(toErlBinary).join(',')}]}`).join(',\n ')}}}.\n`
for (let e of Object.values(mods)) {
  let w = JSON.stringify(e.m['"word"'])
  for (let mk of Object.keys(e.m)) if (mk.startsWith('["ns"') && JSON.stringify(e.m[mk]) === w) delete e.m[mk]
}
out += `{modifiers, #{${Object.values(mods).map(({ root, vg, sig, m }) =>
  `{${toErlBinary(root)},${typeof vg === 'string' ? `'${vg}'` : toVclassTerm(vg)},${toSigTerm(sig)}} => #{${Object.entries(m).map(([mk, r]) =>
    `${toVclassTerm(JSON.parse(mk))} => ${r === 'invalid' ? 'invalid' : toSigTerm(r)}`).join(', ')}}`).join(',\n ')}}}.\n`
out += `{compound_chains, #{${chains.map(([k, ok]) => `[${k.map(toErlBinary).join(',')}] => ${ok}`).join(',\n ')}}}.\n`
out += `{exact_modifiers, #{${Object.entries(exactMods).map(([c, m]) =>
  `${toErlBinary(c)} => #{${Object.entries(m).map(([mk, r]) => `${toVclassTerm(JSON.parse(mk))} => ${r === 'invalid' ? 'invalid' : toSigTerm(r)}`).join(', ')}}`).join(',\n ')}}}.\n`
fs.writeFileSync(outFile, out)
console.error(`tailwind ${version}: ${Object.keys(exact).length} exact, ${Object.keys(functional).length} functional roots, ` +
  `${Object.keys(mods).length} modifier groups, ${Object.keys(exactMods).length} exact-mod overrides, ${modConflicts.length} modifier conflicts, modNs=${modNs.join(',')}`)
if (modConflicts.length) console.error('conflicts sample:', [...new Set(modConflicts.map(c=>c.split('/')[0]))].join(' '))
