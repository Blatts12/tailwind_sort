defmodule TailwindSort do
  @moduledoc """
  Sorts Tailwind CSS v4 classes in your templates the same way `prettier-plugin-tailwindcss`
  does. You get the familiar class order from `mix format`, with no Node in your toolchain.

  This guide assumes your project already runs `mix format` and uses Tailwind v4.

  ## Setup

  Add the plugin to your `.formatter.exs` and put its options under the `:tailwind_sort` key.
  The stylesheet path points at your Tailwind entry CSS.

      # .formatter.exs
      [
        plugins: [TailwindSort, Phoenix.LiveView.HTMLFormatter],
        tailwind_sort: [stylesheet: "assets/css/app.css", icon_prefix: "hero-"],
        inputs: ["*.{heex,ex,exs}", "{config,lib,test}/**/*.{heex,ex,exs}"]
      ]

  The plugin handles `~H` and `.heex`, Hologram's `~HOLO` and `.holo`, and `~CLS"..."` class
  lists in plain Elixir code. `~HOLO` and `~CLS` need Elixir 1.15 or newer.

  The formatter only knows the `~CLS` name. You define the sigil yourself as a compile-time
  macro, for example in your `html_helpers`:

      defmacro sigil_CLS({:<<>>, _meta, [classes]}, []), do: classes

  ## Options

    * `:stylesheet` is your Tailwind entry CSS. The plugin reads `@theme`, `@custom-variant`,
      `@utility`, `prefix(...)` and local `@import`s from it. Defaults to the stock theme.
    * `:icon_prefix` marks icon classes from a plugin shaped like Phoenix's
      `assets/vendor/heroicons.js`. Those classes sort by the CSS that plugin emits.
      Defaults to `"hero-"`. Set it to `nil` and such classes count as unknown.
    * `:attributes` lists the attributes to sort, as exact names or regexes. For example,
      `["class", ~r/_class$/]` also sorts `wrapper_class`. Defaults to `["class"]`.
    * `:remove_duplicates` drops repeated known classes. Defaults to `true`.

  ## Limits

  The plugin can't run JS plugins like `@tailwindcss/forms` or daisyUI. Their classes count as
  unknown and move to the front, where prettier would sort them. If your project leans on
  those plugins, prettier with the official plugin stays the more accurate choice.
  """

  @behaviour Mix.Tasks.Format

  alias TailwindSort.Design
  alias TailwindSort.Sorter
  alias TailwindSort.Template

  # Multi-letter sigils like ~HOLO and ~CLS arrived in Elixir 1.15. Older versions reject the key.
  @sigils if Version.match?(System.version(), ">= 1.15.0"), do: [:H, :HOLO, :CLS], else: [:H]

  @impl true
  def features(_opts), do: [sigils: @sigils, extensions: [".heex", ".holo"]]

  @impl true
  def format(contents, opts) do
    config = Keyword.get(opts, :tailwind_sort, [])

    if opts[:sigil] == :CLS,
      do: format_class_sigil(contents, config),
      else: format_template(contents, opts, config)
  end

  # ~CLS"..." holds a bare class list. We keep the surrounding whitespace because heredocs end in a newline.
  defp format_class_sigil(contents, config) do
    [lead, classes, trail] =
      Regex.run(~r/\A(\s*)(.*?)(\s*)\z/s, contents, capture: :all_but_first)

    lead <> Sorter.sort_class_string(classes, load_configured_design(config), config) <> trail
  end

  defp format_template(contents, opts, config) do
    hologram? = opts[:sigil] == :HOLO or opts[:extension] == ".holo"

    Template.sort_class_attributes(
      contents,
      load_configured_design(config),
      Keyword.put(config, :interpolate_quoted, hologram?)
    )
  end

  @doc """
  Sorts a whitespace separated class string. It takes the same options as the formatter.
  Unknown classes like `foo` move to the front:

      iex> TailwindSort.sort_classes("p-4 flex hover:p-2 foo")
      "foo flex p-4 hover:p-2"
  """
  def sort_classes(classes, opts \\ []) when is_binary(classes) do
    Sorter.sort_class_string(classes, load_configured_design(opts), opts)
  end

  defp load_configured_design(opts), do: Design.load_design(opts[:stylesheet], Keyword.take(opts, [:icon_prefix]))
end
