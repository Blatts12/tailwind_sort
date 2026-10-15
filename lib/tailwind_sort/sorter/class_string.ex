defmodule TailwindSort.Sorter.ClassString do
  @moduledoc """
  Sorts a class string like `"p-4 flex"` and puts its whitespace back the way prettier does.

  This ports `sortClasses` from `prettier-plugin-tailwindcss`. `TailwindSort.Sorter` decides
  the order of the classes. This module splits the string, keeps pinned classes in place and
  rebuilds the whitespace.
  """

  alias TailwindSort.Design
  alias TailwindSort.Sorter
  alias TailwindSort.Text

  @doc """
  Sorts a whitespace separated class string.

  `:ignore_first` and `:ignore_last` keep the first or last token in place, because it's glued to
  an interpolation. `:collapse_start` and `:collapse_end` trim leading or trailing whitespace.
  """
  @spec sort_class_string(classes :: String.t(), Design.t(), keyword()) :: String.t()
  def sort_class_string(str, d, opts \\ []) do
    {classes, gaps} = split_classes(str)
    {prefix, classes, gaps} = pin_first_class(classes, gaps, opts[:ignore_first])
    {suffix, classes, gaps} = pin_last_class(classes, gaps, opts[:ignore_last])
    {sorted, removed} = Sorter.sort_class_list(classes, d, opts)
    trailing = if sorted != [] and gaps - removed >= length(sorted), do: " ", else: ""

    result =
      (Enum.join(sorted, " ") <> trailing)
      |> replace_leading_whitespace(if(Keyword.get(opts, :collapse_start, true), do: "", else: " "))
      |> replace_trailing_whitespace(if(Keyword.get(opts, :collapse_end, true), do: "", else: " "))

    replace_trailing_whitespace(prefix, " ") <> result <> replace_leading_whitespace(suffix, " ")
  end

  defp pin_first_class([first | rest], gaps, pin?) when pin? not in [nil, false],
    do: {first <> gap_space(gaps), rest, max(gaps - 1, 0)}

  defp pin_first_class(classes, gaps, _pin?), do: {"", classes, gaps}

  defp pin_last_class([_ | _] = classes, gaps, pin?) when pin? not in [nil, false],
    do: {gap_space(gaps) <> List.last(classes), Enum.drop(classes, -1), max(gaps - 1, 0)}

  defp pin_last_class(classes, gaps, _pin?), do: {"", classes, gaps}

  # Mirrors the split in prettier-plugin-tailwindcss. Leading whitespace leaves an empty first class,
  # which is unknown and so stays in front. `gaps` counts the whitespace runs, and each run becomes one space.
  defp split_classes(""), do: {[], 0}

  defp split_classes(str) do
    parts = :binary.split(str, [" ", "\t", "\r", "\f", "\n"], [:global])
    classes = Enum.reject(parts, &(&1 == ""))
    lead = if hd(parts) == "", do: 1, else: 0
    trail = if List.last(parts) == "", do: 1, else: 0

    case classes do
      [] -> {[""], 1}
      _ when lead == 1 -> {["" | classes], length(classes) + trail}
      _ -> {classes, length(classes) - 1 + trail}
    end
  end

  defp gap_space(0), do: ""
  defp gap_space(_), do: " "

  defp replace_leading_whitespace(str, replacement) do
    case Text.trim_leading_whitespace(str) do
      ^str -> str
      trimmed -> replacement <> trimmed
    end
  end

  defp replace_trailing_whitespace(str, replacement) do
    case Text.trim_trailing_whitespace(str) do
      ^str -> str
      trimmed -> trimmed <> replacement
    end
  end
end
