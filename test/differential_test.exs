defmodule TailwindSort.DifferentialTest do
  # scripts/fixtures.mjs produces the fixtures. Each one is a random class list, sorted by
  # prettier-plugin-tailwindcss against the real Tailwind design system.
  use ExUnit.Case, async: true

  alias TailwindSort.Design
  alias TailwindSort.Sorter

  for {name, css} <- [
        default: nil,
        custom: "test/fixtures/custom.css",
        prefix: "test/fixtures/prefix.css",
        reset: "test/fixtures/reset.css"
      ] do
    @tag fixture: name
    test "matches prettier-plugin-tailwindcss on #{name} stylesheet" do
      {:ok, cases} = :file.consult(~c"test/fixtures/fx_#{unquote(name)}.term")
      design = Design.load_design(unquote(css))

      mismatches =
        for {input, expected} <- cases,
            (got = Sorter.sort_class_string(input, design)) != expected do
          "\n  in:   #{input}\n  want: #{expected}\n  got:  #{got}"
        end

      assert mismatches == [],
             "#{length(mismatches)}/#{length(cases)} differ:" <>
               Enum.join(Enum.take(mismatches, 5))
    end
  end
end
