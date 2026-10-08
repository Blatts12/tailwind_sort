# mix run bench/sort_classes.exs
# BENCH_TAG=baseline mix run bench/sort_classes.exs saves a run for later runs to compare against

button =
  "hover:bg-gray-50 text-sm px-4 flex shadow-sm rounded-lg focus-visible:ring-2 items-center bg-white font-medium py-2 text-gray-900"

card =
  """
  md:p-8 dark:bg-gray-900 p-4 grid gap-4 sm:grid-cols-2 lg:grid-cols-3 rounded-xl border border-gray-200
  dark:border-gray-800 bg-white shadow hover:shadow-lg transition-shadow duration-200 text-gray-700
  dark:text-gray-300 group relative overflow-hidden focus-within:ring-2 focus-within:ring-indigo-500
  sm:p-6 max-w-7xl mx-auto w-full min-h-48 ease-out group-hover:translate-y-0.5 phx-no-feedback:hidden
  """

stacked_variants =
  """
  dark:md:hover:group-hover:peer-focus:aria-checked:data-[state=open]:supports-[display:grid]:[&>*]:p-4
  lg:dark:focus-visible:has-[input:checked]:not-first:bg-indigo-600/50
  max-md:rtl:group-data-[side=left]/sidebar:peer-invalid/email:-translate-x-1/2
  print:motion-safe:forced-colors:in-[.theme-x]:*:first-letter:uppercase
  @lg/main:open:starting:inert:nth-[3n+1]:opacity-0
  """

arbitrary_values =
  """
  grid-cols-[repeat(auto-fill,minmax(12rem,1fr))] bg-[url('/images/hero.png')] w-[calc(100%-2rem)]
  [mask-type:luminance] shadow-[0_35px_60px_-15px_rgba(0,0,0,0.3)] text-[length:var(--title-size)]
  bg-(--brand-color) translate-x-[clamp(1rem,5vw,3rem)] [--scroll-offset:56px] top-[117px]
  before:content-['→'] aspect-[16/9] font-[family-name:var(--font-display)] h-[100dvh]
  """

variants = ~w(sm md lg xl 2xl dark hover focus active disabled group-hover peer-checked aria-expanded data-[open] *)

utilities =
  ~w(flex grid hidden p-4 px-2 py-1 m-auto mt-4 gap-2 w-full h-10 text-sm font-bold text-gray-500 bg-white
    border rounded-md shadow opacity-50 translate-x-2 transition duration-150 z-10 inset-0 col-span-2 my-unknown-class)

# bare utilities go in twice to exercise duplicate removal
:rand.seed(:exsss, {1, 2, 3})
huge = Enum.join(Enum.shuffle(for(v <- variants, u <- utilities, do: "#{v}:#{u}") ++ utilities ++ utilities), " ")

save_or_load =
  case System.get_env("BENCH_TAG") do
    nil -> [load: "bench/sort_classes.benchee"]
    tag -> [save: [path: "bench/sort_classes.benchee", tag: tag]]
  end

# Repeated calls in one process hit the class cache, so "cold cache" clears it before each run
Benchee.run(
  %{
    "sort_classes" => &TailwindSort.sort_classes/1,
    "sort_classes, cold cache" =>
      {&TailwindSort.sort_classes/1,
       before_each: fn input ->
         Process.delete(TailwindSort.Sorter)
         input
       end}
  },
  [
    inputs: %{
      "normal: button (12 classes)" => button,
      "normal: card (31 classes)" => card,
      "extreme: stacked variants" => stacked_variants,
      "extreme: arbitrary values" => arbitrary_values,
      "extreme: 425 classes with duplicates" => huge
    },
    warmup: 1,
    time: 3,
    memory_time: 1
  ] ++ save_or_load
)
