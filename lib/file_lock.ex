defmodule FileLock do
  @moduledoc """
  Cross-process filesystem lock helpers for arbitrary files. Uses a lock dir
  with atomic stale lock takeover.

  API is intentionally small:
  - acquire_lock(path)
  - release_lock(path)
  - with_lock(path, fun, opts \\\\ [])
  """

  @stale_ms 120_000
  @base_retry_ms 10
  @max_retry_ms 250

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
    # Ensure the parent directory exists so callers can lock against paths
    # whose target hasn't been created yet (e.g. a new index entry directory
    # that the worker is about to create inside the lock). Ignore errors -
    # the subsequent mkdir on the lock dir will surface any real issue.
    _ = File.mkdir_p(Path.dirname(lock_dir))
    do_acquire_lock(lock_dir, path, System.monotonic_time(:millisecond), 0)
  end

  defp do_acquire_lock(lock_dir, path, start_time, attempt) do
    elapsed = System.monotonic_time(:millisecond) - start_time

    case timeout_remaining(path, elapsed) do
      :ok ->
        case File.mkdir(lock_dir) do
          :ok ->
            handle_owner_write(lock_dir, path, start_time, attempt)

          {:error, :eexist} ->
            handle_existing_lock(lock_dir, path, start_time, attempt)

          {:error, reason} ->
            {:error, {:mkdir_failed, lock_dir, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp timeout_remaining(path, elapsed) do
    case elapsed >= lock_timeout_ms() do
      true -> {:error, {:timeout, path, elapsed}}
      false -> :ok
    end
  end

  defp handle_owner_write(lock_dir, path, start_time, attempt) do
    case write_owner_info(lock_dir) do
      :ok ->
        :ok

      {:retry} ->
        retry_lock(lock_dir, path, start_time, attempt + 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_existing_lock(lock_dir, path, start_time, attempt) do
    case stale_lock?(lock_dir) do
      true ->
        handle_stale_takeover(lock_dir, path, start_time, attempt)

      false ->
        retry_lock(lock_dir, path, start_time, attempt + 1)
    end
  end

  defp handle_stale_takeover(lock_dir, path, start_time, attempt) do
    case attempt_stale_takeover(lock_dir) do
      :ok ->
        :ok

      :retry ->
        retry_lock(lock_dir, path, start_time, attempt + 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp retry_lock(lock_dir, path, start_time, attempt) do
    elapsed = System.monotonic_time(:millisecond) - start_time

    case timeout_remaining(path, elapsed) do
      :ok ->
        Process.sleep(min(retry_delay_ms(attempt), lock_timeout_ms() - elapsed))
        do_acquire_lock(lock_dir, path, start_time, attempt)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stale_lock?(lock_dir) do
    stale_lock_age_ms(lock_dir) > @stale_ms
  end

  defp stale_lock_age_ms(lock_dir) do
    case File.stat(lock_dir, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} when is_integer(mtime) ->
        now = System.system_time(:second)
        max(0, (now - mtime) * 1_000)

      _ ->
        @stale_ms + 1
    end
  end

  defp lock_timeout_ms, do: 30_000

  defp retry_delay_ms(attempt) do
    attempt
    |> retry_window_ms()
    |> add_retry_jitter(attempt)
  end

  defp retry_window_ms(attempt) do
    growth = min(attempt, 4)
    delay = @base_retry_ms * trunc(:math.pow(2, growth))
    min(delay, @max_retry_ms)
  end

  defp add_retry_jitter(delay_ms, attempt) do
    jitter = :erlang.phash2({self(), attempt, System.monotonic_time()}, delay_ms + 1)
    min(delay_ms + jitter, @max_retry_ms)
  end

  @doc """
  Return the bounded retry delay used between lock acquisition attempts.

  This supports the contention policy exercised by the integration tests.
  """
  @spec retry_delay_ms_for_test(non_neg_integer()) :: non_neg_integer()
  def retry_delay_ms_for_test(attempt) do
    retry_delay_ms(attempt)
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
                case write_owner_info(lock_dir) do
                  :ok ->
                    Services.Globals.Spawn.spawn(fn ->
                      "#{lock_dir}.stale.*" |> Path.wildcard() |> Enum.each(&File.rm_rf/1)
                    end)

                    :ok

                  {:retry} ->
                    File.rm_rf(lock_dir)
                    :retry

                  {:error, reason} ->
                    File.rm_rf(lock_dir)
                    {:error, reason}
                end

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

    # OS pid is the useful identifier here - BEAM pids are ephemeral to a
    # given VM and meaningless to a human looking at a stale lock.
    owner_info =
      [
        "os_pid: #{System.pid()}",
        "beam_pid: #{inspect(self())}",
        "at: #{DateTime.utc_now() |> DateTime.to_iso8601()}"
      ]
      |> Enum.join("\n")

    case File.write(owner_file, owner_info) do
      :ok -> :ok
      {:error, :enoent} -> {:retry}
      {:error, reason} -> {:error, {:write_failed, owner_file, reason}}
    end
  end

  @doc """
  Returns a map describing the current holder of the lock at `path`, or `nil`
  if no lock exists. Useful when reporting lock contention to the user.

  Keys: "os_pid", "beam_pid", "at" - exactly the fields written by
  `write_owner_info/1`, parsed as a flat string map. May be empty if the
  owner file is missing or malformed (e.g. the directory exists but the
  owner file was never written, or was written in an older format).
  """
  @spec read_owner_info(path :: binary) :: map | nil
  def read_owner_info(path) do
    owner_file = Path.join(path <> ".lock", "owner")

    case File.read(owner_file) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.reduce(%{}, fn line, acc ->
          case String.split(line, ":", parts: 2) do
            [k, v] -> Map.put(acc, String.trim(k), String.trim(v))
            _ -> acc
          end
        end)

      {:error, _} ->
        nil
    end
  end
end
