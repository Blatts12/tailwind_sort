# tailwind_sort

`tailwind_sort` is a `mix format` plugin that sorts Tailwind CSS v4 classes exactly like
[prettier-plugin-tailwindcss](https://github.com/tailwindlabs/prettier-plugin-tailwindcss).

It works on `~H` and `.heex`, Hologram's `~HOLO` and `.holo`, and `~CLS"..."` class lists in plain Elixir.

## Setup

1. Add the dependency to `mix.exs`. You only need it in dev and test, never at runtime.

   ```elixir
   # mix.exs
   {:tailwind_sort, "~> 0.1", only: [:dev, :test], runtime: false}
   ```

2. Register the plugin in `.formatter.exs` and point it at your Tailwind entry CSS.

   ```elixir
   # .formatter.exs
   [
     plugins: [TailwindSort, Phoenix.LiveView.HTMLFormatter],
     tailwind_sort: [stylesheet: "assets/css/app.css", icon_prefix: "hero-"],
     inputs: ["*.{heex,ex,exs}", "{config,lib,test}/**/*.{heex,ex,exs}"]
   ]
   ```

3. Run `mix format`. Your class lists come back sorted.

## Options

All options live under the `:tailwind_sort` key.

| Option              | Default     | What it does                                                                   |
| ------------------- | ----------- | ------------------------------------------------------------------------------ |
| `stylesheet`        | stock theme | Your Tailwind entry CSS.                                                       |
| `icon_prefix`       | `"hero-"`   | Prefix of icon classes from a heroicons-style plugin. `nil` turns it off.      |
| `attributes`        | `["class"]` | Attributes to sort, as names or regexes. For example `["class", ~r/_class$/]`. |
| `remove_duplicates` | `true`      | Drops repeated known classes.                                                  |

## What gets sorted?

| Source                             | What happens                                                                |
| ---------------------------------- | --------------------------------------------------------------------------- |
| `class="..."`                      | The value gets sorted and its whitespace collapses.                         |
| `class={["a b", @x && "c d"]}`     | Every string literal gets sorted.                                           |
| `"mt-#{@n} p-2 flex"`              | Chunks around `#{}` get sorted. Tokens glued to the interpolation stay put. |
| `class="p-4 {@x} flex"` (Hologram) | Same chunking around `{...}`.                                               |

Unknown classes go first in their original order, just like in the prettier plugin. `...` goes last, and repeated
known classes go away.

## Class lists in Elixir code

Sometimes your classes live in a function instead of a template. Wrap them in `~CLS` and the formatter sorts them
too. Here's a helper that picks wrapper classes for an error state:

```elixir
def pick_wrapper_classes(error?) do
  if error?, do: ~CLS"flex border border-red-500 p-4", else: ~CLS"flex border p-4"
end
```

The formatter only knows the sigil's name. You define the sigil yourself as a compile-time macro, so this package
can stay a dev-only dependency. A good spot for it is your `html_helpers/0`:

```elixir
# e.g. in MyAppWeb.html_helpers/0
defmacro sigil_CLS({:<<>>, _meta, [classes]}, []), do: classes
```

## Icons

Phoenix ships icons through `@plugin "../vendor/heroicons"`. JS plugins don't run here, so we emulate that one.
Any `<icon_prefix><name>` class sorts by the CSS the plugin emits, like `display`, `width`, `height` and `mask`.
For example, `size-4 hero-x-mark mr-2` becomes `mr-2 hero-x-mark size-4`, the same as in prettier.

Variants work. Modifiers like `hero-x-mark/50` and arbitrary values count as unknown, just like in Tailwind. For
another plugin with the same shape, set a different prefix, such as `"lucide-"`.

A word of caution: we don't check icon names against `deps/heroicons`. A misspelled icon sorts like a real one
instead of moving to the front, so the formatter won't catch your typos.

## How does it stay compliant?

Tailwind sorts classes in
[`compile.ts`](https://github.com/tailwindlabs/tailwindcss/blob/v4.3.3/packages/tailwindcss/src/compile.ts). That
code is short, so we ported it to Elixir as is. It compares two classes step by step, and the first step that
finds a difference decides:

1. Variants. Every variant, like `hover` or `md`, has a fixed spot in Tailwind's list. Classes without variants
   come first. With several variants, the one latest in the list counts most. Breakpoints and container sizes sort
   by width.
2. CSS properties. Tailwind keeps a fixed list of CSS properties in
   [`property-order.ts`](https://github.com/tailwindlabs/tailwindcss/blob/v4.3.3/packages/tailwindcss/src/property-order.ts),
   where `display` comes before `padding`. The class whose properties show up earlier in that list goes first.
3. Size. The class that writes more CSS declarations goes first.
4. Name. Classes sort by name, with numbers compared as numbers, so `p-2` comes before `p-10`.

The hard part is step 2. We need to know which CSS properties each class sets. Tailwind works that out in
[`utilities.ts`](https://github.com/tailwindlabs/tailwindcss/blob/v4.3.3/packages/tailwindcss/src/utilities.ts),
which is about 6,800 lines long. Porting and maintaining all of that would be a big job. Instead,
`scripts/extract.mjs` loads the real Tailwind package in Node. It asks Tailwind to build the CSS for a long list of
sample classes and writes down which properties each one sets. The samples cover:

- every class Tailwind lists on its own, from `getClassList()`
- every utility that takes a value, like `p-*` or `bg-*`, tried with each kind of value: plain numbers, theme
  keys, arbitrary values like `[10px]`, type hints like `[length:var(--x)]` and keywords like `auto`
- every kind of modifier, like the `/50` in `bg-red-500/50`
- every variant, plus which variant chains Tailwind accepts. Some look valid but aren't, like `group-not-hover`.

The result ships as `priv/tailwind_data.etf`, about 850 KB. That's the cost of this approach. You get a bigger
package, and we skip porting thousands of lines.

Your stylesheet gets read when you run `mix format`. The plugin picks up:

- `@theme`, including resets like `--color-*: initial`
- `@custom-variant`
- `@utility`, including what `--value()` and `--modifier()` accept
- `prefix()`
- local `@import`s

## How accurate is it?

We run differential tests against prettier-plugin-tailwindcss with tailwindcss 4.3.3. The inputs are random,
deliberately nasty class lists. They mix stacked, compound and arbitrary variants with arbitrary values, modifiers,
negatives, `!` and unknown classes.

| Stylesheet                                   | Cases                          | Match |
| -------------------------------------------- | ------------------------------ | ----- |
| default                                      | 50,000 holdout + 4,000 fixture | 100%  |
| custom `@theme`/`@custom-variant`/`@utility` | 15,000 + 2,000                 | 100%  |
| `prefix(tw)`                                 | 5,000 + 1,000                  | 100%  |
| namespace resets + custom breakpoints        | 5,000                          | 100%  |

Sorting takes about 25 to 45 µs per class.

## Elixir versions

Three features need Elixir 1.15 or newer: the `~CLS` sigil, the `~HOLO` sigil, and chaining with
`Phoenix.LiveView.HTMLFormatter` on the same sigil. On 1.14 the plugin only handles
`~H`, `.heex` and `.holo`.

## Known gaps

- `@plugin` and `@config` aren't evaluated. That covers JS plugins like `@tailwindcss/forms`, typography and
  daisyUI. Their classes count as unknown and move to the front, where prettier would sort them. Heroicons-style
  plugins are the exception, see `icon_prefix`.
- Some utilities read more than one group of theme variables. `text-*` reads both `--color-*` and `--text-*`. If
  you define the same name in both, like `--color-lg` and `--text-lg`, the plugin picks the winner by a fixed
  ranking taken from Tailwind's defaults. Your own stylesheet doesn't change that ranking.
- Extra settings on your own theme values, like `--text-huge--line-height`, don't count toward step 3 of the sort.
  That only matters when two classes tie on steps 1 and 2.

## How do I regenerate the data for another Tailwind version?

The data matches one Tailwind version. To target another one, edit the versions in `scripts/package.json`. Then
run the regen script and the tests:

```sh
scripts/regen.sh && mix test
```

The script needs Node, npm and network access, because it downloads Tailwind's sources. Only maintainers
run it. Your users never need Node.
