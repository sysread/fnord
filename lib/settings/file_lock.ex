defmodule Settings.FileLock do
  @moduledoc """
  Cross-process filesystem lock helpers for settings.json. Uses `mkdir` for the
  lock with atomic stale lock takeover.

  Strategy:
  1. Attempt to create a lock dir with a `.lock` suffix.
     -> Success: we own the lock, GOTO 4
     -> Failure: GOTO 2
  2. If the lock dir already exists, check whether it's age is younger than the `:stale_ms` threshold.
     -> Younger: sleep briefly and GOTO 1
     -> Older: GOTO 3
  3. Attempt to take over the stale lock dir:
     a) Create a unique temp dir
     b) Rename the stale lock to a .stale.* name
     c) Rename temp dir to become the lock dir
     -> Success at all steps: we own the lock, GOTO 4
     -> Failure at any step: sleep briefly and GOTO 1
  4. Write a file named `owner` in the lock dir with our PID and timestamp.

  If at any time we exceed the `:timeout_ms` threshold, we raise an error.
  """

  @timeout_ms 10_000
  @stale_ms 120_000

  @doc """
  Release the lock directory created for `path`.
  """
  @spec release_lock!(path :: binary) :: :ok
  def release_lock!(path) do
    lock_dir = path <> ".lock"
    stale_name = "#{lock_dir}.released.#{:erlang.unique_integer([:positive])}"

    case File.rename(lock_dir, stale_name) do
      :ok ->
        # Safe to delete now; lock_dir path is no longer used by this release
        File.rm_rf(stale_name)
        :ok

      {:error, :enoent} ->
        # Already gone; nothing to do
        :ok

      {:error, _} ->
        # Fallback; best-effort cleanup
        File.rm_rf(lock_dir)
        :ok
    end
  end

  @doc """
  Acquire a lock directory alongside the JSON file at `path`. Blocks up to
  `opts[:timeout_ms]` (default 10_000ms), treats locks older than
  `opts[:stale_ms]` (default 120_000ms) as stale and reclaims them.
  """
  @spec acquire_lock!(path :: binary) :: :ok
  def acquire_lock!(path) do
    lock_dir = path <> ".lock"
    do_acquire_lock(lock_dir, path, System.monotonic_time(:millisecond))
  end

  @spec do_acquire_lock(
          lock_dir :: binary(),
          path :: binary(),
          start_time :: non_neg_integer()
        ) :: :ok
  defp do_acquire_lock(lock_dir, path, start_time) do
    # If we've been trying for too long, give up and raise an error.
    elapsed = System.monotonic_time(:millisecond) - start_time

    if elapsed >= @timeout_ms do
      raise """
      Timeout acquiring file lock for #{path}.
      Waited #{elapsed}ms (timeout is #{@timeout_ms}ms).
      """
    end

    # Attempt to create the lock directory.
    case File.mkdir(lock_dir) do
      :ok ->
        # The lock directory did not exist and we successfully created it.
        # Ergo, we own the lock.
        case write_owner_info(lock_dir) do
          :ok ->
            :ok

          {:retry} ->
            # Another process deleted the dir out from under us; start over.
            # But don't count this against our timeout.
            :timer.sleep(10)
            do_acquire_lock(lock_dir, path, System.monotonic_time(:millisecond))
        end

        :ok

      {:error, :eexist} ->
        # The lock directory already exists. But is it stale? It may have been
        # left behind by a crashed process. Check its age.
        age_ms =
          case File.stat(lock_dir, time: :posix) do
            {:ok, %File.Stat{mtime: mtime}} when is_integer(mtime) ->
              now = System.system_time(:second)
              # Guard against clock skew going negative
              max(0, (now - mtime) * 1_000)

            _ ->
              @stale_ms + 1
          end

        if age_ms > @stale_ms do
          # The lock is stale, try to take it over.
          case attempt_stale_takeover(lock_dir) do
            :ok ->
              # We successfully took over the stale lock
              UI.debug("Took over stale lock", "#{path} -> #{age_ms} ms)")
              :ok

            :retry ->
              # The take-over failed, possibly because another process took
              # over the stale lock before we could. Retry until the timeout is
              # reached.
              :timer.sleep(50)
              do_acquire_lock(lock_dir, path, start_time)
          end
        else
          # The lock is not stale, wait and retry
          :timer.sleep(50)
          do_acquire_lock(lock_dir, path, start_time)
        end

      # Other error creating the lock directory
      {:error, reason} ->
        raise "Unable to create lock directory #{lock_dir}: #{inspect(reason)}"
    end
  end

  # ----------------------------------------------------------------------------
  # Atomically take over a stale lock directory. Returns :ok if takeover
  # succeeded, :retry if it failed.
  # ----------------------------------------------------------------------------
  @spec attempt_stale_takeover(binary()) :: :ok | :retry
  defp attempt_stale_takeover(lock_dir) do
    temp_lock = "#{lock_dir}.tmp.#{:erlang.unique_integer([:positive])}"

    case File.mkdir(temp_lock) do
      :ok ->
        # We have our temp lock, try to atomically replace the stale lock
        stale_name = "#{lock_dir}.stale.#{:erlang.unique_integer([:positive])}"

        case File.rename(lock_dir, stale_name) do
          :ok ->
            # Successfully moved stale lock out of the way
            case File.rename(temp_lock, lock_dir) do
              :ok ->
                # We now own the lock!
                write_owner_info(lock_dir)

                # Clean up any other stale lock dirs we created in the
                # background while attempting takeover.
                Services.Globals.Spawn.spawn(fn ->
                  "#{lock_dir}.stale.*"
                  |> Path.wildcard()
                  |> Enum.each(&File.rm_rf/1)
                end)

                :ok

              {:error, _} ->
                # Someone else got there first. Clean up and retry.
                File.rm_rf(temp_lock)
                :retry
            end

          {:error, :enoent} ->
            # Stale lock disappeared (most likely someone else took it)
            File.rm_rf(temp_lock)
            :retry

          {:error, _} ->
            # Can't rename (permissions?), clean up and retry
            File.rm_rf(temp_lock)
            :retry
        end

      {:error, _} ->
        # Can't create temp lock for whatever reason, retry
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
      :ok ->
        :ok

      # dir was removed; caller should re-attempt acquire
      {:error, :enoent} ->
        {:retry}

      {:error, reason} ->
        raise File.Error, reason: reason, action: "write", path: owner_file
    end
  end
end
