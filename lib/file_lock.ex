defmodule FileLock do
  @moduledoc """
  Cross-process filesystem lock helpers for arbitrary files. Uses a lock dir
  with atomic stale lock takeover.

  API is intentionally small:
  - acquire_lock(path)
  - release_lock(path)
  - with_lock(path, fun, opts \\\\ [])
  """

  @timeout_ms 10_000
  @stale_ms 120_000

  @doc """
  Execute `fun` while holding a lock for `path`.

  Returns:
  - `{:ok, result}` when the callback returns normally
  - `{:error, :lock_failed}` when the lock cannot be acquired
  - `{:callback_error, exception}` when the callback raises
  - any `{:error, reason}` tuple returned by the callback itself
  """
  @spec with_lock(binary, (-> any), keyword) ::
          {:ok, any}
          | {:error, :lock_failed}
          | {:error, term}
          | {:callback_error, Exception.t()}
  def with_lock(path, fun, _opts \\ []) do
    case acquire_lock(path) do
      :ok ->
        try do
          {:ok, fun.()}
        rescue
          e -> {:callback_error, e}
        after
          release_lock(path)
        end

      {:error, _reason} ->
        {:error, :lock_failed}
    end
  end

  @doc """
  Release the lock directory created for `path`.
  """
  @spec release_lock(path :: binary) :: :ok
  def release_lock(path) do
    lock_dir = path <> ".lock"
    stale_name = "#{lock_dir}.released.#{:erlang.unique_integer([:positive])}"

    case File.rename(lock_dir, stale_name) do
      :ok ->
        File.rm_rf(stale_name)
        :ok

      {:error, :enoent} ->
        :ok

      {:error, _} ->
        File.rm_rf(lock_dir)
        :ok
    end
  end

  @doc """
  Acquire a lock directory alongside the file at `path`.

  Returns `:ok` on success, `{:error, reason}` on failure.
  """
  @spec acquire_lock(path :: binary) :: :ok | {:error, term}
  def acquire_lock(path) do
    lock_dir = path <> ".lock"
    do_acquire_lock(lock_dir, path, System.monotonic_time(:millisecond))
  end

  defp do_acquire_lock(lock_dir, path, start_time) do
    elapsed = System.monotonic_time(:millisecond) - start_time

    if elapsed >= @timeout_ms do
      {:error, {:timeout, path, elapsed}}
    else
      case File.mkdir(lock_dir) do
        :ok ->
          case write_owner_info(lock_dir) do
            :ok ->
              :ok

            {:retry} ->
              :timer.sleep(10)
              do_acquire_lock(lock_dir, path, System.monotonic_time(:millisecond))
          end

        {:error, :eexist} ->
          age_ms =
            case File.stat(lock_dir, time: :posix) do
              {:ok, %File.Stat{mtime: mtime}} when is_integer(mtime) ->
                now = System.system_time(:second)
                max(0, (now - mtime) * 1_000)

              _ ->
                @stale_ms + 1
            end

          if age_ms > @stale_ms do
            case attempt_stale_takeover(lock_dir) do
              :ok ->
                :ok

              :retry ->
                :timer.sleep(50)
                do_acquire_lock(lock_dir, path, start_time)

              {:error, reason} ->
                {:error, reason}
            end
          else
            :timer.sleep(50)
            do_acquire_lock(lock_dir, path, start_time)
          end

        {:error, reason} ->
          {:error, {:mkdir_failed, lock_dir, reason}}
      end
    end
  end

  @spec attempt_stale_takeover(binary()) :: :ok | :retry | {:error, term}
  defp attempt_stale_takeover(lock_dir) do
    temp_lock = "#{lock_dir}.tmp.#{:erlang.unique_integer([:positive])}"

    case File.mkdir(temp_lock) do
      :ok ->
        stale_name = "#{lock_dir}.stale.#{:erlang.unique_integer([:positive])}"

        case File.rename(lock_dir, stale_name) do
          :ok ->
            case File.rename(temp_lock, lock_dir) do
              :ok ->
                write_owner_info(lock_dir)

                Services.Globals.Spawn.spawn(fn ->
                  "#{lock_dir}.stale.*" |> Path.wildcard() |> Enum.each(&File.rm_rf/1)
                end)

                :ok

              {:error, _} ->
                File.rm_rf(temp_lock)
                :retry
            end

          {:error, :enoent} ->
            File.rm_rf(temp_lock)
            :retry

          {:error, reason} ->
            File.rm_rf(temp_lock)
            {:error, {:rename_failed, stale_name, reason}}
        end

      {:error, _} ->
        :retry
    end
  end

  defp write_owner_info(lock_dir) do
    owner_file = Path.join(lock_dir, "owner")

    owner_info =
      [
        "pid: #{inspect(self())}",
        "at:  #{DateTime.utc_now() |> DateTime.to_iso8601()}"
      ]
      |> Enum.join("\n")

    case File.write(owner_file, owner_info) do
      :ok -> :ok
      {:error, :enoent} -> {:retry}
      {:error, reason} -> {:error, {:write_failed, owner_file, reason}}
    end
  end
end
