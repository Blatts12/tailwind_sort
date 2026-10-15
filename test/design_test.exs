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
end
