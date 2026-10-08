defmodule TailwindSort.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :tailwind_sort,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "mix format plugin that sorts Tailwind CSS v4 classes like prettier-plugin-tailwindcss",
      package: [licenses: ["MIT"], files: ~w(lib priv scripts mix.exs README.md LICENSE)]
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    []
  end
end
