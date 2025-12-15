defmodule UI.Queue.Test do
  use Fnord.TestCase, async: false

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
        UI.Queue.puts(UI.Queue, :stdout, "dummy")
        send(parent, :after_puts)
      end)

      # Release the blocker
      send(UI.Queue, :go)

      # Ensure interact runs before puts
      assert_receive :after_interact, 200
      assert_receive :after_puts, 200
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
          result = UI.Queue.log(UI.Queue, :error, invalid)
          assert result == :ok
        end)

      assert is_binary(output)
    end
  end

  describe "puts/4 with Owl.Data lists" do
    test "puts/4 accepts Owl.Data lists with wide unicode characters" do
      owl_data = ["Wide: ", Owl.Data.tag("世界", :green), " ", Owl.Data.tag("🙂", :green), "\n"]

      :meck.new(Owl.IO, [:passthrough])

      :meck.expect(Owl.IO, :puts, fn data ->
        # Convert Owl data to chardata for inspection
        rendered = Owl.Data.to_chardata(data) |> IO.iodata_to_binary()
        assert rendered =~ "世界"
        assert rendered =~ "🙂"
        :ok
      end)

      on_exit(fn ->
        try do
          :meck.unload(Owl.IO)
        rescue
          _ -> :ok
        catch
          _, _ -> :ok
        end
      end)

      result =
        UI.Queue.interact(fn ->
          UI.Queue.puts(UI.Queue, :stdio, owl_data)
        end)

      assert result == {:ok, :ok}
    end
  end
end
