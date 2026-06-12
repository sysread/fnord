defmodule UI.Queue.Test do
  # Sync: capture_all captures the VM-global :stderr device, so output from
  # concurrently running tests would cross-bleed into the captures.
  use Fnord.TestCase, async: false

  defmodule LogCaptureHandler do
    @moduledoc false

    @spec log(:logger.log_event(), map()) :: :ok
    def log(log_event, %{test_pid: pid}),
      do:
        (
          send(pid, {:captured_log, log_event})
          :ok
        )
  end

  describe "interaction_token/1 and interact/3 lifecycle" do
    test "token is nil outside, non-nil inside interact, then nil again" do
      # Before any interaction, token should be nil
      assert UI.Queue.interaction_token() == nil

      # During interact, a token should be available
      {:ok, inner_token} =
        UI.Queue.interact(fn ->
          tok = UI.Queue.interaction_token()
          assert is_reference(tok)
          tok
        end)

      # The returned token should be a reference
      assert is_reference(inner_token)

      # After interaction, token should be nil again
      assert UI.Queue.interaction_token() == nil
    end
  end

  describe "run_from_task/2 preserves parent context, run_from_genserver/2 does not" do
    test "run_from_task preserves parent context and run_from_genserver creates a fresh context" do
      caller = self()

      UI.Queue.interact(fn ->
        parent_token = UI.Queue.interaction_token()

        # run_from_task should keep the same token
        task_token = UI.Queue.run_from_task(fn -> UI.Queue.interaction_token() end)
        send(caller, {:task, task_token, parent_token})

        # run_from_genserver should generate a fresh token
        gen_token = UI.Queue.run_from_genserver(fn -> UI.Queue.interaction_token() end)
        send(caller, {:gen, gen_token, parent_token})

        :ok
      end)

      # Assert run_from_task token equals parent
      assert_receive {:task, task_token, parent_token}, 100
      assert task_token == parent_token

      # Assert run_from_genserver token is fresh
      assert_receive {:gen, gen_token, parent_token2}, 100
      assert is_reference(gen_token)
      refute gen_token == parent_token2
    end
  end

  describe "spawn_bound/2 inherits the current token into a new process" do
    test "spawn_bound within interact preserves the token" do
      caller = self()

      UI.Queue.interact(fn ->
        parent_token = UI.Queue.interaction_token()

        # spawn_bound should inherit the interaction token
        UI.Queue.spawn_bound(fn ->
          send(caller, {:spawned, UI.Queue.interaction_token()})
        end)

        # send back the parent token for comparison
        send(caller, {:parent, parent_token})
      end)

      # Receive tokens and assert they match
      assert_receive {:spawned, spawn_token}, 100
      assert_receive {:parent, parent_token}, 100
      assert spawn_token == parent_token
    end
  end

  describe "priority ordering: queued interacts (hq) run before queued puts/log (q)" do
    test "an interact enqueued while busy runs before a puts enqueued at the same time" do
      parent = self()

      # Block the queue with an initial interact
      _blocker =
        Services.Globals.Spawn.spawn(fn ->
          UI.Queue.interact(fn ->
            send(parent, :blocker_started)

            receive do
              :go -> :ok
            after
              500 -> flunk("blocker did not receive :go")
            end
          end)
        end)

      assert_receive :blocker_started, 100

      # Enqueue another interact (high priority)
      Services.Globals.Spawn.spawn(fn ->
        UI.Queue.interact(fn -> send(parent, :after_interact) end)
      end)

      # Enqueue a puts (normal priority)
      Services.Globals.Spawn.spawn(fn ->
        UI.Queue.puts(UI.Queue.instance(), :stdout, "dummy")
        send(parent, :after_puts)
      end)

      # Release the blocker
      send(UI.Queue.instance(), :go)

      # Ensure interact runs before puts
      assert_receive :after_interact, 200
      assert_receive :after_puts, 200
    end
  end

  describe "nested interact via the queued path" do
    # The queued interact handler runs the fun inside the UI.Queue process
    # itself, tokening the queue's own pdict - so a nested interact takes the
    # in-context branch FROM the queue process. That branch must not
    # GenServer.call back into the queue (:calling_self). This is the
    # `fnord frobs call` shape: Cmd.Frobs.call_frob wraps the whole
    # parameter-prompt loop in UI.interact, and each per-parameter
    # choose/prompt is itself an interact.
    test "an interact nested inside a queued interact runs inline" do
      result =
        UI.Queue.interact(fn ->
          {:ok, inner} = UI.Queue.interact(fn -> :nested_ok end)
          inner
        end)

      assert result == {:ok, :nested_ok}
    end
  end

  describe "error handling in interact/3" do
    test "if the fun raises, interact returns {:error, {exception, stack_trace}}" do
      {:error, {exc, stack}} =
        UI.Queue.interact(fn ->
          raise RuntimeError, "boom"
        end)

      assert %RuntimeError{message: "boom"} = exc
      assert is_list(stack)
    end
  end

  describe "log/3 with invalid UTF-8 binary" do
    test "does not crash on invalid UTF-8 and returns :ok" do
      invalid = <<0xFF, 0xFE, 0xFA>>

      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          result = UI.Queue.log(UI.Queue.instance(), :error, invalid)
          assert result == :ok
        end)

      assert is_binary(output)
    end
  end

  describe "puts/4 with Owl.Data lists" do
    test "puts/4 accepts Owl.Data lists with wide unicode characters" do
      owl_data = ["Wide: ", Owl.Data.tag("世界", :green), " ", Owl.Data.tag("🙂", :green), "\n"]

      # The queue's exec runs Owl.IO.puts in the queue process, which writes
      # to the queue's group leader. Start a fresh queue *inside* capture_io
      # so it inherits the capture device and the real rendered output is
      # assertable. (start_link re-registers the tree's instance; this test
      # ends immediately after, so nothing downstream notices.)
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          {:ok, queue} = UI.Queue.start_link([])

          result =
            UI.Queue.interact(queue, fn ->
              UI.Queue.puts(queue, :stdio, owl_data)
            end)

          assert result == {:ok, :ok}
        end)

      assert output =~ "世界"
      assert output =~ "🙂"
    end
  end

  describe "log buffering during fast-path interact (in-context branch)" do
    # The fast-path is taken when the caller is already in a UI context, e.g.
    # via Services.Approvals.handle_call -> UI.Queue.run_from_genserver -> ...
    # -> UI.choose -> UI.Queue.interact. Without the pause coordination, the
    # GenServer keeps processing {:log, ...} calls from other processes
    # (memory_indexer, background_indexer, etc.) and scribbles over the
    # active prompt. This regression test exercises the exact scenario.
    test "log calls from other processes buffer while a fast-path interact holds the prompt" do
      caller = self()

      assert :ok =
               :logger.add_handler(:ui_queue_test_fastpath, LogCaptureHandler, %{
                 test_pid: caller,
                 level: :all
               })

      on_exit(fn ->
        try do
          :logger.remove_handler(:ui_queue_test_fastpath)
        rescue
          _ -> :ok
        end
      end)

      # Process A simulates the Approvals path: enters a fresh context (so
      # in_ctx? returns true), then calls interact - taking the fast path.
      # A's interact runs IN A's process (not in UI.Queue's), so :release
      # must be sent to A, not UI.Queue.
      a_pid =
        Services.Globals.Spawn.spawn(fn ->
          UI.Queue.run_from_genserver(fn ->
            UI.Queue.interact(fn ->
              send(caller, :prompt_open)

              receive do
                :release -> :ok
              end
            end)
          end)

          send(caller, :a_done)
        end)

      assert_receive :prompt_open, 500

      # Process B logs while A holds the prompt. Without the fix, this would
      # immediately emit. With the fix, it buffers until A releases.
      # Use :error so the OTP Logger primary-level filter (default :notice
      # outside production) doesn't drop the event before our handler sees it.
      Services.Globals.Spawn.spawn(fn ->
        :ok = UI.Queue.log(UI.Queue.instance(), :error, "should-be-buffered")
        send(caller, :log_returned)
      end)

      assert_receive :log_returned, 1_000
      refute_receive {:captured_log, _}, 200

      # Release A's interact; the buffered log should now flush.
      send(a_pid, :release)
      assert_receive :a_done, 1_000

      assert_receive {:captured_log, event}, 1_000
      assert inspect(event) =~ "should-be-buffered"
    end

    test "pause/unpause counter: two concurrent pausers, only the last unpause flushes" do
      caller = self()

      assert :ok =
               :logger.add_handler(:ui_queue_test_counter, LogCaptureHandler, %{
                 test_pid: caller,
                 level: :all
               })

      on_exit(fn ->
        try do
          :logger.remove_handler(:ui_queue_test_counter)
        rescue
          _ -> :ok
        end
      end)

      # Two independent pauses.
      :ok = UI.Queue.pause_logs()
      :ok = UI.Queue.pause_logs()

      # Log a thing - should buffer. :error to clear OTP's default
      # primary-level :notice filter in test runs.
      :ok = UI.Queue.log(UI.Queue.instance(), :error, "counter-test")
      refute_receive {:captured_log, _}, 150

      # First unpause - depth still > 0; nothing should flush.
      :ok = UI.Queue.unpause_logs()
      refute_receive {:captured_log, _}, 150

      # Second unpause - depth reaches 0; buffer flushes.
      :ok = UI.Queue.unpause_logs()
      assert_receive {:captured_log, event}, 1_000
      assert inspect(event) =~ "counter-test"
    end
  end

  describe "log buffering during interact" do
    test "log events are buffered until interact completes" do
      caller = self()
      # Install temporary logger handler
      assert :ok =
               :logger.add_handler(:ui_queue_test_capture, LogCaptureHandler, %{
                 test_pid: caller,
                 level: :all
               })

      assert {:ok, _cfg} = :logger.get_handler_config(:ui_queue_test_capture)

      on_exit(fn ->
        try do
          :logger.remove_handler(:ui_queue_test_capture)
        rescue
          _ -> :ok
        end
      end)

      # Block the queue with an initial interact
      _blocker =
        Services.Globals.Spawn.spawn(fn ->
          UI.Queue.interact(fn ->
            send(caller, :interact_started)

            receive do
              :release -> :ok
            end
          end)
        end)

      assert_receive :interact_started, 500

      # Attempt to log during interact
      Services.Globals.Spawn.spawn(fn ->
        send(caller, {:log_start, self()})
        Process.delete({:uiq_ctx, UI.Queue.instance()})
        send(caller, {:token_deleted, self()})
        result = UI.Queue.log(UI.Queue.instance(), :error, "buffer-me")
        send(caller, {:log_returned, result})
      end)

      assert_receive {:log_start, _pid}, 500
      assert_receive {:token_deleted, _pid}, 500
      refute_receive {:log_returned, :ok}, 200
      refute_receive {:captured_log, _}, 200

      # Release the interact
      send(UI.Queue.instance(), :release)

      assert_receive {:log_returned, :ok}, 1_000

      # Assert log event is received after release
      receive do
        {:captured_log, log_event} ->
          assert inspect(log_event) =~ "buffer-me"
      after
        1_000 ->
          case :logger.get_handler_config(:ui_queue_test_capture) do
            {:ok, cfg} ->
              flunk("No log event received, handler config: #{inspect(cfg)}")

            {:error, {:not_found, _}} ->
              flunk("No log event received and handler not found")
          end
      end
    end
  end
end
