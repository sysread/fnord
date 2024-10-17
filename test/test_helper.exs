orig_value = System.get_env("FNORD_DISABLE_ANIMATION", "")
System.put_env("FNORD_DISABLE_ANIMATION", "true")

ExUnit.start()

ExUnit.after_suite(fn _ ->
  System.put_env("FNORD_DISABLE_ANIMATION", orig_value)
end)
