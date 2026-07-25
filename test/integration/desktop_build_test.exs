defmodule Rekindle.DesktopBuildTest do
  use ExUnit.Case, async: false

  setup do
    previous = Application.get_env(:rekindle_desktop_build_test, Rekindle)

    root =
      Path.join(
        System.tmp_dir!(),
        "rekindle-desktop-build-#{System.pid()}-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(Path.join(root, "client/src/bin"))
    File.write!(Path.join(root, "client/Cargo.toml"), "[package]\nname = \"fixture_ui\"\n")
    File.write!(Path.join(root, "client/src/bin/desktop.rs"), "fn main() {}\n")

    Application.put_env(:rekindle_desktop_build_test, Rekindle,
      integration: :gpui,
      targets: [desktop: []]
    )

    on_exit(fn ->
      File.rm_rf!(root)

      if previous do
        Application.put_env(:rekindle_desktop_build_test, Rekindle, previous)
      else
        Application.delete_env(:rekindle_desktop_build_test, Rekindle)
      end
    end)

    %{root: root}
  end

  test "publishes an executable without launching it", %{root: root} do
    tools = fake_tools(root, executable?: true)

    assert {:ok, %Rekindle.Build.Result{} = result} = build(root, tools)
    assert result.target == :desktop
    assert result.profile == :dev
    assert result.metadata.rust_target == tools.target
    refute File.exists?(tools.launched)

    generation = result.metadata.generation
    generation_root = Path.dirname(result.artifact)

    assert generation =~ ~r/^[0-9a-f]{64}$/

    assert generation_root ==
             Path.join([root, ".rekindle", "dev", "desktop", tools.target, generation])

    assert executable?(result.artifact)

    manifest = result.metadata.manifest |> File.read!() |> Jason.decode!()
    assert manifest["generation"] == generation
    assert manifest["target"] == tools.target
    assert manifest["package"] == "fixture_ui"
    assert manifest["binary"] == "desktop"
    assert manifest["integration"] == "gpui"
    assert manifest["executable"] == "desktop"
    assert manifest["sha256"] == sha256(File.read!(result.artifact))

    refute File.exists?(Path.join(root, ".rekindle/dev/desktop-current.json"))
    refute File.exists?(Path.join(root, ".rekindle/dev/desktop-last-running.json"))
    assert Path.wildcard(Path.join(root, ".rekindle/tmp/desktop/*")) == []

    assert {:ok, second} = build(root, tools)
    assert second.artifact == result.artifact
    refute File.exists?(tools.launched)
  end

  test "rejects linked project state ancestors without external writes", %{root: root} do
    tools = fake_tools(root, executable?: true)
    external = Path.join(root, "external-state")
    File.mkdir!(external)
    File.write!(Path.join(external, "sentinel"), "unchanged")
    state = Path.join(root, ".rekindle")
    File.ln_s!(external, state)

    assert {:error, %Rekindle.Desktop.Error{kind: :mkdir, message: message}} =
             build(root, tools)

    assert message =~ "project-owned path"
    refute File.exists?(Path.join(external, "tmp"))
    assert File.read!(Path.join(external, "sentinel")) == "unchanged"

    File.rm!(state)
    assert {:ok, selected} = build(root, tools)
    artifact = File.read!(selected.artifact)
    manifest = File.read!(selected.metadata.manifest)

    tmp = Path.join(state, "tmp")
    File.rename!(tmp, Path.join(state, "tmp-owned"))
    File.ln_s!(external, tmp)

    assert {:error, %Rekindle.Desktop.Error{kind: :mkdir}} = build(root, tools)
    assert File.read!(selected.artifact) == artifact
    assert File.read!(selected.metadata.manifest) == manifest
    refute File.exists?(Path.join(external, "desktop"))
    assert File.read!(Path.join(external, "sentinel")) == "unchanged"
  end

  test "publishes a content-named desktop release without launching it", %{root: root} do
    tools = fake_tools(root, executable?: true, marker: "first")
    target_root = Path.join([root, "dist", "rekindle", "desktop", tools.target])
    File.mkdir_p!(target_root)
    File.write!(Path.join(target_root, "keep.txt"), "application-owned")
    File.write!(Path.join(target_root, ".tmp-stale"), "incomplete")
    orphan = Path.join(target_root, "application-#{String.duplicate("a", 64)}")
    owned_directory = Path.join(target_root, "application-#{String.duplicate("b", 64)}")
    owned_symlink = Path.join(target_root, "application-#{String.duplicate("c", 64)}")
    File.write!(orphan, "unreferenced")
    File.mkdir!(owned_directory)
    File.ln_s!("keep.txt", owned_symlink)

    assert {:ok, result} = build(root, tools, profile: :release)
    assert result.profile == :release
    assert Path.dirname(result.artifact) == target_root
    assert Path.basename(result.artifact) == "application-#{sha256(File.read!(result.artifact))}"
    assert executable?(result.artifact)
    refute File.exists?(tools.launched)

    manifest = result.metadata.manifest |> File.read!() |> Jason.decode!()
    assert result.metadata.manifest == Path.join(target_root, "manifest.json")
    assert manifest["generation"] == result.metadata.generation
    assert manifest["target"] == tools.target
    assert manifest["integration"] == "gpui"
    assert manifest["sha256"] == sha256(File.read!(result.artifact))
    assert manifest["executable"] == Path.basename(result.artifact)
    assert :ok = Rekindle.Desktop.Manifest.validate_deployment(target_root, manifest)
    assert File.read!(Path.join(target_root, "keep.txt")) == "application-owned"
    refute File.exists?(Path.join(target_root, ".tmp-stale"))
    refute File.exists?(orphan)
    assert File.dir?(owned_directory)
    assert match?({:ok, %{type: :symlink}}, File.lstat(owned_symlink))

    previous = result.artifact
    tools = fake_tools(root, executable?: true, marker: "second")
    assert {:ok, replacement} = build(root, tools, profile: :release)
    refute replacement.artifact == previous
    refute File.exists?(previous)
    assert File.regular?(replacement.artifact)

    assert Path.wildcard(
             Path.join([
               root,
               ".rekindle/release/desktop",
               tools.target,
               "*",
               "manifest.json"
             ])
           ) != []

    refute File.exists?(Path.join(root, ".rekindle/release/desktop-current.json"))
    refute File.exists?(Path.join(root, ".rekindle/release/desktop-last-running.json"))
    refute File.exists?(Path.join(root, ".rekindle/dev/desktop-current.json"))
    refute File.exists?(tools.launched)
  end

  test "rejects linked and special desktop release source manifests before reading", %{
    root: root
  } do
    tools = fake_tools(root, executable?: true)
    assert {:ok, candidate} = build(root, tools)

    assert {:ok, project} =
             Rekindle.Config.load(:rekindle_desktop_build_test, project_root: root)

    manifest_path = candidate.metadata.manifest
    manifest = File.read!(manifest_path)
    release_root = Path.join([root, "dist", "rekindle", "desktop", tools.target])

    for kind <- [:symlink, :fifo] do
      backup = manifest_path <> ".source-backup"
      File.rename!(manifest_path, backup)

      case kind do
        :symlink -> File.ln_s!(backup, manifest_path)
        :fifo -> assert {"", 0} = System.cmd("mkfifo", [manifest_path])
      end

      try do
        assert {:ok, {:error, %Rekindle.Desktop.Error{kind: :invalid_manifest}}} =
                 bounded(fn ->
                   Rekindle.Desktop.Release.publish(project, %{candidate | profile: :release})
                 end)

        refute File.exists?(Path.join(release_root, "manifest.json"))
      after
        File.rm!(manifest_path)
        File.rename!(backup, manifest_path)
      end

      assert File.read!(manifest_path) == manifest
    end

    assert {:ok, published} =
             Rekindle.Desktop.Release.publish(project, %{candidate | profile: :release})

    assert published.metadata.generation =~ ~r/^[0-9a-f]{64}$/
    assert File.regular?(published.artifact)
    refute File.exists?(tools.launched)
  end

  test "rejects linked and special canonical desktop manifests before reuse", %{root: root} do
    tools = fake_tools(root, executable?: true)
    assert {:ok, selected} = build(root, tools)

    manifest_path = selected.metadata.manifest
    manifest = File.read!(manifest_path)
    artifact = File.read!(selected.artifact)

    for kind <- [:symlink, :fifo] do
      backup = manifest_path <> ".reuse-backup"
      File.rename!(manifest_path, backup)

      case kind do
        :symlink -> File.ln_s!(backup, manifest_path)
        :fifo -> assert {"", 0} = System.cmd("mkfifo", [manifest_path])
      end

      try do
        assert {:ok, {:error, %Rekindle.Desktop.Error{kind: :invalid_manifest}}} =
                 bounded(fn -> build(root, tools) end)

        assert File.read!(selected.artifact) == artifact
        refute File.exists?(Path.join(root, ".rekindle/dev/desktop-last-running.json"))
      after
        File.rm!(manifest_path)
        File.rename!(backup, manifest_path)
      end

      assert File.read!(manifest_path) == manifest
    end

    assert {:ok, reused} = build(root, tools)
    assert reused.metadata.generation == selected.metadata.generation
  end

  test "rejects linked and special desktop release destination ancestors", %{root: root} do
    selected_tools = fake_tools(root, executable?: true, marker: "selected")
    assert {:ok, selected} = build(root, selected_tools, profile: :release)
    selected_manifest = File.read!(selected.metadata.manifest)
    selected_executable = File.read!(selected.artifact)

    candidate_tools = fake_tools(root, executable?: true, marker: "candidate")
    assert {:ok, candidate} = build(root, candidate_tools)

    target_root = Path.dirname(selected.metadata.manifest)

    ancestors = [
      Path.join(root, "dist"),
      Path.join([root, "dist", "rekindle"]),
      Path.join([root, "dist", "rekindle", "desktop"]),
      target_root
    ]

    assert {:ok, project} =
             Rekindle.Config.load(:rekindle_desktop_build_test, project_root: root)

    for {ancestor, index} <- Enum.with_index(ancestors),
        kind <- [:symlink, :fifo] do
      backup = Path.join(root, "release-backup-#{index}-#{kind}")
      external = Path.join(root, "release-external-#{index}-#{kind}")
      File.mkdir!(external)
      File.write!(Path.join(external, "sentinel"), "unchanged")
      relative_target = Path.relative_to(target_root, ancestor)

      external_target =
        if relative_target == ".", do: external, else: Path.join(external, relative_target)

      File.mkdir_p!(external_target)
      protected = Path.join(external_target, "application-#{String.duplicate("a", 64)}")
      protected_temporary = Path.join(external_target, ".tmp-protected")
      File.write!(protected, "protected")
      File.write!(protected_temporary, "temporary")
      external_root_names = external |> File.ls!() |> Enum.sort()
      external_target_names = external_target |> File.ls!() |> Enum.sort()
      relative_manifest = Path.relative_to(selected.metadata.manifest, ancestor)
      relative_executable = Path.relative_to(selected.artifact, ancestor)
      File.rename!(ancestor, backup)

      case kind do
        :symlink -> File.ln_s!(external, ancestor)
        :fifo -> assert {"", 0} = System.cmd("mkfifo", [ancestor])
      end

      try do
        assert {:error, %Rekindle.Desktop.Error{kind: :mkdir}} =
                 Rekindle.Desktop.Release.publish(project, %{candidate | profile: :release})

        assert external |> File.ls!() |> Enum.sort() == external_root_names
        assert external_target |> File.ls!() |> Enum.sort() == external_target_names
        assert File.read!(Path.join(external, "sentinel")) == "unchanged"
        assert File.read!(protected) == "protected"
        assert File.read!(protected_temporary) == "temporary"
        refute File.exists?(Path.join(external_target, "manifest.json"))
        assert File.read!(Path.join(backup, relative_manifest)) == selected_manifest
        assert File.read!(Path.join(backup, relative_executable)) == selected_executable
      after
        File.rm!(ancestor)
        File.rename!(backup, ancestor)
      end
    end
  end

  test "preserves the prior release when the next manifest cannot be published", %{root: root} do
    project_root = root
    tools = fake_tools(root, executable?: true, marker: "first")
    assert {:ok, first} = build(root, tools, profile: :release)

    release_root = Path.dirname(first.artifact)
    manifest_path = Path.join(release_root, "manifest.json")
    manifest = File.read!(manifest_path)
    File.rm!(manifest_path)
    File.mkdir!(manifest_path)

    tools = fake_tools(project_root, executable?: true, marker: "second")

    publication =
      try do
        build(project_root, tools, profile: :release)
      after
        File.rmdir!(manifest_path)
        File.write!(manifest_path, manifest)
      end

    assert {:error, %Rekindle.Desktop.Error{kind: :manifest_write}} = publication
    assert File.regular?(first.artifact)
    assert File.read!(manifest_path) == manifest

    assert release_root
           |> File.ls!()
           |> Enum.filter(&String.starts_with?(&1, "application-")) == [
             Path.basename(first.artifact)
           ]
  end

  test "keeps the selected manifest unchanged when replacement is not writable", %{root: root} do
    tools = fake_tools(root, executable?: true, marker: "first")
    assert {:ok, first} = build(root, tools, profile: :release)

    release_root = Path.dirname(first.artifact)
    manifest_path = Path.join(release_root, "manifest.json")
    selected = File.read!(manifest_path)

    tools = fake_tools(root, executable?: true, marker: "second")
    assert {:ok, candidate} = build(root, tools)
    contents = File.read!(candidate.artifact)
    staged = Path.join(release_root, "application-#{sha256(contents)}")
    File.cp!(candidate.artifact, staged)
    File.chmod!(staged, 0o755)

    assert {:ok, project} =
             Rekindle.Config.load(:rekindle_desktop_build_test, project_root: root)

    File.chmod!(release_root, 0o555)

    publication =
      try do
        Rekindle.Desktop.Release.publish(project, %{candidate | profile: :release})
      after
        File.chmod!(release_root, 0o755)
      end

    assert {:error, %Rekindle.Desktop.Error{kind: :manifest_write}} = publication
    assert File.read!(manifest_path) == selected
    assert File.regular?(first.artifact)
  end

  test "serializes independent release publishers for the same target", %{root: root} do
    first_tools = fake_tools(root, executable?: true, marker: "first")
    assert {:ok, first} = build(root, first_tools)

    second_tools = fake_tools(root, executable?: true, marker: "second")
    assert {:ok, second} = build(root, second_tools)

    assert {:ok, project} =
             Rekindle.Config.load(:rekindle_desktop_build_test, project_root: root)

    release_root = Path.join([root, "dist", "rekindle", "desktop", first_tools.target])
    parent = self()

    holder =
      Task.async(fn ->
        Rekindle.Publication.with_lock(root, {:desktop_release, release_root}, fn ->
          send(parent, :publication_locked)

          receive do
            :release_publication -> :ok
          end
        end)
      end)

    assert_receive :publication_locked

    first_ready = Path.join(root, "first-publisher.ready")
    first_done = Path.join(root, "first-publisher.done")
    second_ready = Path.join(root, "second-publisher.ready")
    second_done = Path.join(root, "second-publisher.done")

    first_port = release_process(project, first, first_ready, first_done)
    second_port = release_process(project, second, second_ready, second_done)

    on_exit(fn ->
      if Port.info(first_port), do: Port.close(first_port)
      if Port.info(second_port), do: Port.close(second_port)
    end)

    wait_until(fn -> File.regular?(first_ready) and File.regular?(second_ready) end)
    refute File.exists?(first_done)
    refute File.exists?(second_done)

    send(holder.pid, :release_publication)
    assert :ok = Task.await(holder)

    assert_receive {^first_port, {:exit_status, 0}}, 10_000
    assert_receive {^second_port, {:exit_status, 0}}, 10_000
    assert {:ok, %Rekindle.Build.Result{}} = read_process_result(first_done)
    assert {:ok, %Rekindle.Build.Result{}} = read_process_result(second_done)

    manifest = release_root |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()
    assert :ok = Rekindle.Desktop.Manifest.validate_deployment(release_root, manifest)
    assert File.regular?(Path.join(release_root, manifest["executable"]))

    assert release_root
           |> File.ls!()
           |> Enum.filter(&String.starts_with?(&1, "application-")) == [
             manifest["executable"]
           ]
  end

  test "rejects changed bytes in an existing generation", %{root: root} do
    tools = fake_tools(root, executable?: true)
    assert {:ok, result} = build(root, tools)

    File.write!(result.artifact, "changed")
    File.chmod!(result.artifact, 0o755)

    assert {:error, %Rekindle.Desktop.Error{kind: :executable_hash}} = build(root, tools)
    assert File.read!(result.artifact) == "changed"
    refute File.exists?(Path.join(root, ".rekindle/dev/desktop-last-running.json"))
    assert Path.wildcard(Path.join(root, ".rekindle/tmp/desktop/*")) == []
  end

  test "rejects noncanonical desktop generation inventory during reuse", %{root: root} do
    tools = fake_tools(root, executable?: true)
    assert {:ok, result} = build(root, tools)

    generation_root = Path.dirname(result.artifact)
    manifest = result.metadata.manifest |> File.read!() |> Jason.decode!()
    linked_root = Path.join(root, "linked-desktop-generation")
    File.ln_s!(generation_root, linked_root)

    assert {:error, %Rekindle.Desktop.Error{kind: :invalid_manifest}} =
             Rekindle.Desktop.Manifest.validate(linked_root, manifest)

    assert {:error, %Rekindle.Desktop.Error{kind: :invalid_manifest}} =
             Rekindle.Desktop.Manifest.validate_deployment(linked_root, manifest)

    extra_file = Path.join(generation_root, "extra")
    File.write!(extra_file, "application-owned")

    assert {:error, %Rekindle.Desktop.Error{kind: :invalid_manifest}} =
             Rekindle.Desktop.Manifest.validate(generation_root, manifest)

    assert :ok = Rekindle.Desktop.Manifest.validate_deployment(generation_root, manifest)
    File.rm!(extra_file)

    extra_directory = Path.join(generation_root, "extra-directory")
    File.mkdir!(extra_directory)

    assert {:error, %Rekindle.Desktop.Error{kind: :invalid_manifest}} =
             Rekindle.Desktop.Manifest.validate(generation_root, manifest)

    File.rmdir!(extra_directory)
    File.ln_s!(result.artifact, Path.join(generation_root, "extra-link"))

    assert {:error, %Rekindle.Desktop.Error{kind: :invalid_manifest}} =
             Rekindle.Desktop.Manifest.validate(generation_root, manifest)

    assert {:error, %Rekindle.Desktop.Error{kind: :invalid_manifest}} = build(root, tools)
    assert File.regular?(result.artifact)
    assert executable?(result.artifact)
  end

  test "rejects non-executable Cargo output", %{root: root} do
    tools = fake_tools(root, executable?: false)

    assert {:error, %Rekindle.Desktop.Error{kind: :not_executable}} = build(root, tools)
    refute File.exists?(Path.join(root, ".rekindle/dev/desktop-current.json"))
  end

  test "reports publication state failures without leaving a selector", %{root: root} do
    tools = fake_tools(root, executable?: true)
    File.mkdir_p!(Path.join(root, ".rekindle"))
    File.write!(Path.join(root, ".rekindle/dev"), "not a directory")

    assert {:error, %Rekindle.Desktop.Error{kind: :mkdir}} = build(root, tools)
    refute File.exists?(Path.join(root, ".rekindle/dev/desktop-current.json"))
  end

  test "validates manifest identity and target paths", %{root: root} do
    tools = fake_tools(root, executable?: true)
    assert {:ok, result} = build(root, tools)
    generation_root = Path.dirname(result.artifact)
    manifest = result.metadata.manifest |> File.read!() |> Jason.decode!()

    changed_target = %{manifest | "target" => "other-target"}

    assert {:error, %Rekindle.Desktop.Error{kind: :invalid_manifest}} =
             Rekindle.Desktop.Manifest.validate(generation_root, changed_target)

    escaping = %{manifest | "target" => "../outside"}

    assert {:error, %Rekindle.Desktop.Error{kind: :invalid_manifest}} =
             Rekindle.Desktop.Manifest.validate(generation_root, escaping)
  end

  test "rejects noncanonical desktop manifest fields without replacing prior output", %{
    root: root
  } do
    selected_tools = fake_tools(root, executable?: true, marker: "selected")
    assert {:ok, selected} = build(root, selected_tools, profile: :release)
    release_root = Path.dirname(selected.artifact)
    release_manifest_path = selected.metadata.manifest
    release_manifest = File.read!(release_manifest_path)

    candidate_tools = fake_tools(root, executable?: true, marker: "candidate")
    assert {:ok, candidate} = build(root, candidate_tools)
    generation_root = Path.dirname(candidate.artifact)
    manifest_path = candidate.metadata.manifest
    manifest = manifest_path |> File.read!() |> Jason.decode!()
    unknown = Map.put(manifest, "metadata", %{"ignored" => true})

    for invalid <- [
          unknown,
          Map.delete(manifest, "target"),
          Map.put(manifest, "sha256", 42)
        ] do
      assert {:error, %Rekindle.Desktop.Error{kind: :invalid_manifest}} =
               Rekindle.Desktop.Manifest.validate(generation_root, invalid)
    end

    File.write!(manifest_path, Jason.encode!(unknown))

    assert {:error, %Rekindle.Desktop.Error{kind: :invalid_manifest}} =
             build(root, candidate_tools)

    assert File.regular?(candidate.artifact)

    assert {:ok, project} =
             Rekindle.Config.load(:rekindle_desktop_build_test, project_root: root)

    assert {:error, %Rekindle.Desktop.Error{kind: :invalid_manifest}} =
             Rekindle.Desktop.Release.publish(project, %{candidate | profile: :release})

    assert File.read!(release_manifest_path) == release_manifest
    assert File.regular?(selected.artifact)

    assert :ok =
             release_manifest
             |> Jason.decode!()
             |> then(&Rekindle.Desktop.Manifest.validate_deployment(release_root, &1))
  end

  test "rejects a noncanonical desktop release source without replacing output", %{root: root} do
    selected_tools = fake_tools(root, executable?: true, marker: "selected")
    assert {:ok, selected} = build(root, selected_tools, profile: :release)
    release_root = Path.dirname(selected.artifact)
    manifest_path = selected.metadata.manifest
    selected_manifest = File.read!(manifest_path)

    candidate_tools = fake_tools(root, executable?: true, marker: "candidate")
    assert {:ok, candidate} = build(root, candidate_tools)
    candidate_root = Path.dirname(candidate.artifact)
    File.ln_s!(candidate.artifact, Path.join(candidate_root, "extra-link"))

    assert {:ok, project} =
             Rekindle.Config.load(:rekindle_desktop_build_test, project_root: root)

    assert {:error, %Rekindle.Desktop.Error{kind: :invalid_manifest}} =
             Rekindle.Desktop.Release.publish(project, %{candidate | profile: :release})

    assert File.read!(manifest_path) == selected_manifest
    assert File.regular?(selected.artifact)

    assert :ok =
             selected_manifest
             |> Jason.decode!()
             |> then(&Rekindle.Desktop.Manifest.validate_deployment(release_root, &1))
  end

  test "rejects a desktop release source reached through linked state ancestry", %{root: root} do
    selected_tools = fake_tools(root, executable?: true, marker: "selected")
    assert {:ok, selected} = build(root, selected_tools, profile: :release)
    selected_manifest = File.read!(selected.metadata.manifest)

    candidate_tools = fake_tools(root, executable?: true, marker: "candidate")
    assert {:ok, candidate} = build(root, candidate_tools)
    candidate_manifest = File.read!(candidate.metadata.manifest)
    dev = Path.join(root, ".rekindle/dev")
    external = Path.join(root, "external-dev")
    File.rename!(dev, external)
    File.ln_s!(external, dev)

    assert {:ok, project} =
             Rekindle.Config.load(:rekindle_desktop_build_test, project_root: root)

    assert {:error, %Rekindle.Desktop.Error{kind: :manifest_read}} =
             Rekindle.Desktop.Release.publish(project, %{candidate | profile: :release})

    assert File.read!(selected.metadata.manifest) == selected_manifest
    assert File.regular?(selected.artifact)
    assert File.read!(candidate.metadata.manifest) == candidate_manifest
  end

  defp build(root, tools, options \\ []) do
    Rekindle.build(
      :desktop,
      [
        otp_app: :rekindle_desktop_build_test,
        project_root: root,
        cargo: tools.cargo,
        rustc: tools.rustc
      ] ++ options
    )
  end

  defp release_process(project, result, ready, done) do
    elixir = System.find_executable("elixir") || flunk("elixir executable is required")

    arguments =
      {project, %{result | profile: :release}, ready, done}
      |> :erlang.term_to_binary()
      |> Base.encode64()

    expression = """
    {project, result, ready, done} =
      #{inspect(arguments)}
      |> Base.decode64!()
      |> :erlang.binary_to_term()

    File.write!(ready, "ready")
    publication = Rekindle.Desktop.Release.publish(project, result)
    File.write!(done, publication |> :erlang.term_to_binary() |> Base.encode64())
    """

    code_paths =
      Mix.Project.build_path()
      |> Path.join("lib/*/ebin")
      |> Path.wildcard()
      |> Enum.flat_map(&[~c"-pa", String.to_charlist(&1)])

    Port.open(
      {:spawn_executable, String.to_charlist(elixir)},
      [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: code_paths ++ [~c"-e", String.to_charlist(expression)]
      ]
    )
  end

  defp read_process_result(path) do
    path
    |> File.read!()
    |> Base.decode64!()
    |> :erlang.binary_to_term()
  end

  defp wait_until(condition, attempts \\ 200)

  defp wait_until(condition, attempts) when attempts > 0 do
    if condition.() do
      :ok
    else
      Process.sleep(20)
      wait_until(condition, attempts - 1)
    end
  end

  defp wait_until(_condition, 0), do: flunk("independent publisher did not reach its gate")

  defp fake_tools(root, options) do
    target = Rekindle.Toolchain.desktop_target()
    launched = Path.join(root, "launched")
    artifact = Path.join(root, "client/target/#{target}/debug/desktop")
    rustc = Path.join(root, "fake-rustc")
    cargo = Path.join(root, "fake-cargo")
    package_id = "fixture_ui 0.1.0"

    write_executable(
      rustc,
      """
      #!/bin/sh
      printf 'rustc 1.90.0\\nhost: #{target}\\n'
      """
    )

    metadata =
      Jason.encode!(%{
        "packages" => [
          %{
            "id" => package_id,
            "name" => "fixture_ui",
            "manifest_path" => Path.join(root, "client/Cargo.toml"),
            "targets" => [
              %{
                "name" => "desktop",
                "kind" => ["bin"],
                "src_path" => Path.join(root, "client/src/bin/desktop.rs")
              }
            ],
            "dependencies" => [%{"name" => "gpui"}]
          }
        ],
        "workspace_members" => [package_id],
        "target_directory" => Path.join(root, "client/target")
      })

    compiler_artifact =
      Jason.encode!(%{
        "reason" => "compiler-artifact",
        "package_id" => package_id,
        "target" => %{"name" => "desktop", "kind" => ["bin"]},
        "filenames" => [artifact],
        "executable" => artifact
      })

    mode = if options[:executable?], do: "755", else: "644"
    marker = Keyword.get(options, :marker, "fixture")

    write_executable(
      cargo,
      """
      #!/bin/sh
      if [ "$1" = "metadata" ]; then
        printf '%s\\n' '#{metadata}'
        exit 0
      fi
      mkdir -p '#{Path.dirname(artifact)}'
      printf '#!/bin/sh\\n# #{marker}\\ntouch \"%s\"\\n' '#{launched}' > '#{artifact}'
      chmod #{mode} '#{artifact}'
      printf '%s\\n' '#{compiler_artifact}'
      """
    )

    %{cargo: cargo, rustc: rustc, target: target, launched: launched}
  end

  defp write_executable(path, contents) do
    File.write!(path, contents)
    File.chmod!(path, 0o755)
  end

  defp executable?(path) do
    {:ok, %{mode: mode}} = File.stat(path)
    Bitwise.band(mode, 0o111) != 0
  end

  defp bounded(function) do
    task = Task.async(function)
    Task.yield(task, 2_000) || Task.shutdown(task, :brutal_kill)
  end

  defp sha256(contents),
    do: contents |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
end
