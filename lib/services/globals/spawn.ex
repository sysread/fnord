defmodule Services.Globals.Spawn do
  @pd_root_key :globals_root_pid

  def spawn(fun) do
    if root = Services.Globals.current_root() do
      Kernel.spawn(fn ->
        Process.put(@pd_root_key, root)
        fun.()
      end)
    else
      Kernel.spawn(fun)
    end
  end

  def async(fun) do
    if root = Services.Globals.current_root() do
      Task.async(fn ->
        Process.put(@pd_root_key, root)
        fun.()
      end)
    else
      Task.async(fun)
    end
  end

  def async_stream(enum, fun, opts \\ []) do
    if root = Services.Globals.current_root() do
      Task.async_stream(
        enum,
        fn item ->
          Process.put(@pd_root_key, root)
          fun.(item)
        end,
        opts
      )
    else
      Task.async_stream(enum, fun, opts)
    end
  end
end
