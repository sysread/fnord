defmodule Settings.FrobsTest do
  use Fnord.TestCase, async: false

  @moduletag :capture_log

  describe "Settings.Frobs basic behavior" do
    test "global enable/disable and idempotence" do
      # start with clean slate
      Settings.update(Settings.new(), "frobs", fn _ -> [] end, [])

      refute Settings.Frobs.enabled?("http_get")
      :ok = Settings.Frobs.enable(:global, "http_get")
      assert Settings.Frobs.enabled?("http_get")

      # idempotent
      :ok = Settings.Frobs.enable(:global, "http_get")
      assert Settings.Frobs.enabled?("http_get")

      :ok = Settings.Frobs.disable(:global, "http_get")
      refute Settings.Frobs.enabled?("http_get")
    end

    test "project enable/disable and union semantics" do
      # clean
      Settings.update(Settings.new(), "frobs", fn _ -> [] end, [])

      # select a project
      Settings.set_project("acme")
      s = Settings.new()

      Settings.set_project_data(
        s,
        "acme",
        Map.put(Settings.get_project_data(s, "acme") || %{}, "frobs", [])
      )

      refute Settings.Frobs.enabled?("acme_deploy")

      :ok = Settings.Frobs.enable(:project, "acme_deploy")
      assert Settings.Frobs.enabled?("acme_deploy")

      # union: add global and ensure both present
      :ok = Settings.Frobs.enable(:global, "global_tool")
      eff = Settings.Frobs.effective_enabled()
      assert MapSet.member?(eff, "acme_deploy")
      assert MapSet.member?(eff, "global_tool")

      # disable project tool
      :ok = Settings.Frobs.disable(:project, "acme_deploy")
      refute MapSet.member?(Settings.Frobs.effective_enabled(), "acme_deploy")
      assert MapSet.member?(Settings.Frobs.effective_enabled(), "global_tool")
    end

    test "explicit project scope" do
      Settings.set_project("alpha")
      s1 = Settings.new()

      Settings.set_project_data(
        s1,
        "alpha",
        Map.put(Settings.get_project_data(s1, "alpha") || %{}, "frobs", [])
      )

      s2 = Settings.new()

      Settings.set_project_data(
        s2,
        "beta",
        Map.put(Settings.get_project_data(s2, "beta") || %{}, "frobs", [])
      )

      :ok = Settings.Frobs.enable({:project, "beta"}, "beta_tool")
      refute Settings.Frobs.enabled?("beta_tool")
      assert ["beta_tool"] == Settings.Frobs.list({:project, "beta"})
    end

    test "prune_missing!/1 removes missing frobs and returns retained names" do
      # clean slate for frobs
      Settings.update(Settings.new(), "frobs", fn _ -> [] end, [])

      # global frobs
      :ok = Settings.Frobs.enable(:global, "gf1")
      :ok = Settings.Frobs.enable(:global, "gf2")

      # project frobs
      Settings.set_project("proj1")
      s = Settings.new()

      Settings.set_project_data(
        s,
        "proj1",
        Map.put(Settings.get_project_data(s, "proj1") || %{}, "frobs", [])
      )

      :ok = Settings.Frobs.enable(:project, "pf1")
      :ok = Settings.Frobs.enable(:project, "pf2")

      # prune missing, retaining only gf1 and pf2
      retained = Settings.Frobs.prune_missing!(["gf1", "pf2"])
      assert ["gf1", "pf2"] == retained

      # ensure pruned accordingly
      eff = Settings.Frobs.effective_enabled()
      refute MapSet.member?(eff, "gf2")
      refute MapSet.member?(eff, "pf1")
      assert MapSet.member?(eff, "gf1")
      assert MapSet.member?(eff, "pf2")
    end
  end

  describe "Frobs migration heuristic" do
    test "migrates frobs from legacy tool directories" do
      # clean slate for frobs
      Settings.update(Settings.new(), "frobs", fn _ -> [] end, [])

      # setup legacy frob directory
      # setup legacy frob via create and legacy directory
      {:ok, frob} = Frobs.create("migrated_frob")
      # remove any existing frob home
      # remove 'available' to skip dependency checks
      File.rm_rf!(Path.join(frob.home, "available"))
      # write legacy registry.json
      File.write!(
        Path.join(frob.home, "registry.json"),
        Jason.encode!(%{"projects" => ["proj1", "proj2"]})
      )

      # prepare proj1 with empty 'frobs' key
      Settings.set_project("proj1")
      s1 = Settings.new()

      Settings.set_project_data(
        s1,
        "proj1",
        Map.put(Settings.get_project_data(s1, "proj1") || %{}, "frobs", [])
      )

      # prepare proj2 without 'frobs' key
      Settings.set_project("proj2")
      _s2 = Settings.new()

      Application.put_env(:fnord, :frobs_migrated_runtime, false)

      # trigger migration via listing
      Frobs.Migrate.maybe_migrate_registry_to_settings()
      # assert proj2 has migrated frob but proj1 does not
      assert ["migrated_frob"] == Settings.Frobs.list({:project, "proj2"})
      refute "migrated_frob" in Settings.Frobs.list({:project, "proj1"})

      # ensure no top-level frobs_migrated key in settings
      assert nil == Settings.get(Settings.new(), "frobs_migrated", nil)
    end
  end

  test "global flag in legacy registry enables globally" do
    # clean slate for frobs
    Settings.update(Settings.new(), "frobs", fn _ -> [] end, [])

    # setup legacy frob directory
    {:ok, frob} = Frobs.create("glob_migrated")
    # remove any existing frob home
    File.rm_rf!(Path.join(frob.home, "available"))
    # write legacy registry.json with global flag
    File.write!(
      Path.join(frob.home, "registry.json"),
      Jason.encode!(%{"global" => true})
    )

    # reset migration flag
    Application.put_env(:fnord, :frobs_migrated_runtime, false)

    # trigger migration via listing
    Frobs.Migrate.maybe_migrate_registry_to_settings()
    # assert global enabled
    assert Settings.Frobs.enabled?("glob_migrated")
    # ensure no top-level frobs_migrated key in settings
    assert nil == Settings.get(Settings.new(), "frobs_migrated", nil)
  end
end
