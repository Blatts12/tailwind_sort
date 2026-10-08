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
      description: "mix format plugin that sorts Tailwind CSS v4 classes like prettier-plugin-tailwindcss",
      package: [licenses: ["MIT"], files: ~w(lib priv scripts mix.exs README.md LICENSE)],
      dialyzer: [plt_add_apps: [:mix]]
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    [
      {:doctor, "~> 0.23.0", only: :dev},
      {:credo, "~> 1.6", only: [:dev, :test], runtime: false},
      {:styler, "~> 1.0", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
