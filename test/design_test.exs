defmodule TailwindSort.DesignTest do
  use ExUnit.Case, async: false

  alias TailwindSort.Design

  @tag :tmp_dir
  test "replaces the cached design when the stylesheet changes", %{tmp_dir: dir} do
    css = Path.join(dir, "app.css")
    File.cp!("test/fixtures/custom.css", css)
    Design.load_design(css)
    count = :persistent_term.info().count

    File.write!(css, "@theme { --color-other: red; }", [:append])
    Design.load_design(css)

    assert :persistent_term.info().count == count
  end

  @tag :tmp_dir
  test "sorts with the new theme after an imported file changes", %{tmp_dir: dir} do
    css = Path.join(dir, "app.css")
    File.write!(css, ~s(@import "tailwindcss";\n@import "./theme.css";))
    File.write!(Path.join(dir, "theme.css"), "")
    assert TailwindSort.sort_classes("p-4 content-auto", stylesheet: css) == "content-auto p-4"

    File.write!(Path.join(dir, "theme.css"), "@utility content-auto { content-visibility: auto; }")

    assert TailwindSort.sort_classes("p-4 content-auto", stylesheet: css) == "p-4 content-auto"
  end

  @tag :tmp_dir
  test "sorts with the new stylesheet after it changes", %{tmp_dir: dir} do
    css = Path.join(dir, "app.css")
    File.write!(css, ~s(@import "tailwindcss";))
    assert TailwindSort.sort_classes("p-4 content-auto", stylesheet: css) == "content-auto p-4"

    File.write!(css, ~s(@import "tailwindcss";\n@utility content-auto { content-visibility: auto; }))

    assert TailwindSort.sort_classes("p-4 content-auto", stylesheet: css) == "p-4 content-auto"
  end

  test "load_tailwind_data/0 reads data generated from the pinned tailwindcss version" do
    assert Design.load_tailwind_data().version == "4.3.3"
  end

  describe "build_design/2" do
    setup do
      css = ~S"""
      @import "tailwindcss" prefix(tw);
      @theme { --color-brand: #123; }
      @custom-variant pointer (@media (pointer: fine));
      @utility content-auto { content-visibility: auto; }
      """

      %{d: Design.build_design(TailwindSort.Stylesheet.parse_stylesheet(css))}
    end

    test "adds theme keys from the stylesheet", %{d: d} do
      assert Design.theme_has_key?(d, "--color", "brand")
    end

    test "registers custom variants and utilities", %{d: d} do
      assert Map.has_key?(d.variants, "pointer")
      assert "content-auto" in d.static
    end

    test "keeps the prefix", %{d: d} do
      assert d.prefix == "tw"
    end
  end

  describe "theme_has_key?/3" do
    setup do
      %{d: Design.load_design()}
    end

    test "finds a key in a namespace", %{d: d} do
      assert Design.theme_has_key?(d, "--color", "red-500")
      refute Design.theme_has_key?(d, "--color", "nope")
    end

    test "skips keys that belong to a more specific namespace", %{d: d} do
      assert Map.has_key?(d.theme, "--text-shadow-sm")
      refute Design.theme_has_key?(d, "--text", "shadow-sm")
    end
  end
end
