# mix run bench/format_template.exs
# BENCH_TAG=baseline mix run bench/format_template.exs saves a run for later runs to compare against

block = fn i ->
  """
  <div class="hover:bg-gray-50 text-sm px-4 flex shadow-sm rounded-lg focus-visible:ring-2 items-center bg-white font-medium py-2 text-gray-900" id={"row-#{i}"}>
    <.link navigate={~p"/items/\#{@item}"} class={["md:p-8 dark:bg-gray-900 p-4 grid gap-4", @active && "bg-indigo-600 text-white"]}>
      <span class="truncate font-semibold text-zinc-900">{@item.name}</span>
    </.link>
    <%= if @show do %>
      <p class="mt-2 text-sm leading-6 text-zinc-600">Some text here that is long enough to look like a paragraph.</p>
    <% end %>
  </div>
  """
end

format = &TailwindSort.format(&1, extension: ".heex", tailwind_sort: [])
unsorted = Enum.map_join(1..200, block)

save_or_load =
  case System.get_env("BENCH_TAG") do
    nil -> [load: "bench/format_template.benchee"]
    tag -> [save: [path: "bench/format_template.benchee", tag: tag]]
  end

Benchee.run(
  %{"format" => format},
  [
    inputs: %{
      "200 blocks, 800 class attrs, unsorted" => unsorted,
      "200 blocks, 800 class attrs, already sorted" => format.(unsorted)
    },
    # mix format runs each file in a fresh task, so every run starts without cached classes
    before_each: fn input ->
      Process.delete(TailwindSort.Sorter)
      input
    end,
    warmup: 1,
    time: 3,
    memory_time: 1
  ] ++ save_or_load
)
