# tailwind_sort

You want Tailwind classes in a stable, predictable order, but your Elixir project has no reason to run Node.
`tailwind_sort` is a `mix format` plugin that sorts Tailwind CSS v4 classes exactly like
[prettier-plugin-tailwindcss](https://github.com/tailwindlabs/prettier-plugin-tailwindcss). It's pure Elixir,
with no Node and no NIF.

It works on `~H` and `.heex`, Hologram's `~HOLO` and `.holo`, and `~CLS"..."` class lists in plain Elixir.

This guide assumes you know Tailwind v4 and already run `mix format` in your project.

## How do I set it up?

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

Let's break down the example above:

- The macro receives the class string at compile time and returns it unchanged. Your app pays nothing at runtime.
- The `[]` pattern means `~CLS` takes no modifiers.
- Multi-letter sigils are uppercase-only, so they don't interpolate. Compose dynamic parts with lists instead.

We've verified `~CLS` alongside Styler, which handles `.ex` files, in the same `.formatter.exs`.

## Icons

Phoenix ships icons through `@plugin "../vendor/heroicons"`. JS plugins don't run here, so we emulate that one.
Any `<icon_prefix><name>` class sorts by the CSS the plugin emits, like `display`, `width`, `height` and `mask`.
For example, `size-4 hero-x-mark mr-2` becomes `mr-2 hero-x-mark size-4`, the same as in prettier.

Variants work. Modifiers like `hero-x-mark/50` and arbitrary values count as unknown, just like in Tailwind. For
another plugin with the same shape, set a different prefix, such as `"lucide-"`.

A word of caution: we don't check icon names against `deps/heroicons`. A misspelled icon sorts like a real one
instead of moving to the front, so the formatter won't catch your typos.

## How does it stay compliant?

Tailwind's ordering lives in `compile.ts`, and it's small enough to port directly. It compares classes by these
keys, in this order:

1. The variant bitmask, with one bit per variant in registration order. Breakpoints and container queries compare
   by value.
2. The lowest property index from `property-order.ts`.
3. The declaration count. More declarations sort first.
4. The class name, with numbers compared as numbers.

The hard part is knowing which properties each class generates. Porting `utilities.ts` would mean about 6,800
lines of code. Instead, `scripts/extract.mjs` asks the real design system and collects:

- every class from `getClassList()`
- every functional root, probed with each kind of value: bare numbers, each theme namespace, arbitrary values by
  inferred data type, type hints and keywords
- every kind of modifier
- all variants, plus the compound chains Tailwind rejects, like `group-not-hover`

The result ships as `priv/tailwind_data.etf`, about 850 KB. That's the cost of this approach. You get a bigger
package, and we avoid porting and maintaining thousands of lines.

Your stylesheet gets read at format time. The plugin picks up:

- `@theme`, including `--ns-*: initial` resets
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
`Phoenix.LiveView.HTMLFormatter` on the same sigil. We verified them on 1.15.8. On 1.14 the plugin only handles
`~H`, `.heex` and `.holo`.

## Known gaps

- `@plugin` and `@config` aren't evaluated. That covers JS plugins like `@tailwindcss/forms`, typography and
  daisyUI. Their classes count as unknown and move to the front, where prettier would sort them. Heroicons-style
  plugins are the exception, see `icon_prefix`.
- Say you define one key in two namespaces that a root reads, like `--color-lg` and `--text-lg`. The plugin picks
  one by a priority learned from the data, not by your declaration.
- Sub-keys on your own theme values, like `--text-huge--line-height`, don't show up in declaration counts. That
  only matters for ties.

## How do I regenerate the data for another Tailwind version?

The data matches one Tailwind version. To target another one, edit the versions in `scripts/package.json`. Then
run the regen script and the tests:

```sh
scripts/regen.sh && mix test
```

The script needs Node, npm and network access, because it downloads Tailwind's sources. Only maintainers
run it. Your users never need Node.

## When should you not use it?

If your project leans on JS plugins like daisyUI or `@tailwindcss/forms`, prettier with the official plugin gives
you the right order and this package can't. The same goes for Tailwind v3, which this package doesn't support.
For a Phoenix or Hologram app on plain Tailwind v4, you get prettier's order without adding Node to your toolchain.
