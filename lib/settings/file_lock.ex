defmodule Settings.FileLock do
  @moduledoc """
  Cross-process filesystem lock helpers for settings.json.
  """

  @doc """
  Acquire a lock directory alongside the JSON file at `path`.
  Blocks up to `opts[:timeout_ms]` (default 10_000ms), treats locks older than
  `opts[:stale_ms]` (default 120_000ms) as stale and reclaims them.
  """
  @spec acquire_lock!(path :: binary, opts :: keyword) :: :ok
  def acquire_lock!(path, opts \\ []) do
    lock_dir = path <> ".lock"
    timeout = Keyword.get(opts, :timeout_ms, 10_000)
    stale = Keyword.get(opts, :stale_ms, 120_000)
    start_time = System.monotonic_time(:millisecond)

    do_acquire = fn fun ->
      case File.mkdir(lock_dir) do
        :ok ->
          owner_info =
            [
              "pid: #{inspect(self())}",
              "at:  #{DateTime.utc_now() |> DateTime.to_iso8601()}"
            ]
            |> Enum.join("\n")

          File.write!(Path.join(lock_dir, "owner"), owner_info)
          :ok

        {:error, :eexist} ->
          age_ms =
            case File.stat(lock_dir) do
              {:ok, %File.Stat{mtime: mtime}} ->
                {{y, m, d}, {hh, mm, ss}} = mtime
                file_secs = :calendar.datetime_to_gregorian_seconds({{y, m, d}, {hh, mm, ss}})
                now_secs = System.os_time(:second)
                (now_secs - file_secs) * 1_000

              _ ->
                stale + 1
            end

          if age_ms > stale do
            File.rm_rf!(lock_dir)
            fun.(fun)
          else
            elapsed = System.monotonic_time(:millisecond) - start_time

            if elapsed >= timeout do
              raise "Timeout acquiring file lock for #{path}\n" <>
                      "waited #{elapsed}ms (timeout is #{timeout}ms)"
            else
              :timer.sleep(50)
              fun.(fun)
            end
          end

        {:error, reason} ->
          raise "Unable to create lock directory #{lock_dir}: #{inspect(reason)}"
      end
    end

    do_acquire.(do_acquire)
  end

  @doc """
  Release the lock directory created for `path`.
  """
  @spec release_lock!(path :: binary) :: :ok
  def release_lock!(path) do
    lock_dir = path <> ".lock"
    File.rm_rf!(lock_dir)
    :ok
  end
end
