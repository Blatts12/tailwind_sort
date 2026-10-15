defmodule TailwindSort.TextTest do
  use ExUnit.Case, async: true

  alias TailwindSort.Text

  describe "split_top_level/2" do
    test "ignores separators inside brackets and quotes" do
      assert Text.split_top_level("hover:[&:hover]:content-['a:b']:p-4", ":") ==
               ["hover", "[&:hover]", "content-['a:b']", "p-4"]
    end

    test "keeps an escaped separator in its segment" do
      assert Text.split_top_level(~S(a\:b:c), ":") == [~S(a\:b), "c"]
    end
  end

  test "skip_quoted_string/2 skips escaped quotes and returns what follows the closing one" do
    assert Text.skip_quoted_string(~S(a\"b" rest), ?") == " rest"
  end

  describe "number checks" do
    test "digits?/1 accepts only plain digits" do
      assert Text.digits?("12")
      refute Text.digits?("")
      refute Text.digits?("-1")
      refute Text.digits?("1.5")
    end

    test "decimal?/1 needs digits after the dot" do
      assert Text.decimal?(".5")
      assert Text.decimal?("1.5")
      refute Text.decimal?("1.")
      refute Text.decimal?("1")
    end

    test "percent_value?/2 lets the caller decide what counts as the number" do
      assert Text.percent_value?("50%", &Text.digits?/1)
      refute Text.percent_value?("50.5%", &Text.digits?/1)
      assert Text.percent_value?("50.5%", &Text.decimal?/1)
    end

    test "quarter_multiple?/1 wants a multiple of 0.25 written the way JS prints it" do
      assert Text.quarter_multiple?("2.5")
      assert Text.quarter_multiple?("0.25")
      refute Text.quarter_multiple?("2.3")
      refute Text.quarter_multiple?("2.50")
    end
  end

  test "named_value?/1 accepts the characters Tailwind allows in a named value" do
    assert Text.named_value?("red-500")
    assert Text.named_value?("1.5")
    assert Text.named_value?("50%")
    refute Text.named_value?("a/b")
    refute Text.named_value?("")
  end

  test "trim_leading_whitespace/1 and trim_trailing_whitespace/1 trim every regex whitespace byte" do
    assert Text.trim_leading_whitespace(" \t\n\v\fp-4 flex ") == "p-4 flex "
    assert Text.trim_trailing_whitespace(" p-4 flex \t\n\v\f") == " p-4 flex"
  end

  describe "compare_alnum/2" do
    test "compares runs of digits as numbers" do
      assert Text.compare_alnum("p-2", "p-10") < 0
      assert Text.compare_alnum("p-10", "p-2") > 0
    end

    test "breaks a numeric tie on the digits as written" do
      assert Text.compare_alnum("p-02", "p-2") < 0
    end
  end
end
