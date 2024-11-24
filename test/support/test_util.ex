defmodule TestUtil do
  defmacro setup_args(args) do
    quote do
      setup do
        # Save the current environment settings for the application
        original_env = Application.get_all_env(:fnord)

        # Set the new key-value pairs in the environment
        unquote(args)
        |> Enum.each(fn {key, val} ->
          Application.put_env(:fnord, key, val)
        end)

        # Restore the original environment settings on exit
        on_exit(fn ->
          Application.put_all_env(fnord: original_env)
        end)

        # Return :ok to indicate a successful setup
        :ok
      end
    end
  end
end
