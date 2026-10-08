defmodule TailwindSortTest do
  use ExUnit.Case, async: true
  doctest TailwindSort

  defp format_heex(src), do: TailwindSort.format(src, extension: ".heex")
  defp format_holo(src), do: TailwindSort.format(src, extension: ".holo")

  describe "sort/2" do
    test "unknown classes first, `...` last, known duplicates removed" do
      assert TailwindSort.sort_classes("p-4 my-thing flex ... flex my-thing") ==
               "my-thing my-thing flex p-4 ..."
    end

    test "variants after base utilities, breakpoints by size" do
      assert TailwindSort.sort_classes("lg:p-2 sm:p-2 hover:p-2 p-2") ==
               "p-2 hover:p-2 sm:p-2 lg:p-2"
    end

    test "uses @theme values from the stylesheet" do
      css = "test/fixtures/custom.css"
      # bg-brand is a color only because custom.css defines --color-brand.
      assert TailwindSort.sort_classes("bg-brand p-4", stylesheet: css) == "bg-brand p-4"
      assert TailwindSort.sort_classes("bg-brand p-4") == "bg-brand p-4"
      assert TailwindSort.sort_classes("p-4 bg-brand", stylesheet: css) == "bg-brand p-4"
      assert TailwindSort.sort_classes("p-4 bg-brand") == "bg-brand p-4"
      # content-auto exists only through the @utility in custom.css.
      assert TailwindSort.sort_classes("p-4 content-auto flex", stylesheet: css) ==
               "flex p-4 content-auto"

      assert TailwindSort.sort_classes("p-4 content-auto flex") == "content-auto flex p-4"
    end
  end

  describe "icon_prefix" do
    # Expected orders come from tailwindcss 4.3.3 with Phoenix's assets/vendor/heroicons.js.
    test "hero- icons sort by the CSS the heroicons plugin emits" do
      assert TailwindSort.sort_classes("size-4 hero-x-mark mr-2") == "mr-2 hero-x-mark size-4"

      assert TailwindSort.sort_classes(
               "hero-x-mark-mini size-4 text-zinc-500 ml-1 shrink-0 animate-spin"
             ) ==
               "ml-1 hero-x-mark-mini size-4 shrink-0 animate-spin text-zinc-500"
    end

    test "variants apply; modifiers and arbitrary values are not icons" do
      assert TailwindSort.sort_classes("hover:hero-x-mark mr-2 hero-x-mark/50 hero-[x]") ==
               "hero-x-mark/50 hero-[x] mr-2 hover:hero-x-mark"
    end

    test "custom prefix and disabling" do
      assert TailwindSort.sort_classes("size-4 lucide-check mr-2", icon_prefix: "lucide-") ==
               "mr-2 lucide-check size-4"

      assert TailwindSort.sort_classes("size-4 lucide-check mr-2") == "lucide-check mr-2 size-4"

      assert TailwindSort.sort_classes("size-4 hero-x-mark mr-2", icon_prefix: nil) ==
               "hero-x-mark mr-2 size-4"
    end

    test "formatter option" do
      src = ~s(<span class="size-4 hero-x-mark mr-2"></span>)
      assert format_heex(src) == ~s(<span class="mr-2 hero-x-mark size-4"></span>)

      assert TailwindSort.format(src, extension: ".heex", tailwind_sort: [icon_prefix: nil]) ==
               ~s(<span class="hero-x-mark mr-2 size-4"></span>)
    end
  end

  describe "HEEx" do
    test "sorts static class attributes and collapses whitespace" do
      assert format_heex(~s(<div class="  p-4\n  flex " id="a"></div>)) ==
               ~s(<div class="flex p-4" id="a"></div>)
    end

    test "sorts string literals inside class={...}, keeping interpolation in place" do
      assert format_heex(
               ~S|<.btn class={["p-4 flex", @on && "px-2 bg-red-500", "mt-#{@n} p-2 flex"]} />|
             ) ==
               ~S|<.btn class={["flex p-4", @on && "bg-red-500 px-2", "mt-#{@n} flex p-2"]} />|
    end

    test "leaves everything that is not a class attribute alone" do
      src = ~S'''
      <%!-- <div class="p-4 flex"> --%>
      <!-- <div class="p-4 flex"> -->
      <script>let a = '<div class="p-4 flex">'</script>
      <span data-x="p-4 flex" {@rest}>class="p-4 flex" {@x < 3 && "p-4 flex"}</span>
      <p class={if ok?(@f), do: "block", else: ?{}>x</p>
      '''

      assert format_heex(src) == src
    end

    test "custom attribute list" do
      src = ~s(<div class="p-4 flex" wrapper-class="p-4 flex"></div>)

      out =
        TailwindSort.format(src,
          extension: ".heex",
          tailwind_sort: [attributes: ["wrapper-class"]]
        )

      assert out == ~s(<div class="p-4 flex" wrapper-class="flex p-4"></div>)
    end
  end

  describe "~CLS sigil" do
    defp format_cls(src, config \\ []),
      do: TailwindSort.format(src, sigil: :CLS, tailwind_sort: config)

    test "sorts the class list" do
      assert format_cls("p-4 flex border-red-500 border") == "flex border border-red-500 p-4"
    end

    test "keeps surrounding whitespace, e.g. heredoc newlines" do
      assert format_cls("\n  p-4\n  flex\n") == "\n  flex p-4\n"
    end

    test "uses the configured stylesheet and icon prefix" do
      assert format_cls("p-4 bg-brand size-4 hero-x-mark", stylesheet: "test/fixtures/custom.css") ==
               "hero-x-mark size-4 bg-brand p-4"
    end
  end

  describe "attributes option" do
    defp format_with_attributes(src, attrs),
      do: TailwindSort.format(src, extension: ".heex", tailwind_sort: [attributes: attrs])

    test "exact names and regexes" do
      src =
        ~s(<.input class="p-4 flex" wrapper_class="p-4 flex" label_class={["p-4 flex", @x]} data-class="p-4 flex" />)

      assert format_with_attributes(src, ["class", ~r/_class$/]) ==
               ~s(<.input class="flex p-4" wrapper_class="flex p-4" label_class={["flex p-4", @x]} data-class="p-4 flex" />)

      assert format_with_attributes(src, [~r/^(class|.+_class)$/, "data-class"]) ==
               ~s(<.input class="flex p-4" wrapper_class="flex p-4" label_class={["flex p-4", @x]} data-class="flex p-4" />)
    end

    test "Hologram props with interpolation" do
      out =
        TailwindSort.format(~s(<Card body_class="p-4 {@x} flex mt-2" />),
          extension: ".holo",
          tailwind_sort: [attributes: [~r/class$/]]
        )

      assert out == ~s(<Card body_class="p-4 {@x} mt-2 flex" />)
    end
  end

  describe "Hologram" do
    test "sorts around {...} inside quoted values without moving glued tokens" do
      assert format_holo(~s(<div class="p-4 {@extra} flex mt-2 px-{@n} block"></div>)) ==
               ~s(<div class="p-4 {@extra} mt-2 flex px-{@n} block"></div>)
    end

    test "HEEx does not treat braces in quoted values as interpolation" do
      assert format_heex(~s(<div class="p-4 {x} flex"></div>)) ==
               ~s(<div class="{x} flex p-4"></div>)
    end
  end
end
