defmodule Rekindle.WebBuildTest do
  use ExUnit.Case, async: false

  setup do
    previous = Application.get_env(:rekindle_web_build_test, Rekindle)

    root =
      Path.join(
        System.tmp_dir!(),
        "rekindle-web-build-#{System.pid()}-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(Path.join(root, "client/src/bin"))
    File.write!(Path.join(root, "client/Cargo.toml"), "[package]\nname = \"fixture_ui\"\n")
    File.write!(Path.join(root, "client/src/bin/web.rs"), "fn main() {}\n")

    Application.put_env(:rekindle_web_build_test, Rekindle,
      integration: :gpui,
      targets: [web: [features: ["web"]]]
    )

    on_exit(fn ->
      File.rm_rf!(root)

      if previous do
        Application.put_env(:rekindle_web_build_test, Rekindle, previous)
      else
        Application.delete_env(:rekindle_web_build_test, Rekindle)
      end
    end)

    %{root: root}
  end

  test "publishes a complete immutable Web generation", %{root: root} do
    File.mkdir_p!(Path.join(root, "client/public/images"))
    File.write!(Path.join(root, "client/public/images/icon.txt"), "icon")
    tools = fake_tools(root, "success")

    assert {:ok, %Rekindle.Build.Result{} = result} = build(root, tools)
    assert result.target == :web
    assert result.profile == :dev
    assert File.regular?(result.artifact)

    generation = result.metadata.generation
    generation_root = Path.dirname(result.artifact)

    assert generation =~ ~r/^[0-9a-f]{64}$/
    assert generation_root == Path.join([root, ".rekindle", "dev", "web", generation])
    assert File.read!(result.artifact) =~ "app_bg.wasm"
    assert File.read!(Path.join(generation_root, "images/icon.txt")) == "icon"

    manifest = generation_root |> Path.join("manifest.json") |> read_json()
    assert manifest["generation"] == generation
    assert manifest["entry"] == "app.js"

    assert Enum.map(manifest["members"], & &1["path"]) == [
             "app.js",
             "app_bg.wasm",
             "images/icon.txt",
             "snippets/helper.js"
           ]

    Enum.each(manifest["members"], fn member ->
      contents = File.read!(Path.join(generation_root, member["path"]))
      assert member["sha256"] == sha256(contents)
    end)

    selector = root |> Path.join(".rekindle/dev/web-current.json") |> read_json()
    assert selector["generation"] == generation
    assert selector["manifest"] == "web/#{generation}/manifest.json"
    assert Path.wildcard(Path.join(root, ".rekindle/tmp/web/*")) == []

    assert {:ok, second} = build(root, tools)
    assert second.artifact == result.artifact
    assert File.read!(result.artifact) =~ "app_bg.wasm"
  end

  test "rejects linked project state ancestors without external writes", %{root: root} do
    tools = fake_tools(root, "success")
    external = Path.join(root, "external-state")
    File.mkdir!(external)
    File.write!(Path.join(external, "sentinel"), "unchanged")
    state = Path.join(root, ".rekindle")
    File.ln_s!(external, state)

    assert {:error, %Rekindle.Web.Error{kind: :mkdir, message: message}} =
             build(root, tools)

    assert message =~ "project-owned path"
    refute File.exists?(Path.join(external, "tmp"))
    assert File.read!(Path.join(external, "sentinel")) == "unchanged"

    File.rm!(state)
    assert {:ok, selected} = build(root, tools)
    selector = File.read!(Path.join(root, ".rekindle/dev/web-current.json"))
    artifact = File.read!(selected.artifact)

    tmp = Path.join(state, "tmp")
    File.rename!(tmp, Path.join(state, "tmp-owned"))
    File.ln_s!(external, tmp)

    assert {:error, %Rekindle.Web.Error{kind: :mkdir}} = build(root, tools)
    assert File.read!(Path.join(root, ".rekindle/dev/web-current.json")) == selector
    assert File.read!(selected.artifact) == artifact
    refute File.exists?(Path.join(external, "web"))
    assert File.read!(Path.join(external, "sentinel")) == "unchanged"
  end

  test "publishes release output separately from development output", %{root: root} do
    tools = fake_tools(root, "success")

    assert {:ok, result} = build(root, tools, profile: :release)
    assert result.profile == :release
    assert result.artifact =~ "/priv/static/rekindle/web/"
    assert File.regular?(result.artifact)

    entry = root |> Path.join("priv/static/rekindle/entry.js") |> read_entry()
    assert entry.generation == result.metadata.generation
    assert entry.module == "./web/#{result.metadata.generation}/app.js"

    assert result.metadata.manifest ==
             Path.join([
               root,
               "priv/static/rekindle/web",
               result.metadata.generation,
               "manifest.json"
             ])

    assert File.regular?(
             Path.join([
               root,
               ".rekindle/release/web",
               result.metadata.generation,
               "manifest.json"
             ])
           )

    refute File.exists?(Path.join(root, ".rekindle/dev/web-current.json"))
    refute File.exists?(Path.join(root, ".rekindle/release/web-current.json"))
    refute File.exists?(Path.join(root, "priv/static/rekindle/web-current.json"))
  end

  test "rejects linked and special Web release namespace components", %{root: root} do
    selected_tools = fake_tools(root, "success")
    assert {:ok, selected} = build(root, selected_tools, profile: :release)
    namespace = Path.join(root, "priv/static/rekindle")
    web_root = Path.join(namespace, "web")
    selected_entry = File.read!(Path.join(namespace, "entry.js"))
    selected_manifest = File.read!(selected.metadata.manifest)
    selected_artifact = File.read!(selected.artifact)

    candidate_tools = fake_tools(root, "success-two")
    assert {:ok, candidate} = build(root, candidate_tools)

    assert {:ok, project} =
             Rekindle.Config.load(:rekindle_web_build_test, project_root: root)

    for {ancestor, index} <- Enum.with_index([namespace, web_root]),
        kind <- [:symlink, :fifo] do
      backup = Path.join(root, "web-release-backup-#{index}-#{kind}")

      external =
        Path.join(
          System.tmp_dir!(),
          "rekindle-web-release-external-#{System.unique_integer([:positive, :monotonic])}"
        )

      File.mkdir!(external)
      on_exit(fn -> File.rm_rf!(external) end)
      relative_web = Path.relative_to(web_root, ancestor)
      external_web = if relative_web == ".", do: external, else: Path.join(external, relative_web)
      File.mkdir_p!(external_web)
      protected_generation = Path.join(external_web, String.duplicate("a", 64))
      protected_temporary = Path.join(external_web, ".tmp-protected")
      File.mkdir!(protected_generation)
      File.write!(Path.join(protected_generation, "sentinel"), "generation")
      File.mkdir!(protected_temporary)
      File.write!(Path.join(protected_temporary, "sentinel"), "temporary")
      File.write!(Path.join(external, "entry.js"), "external-entry")
      external_root_names = external |> File.ls!() |> Enum.sort()
      external_web_names = external_web |> File.ls!() |> Enum.sort()
      relative_manifest = Path.relative_to(selected.metadata.manifest, ancestor)
      relative_artifact = Path.relative_to(selected.artifact, ancestor)

      retained_entry =
        if ancestor == namespace,
          do: Path.join(backup, "entry.js"),
          else: Path.join(namespace, "entry.js")

      File.rename!(ancestor, backup)

      case kind do
        :symlink -> File.ln_s!(external, ancestor)
        :fifo -> assert {"", 0} = System.cmd("mkfifo", [ancestor])
      end

      try do
        assert {:error, %Rekindle.Web.Error{kind: :cleanup}} =
                 Rekindle.Web.Release.publish(project, %{candidate | profile: :release})

        assert external |> File.ls!() |> Enum.sort() == external_root_names
        assert external_web |> File.ls!() |> Enum.sort() == external_web_names
        assert File.read!(Path.join(external, "entry.js")) == "external-entry"
        assert File.read!(Path.join(protected_generation, "sentinel")) == "generation"
        assert File.read!(Path.join(protected_temporary, "sentinel")) == "temporary"
        assert File.read!(retained_entry) == selected_entry
        assert File.read!(Path.join(backup, relative_manifest)) == selected_manifest
        assert File.read!(Path.join(backup, relative_artifact)) == selected_artifact
      after
        File.rm!(ancestor)
        File.rename!(backup, ancestor)
      end
    end
  end

  test "retains the selected and previous Web releases without removing sibling files", %{
    root: root
  } do
    tools = fake_tools(root, "success-one")
    namespace = Path.join(root, "priv/static/rekindle")
    File.mkdir_p!(Path.join(namespace, "web"))
    File.write!(Path.join(namespace, "keep.txt"), "application-owned")
    File.mkdir_p!(Path.join(namespace, "web/.tmp-stale"))

    assert {:ok, first} = build(root, tools, profile: :release)
    refute File.exists?(Path.join(namespace, "web/.tmp-stale"))

    File.write!(tools.mode, "success-two")
    assert {:ok, second} = build(root, tools, profile: :release)

    File.write!(tools.mode, "success-three")
    assert {:ok, third} = build(root, tools, profile: :release)

    generations =
      namespace
      |> Path.join("web")
      |> File.ls!()
      |> Enum.filter(&(&1 =~ ~r/^[0-9a-f]{64}$/))
      |> MapSet.new()

    assert generations ==
             MapSet.new([second.metadata.generation, third.metadata.generation])

    refute MapSet.member?(generations, first.metadata.generation)
    assert File.read!(Path.join(namespace, "keep.txt")) == "application-owned"
  end

  test "rejects a missing or changed manifest in an existing public generation", %{root: root} do
    tools = fake_tools(root, "success")
    assert {:ok, result} = build(root, tools, profile: :release)

    entry_path = Path.join(root, "priv/static/rekindle/entry.js")
    entry = File.read!(entry_path)
    manifest_path = result.metadata.manifest
    manifest = File.read!(manifest_path)
    artifact = File.read!(result.artifact)

    File.write!(manifest_path, Jason.encode!(%{"generation" => result.metadata.generation}))

    assert {:error, %Rekindle.Web.Error{kind: :invalid_manifest}} =
             build(root, tools, profile: :release)

    assert File.read!(entry_path) == entry

    File.write!(manifest_path, manifest)
    File.write!(result.artifact, "changed")

    assert {:error, %Rekindle.Web.Error{kind: :member_hash}} =
             build(root, tools, profile: :release)

    assert File.read!(entry_path) == entry

    File.write!(result.artifact, artifact)
    File.rm!(manifest_path)

    assert {:error, %Rekindle.Web.Error{kind: :manifest_read}} =
             build(root, tools, profile: :release)

    assert File.read!(entry_path) == entry
  end

  test "rolls back a new generation when the release selector cannot be replaced", %{
    root: root
  } do
    tools = fake_tools(root, "success-one")
    assert {:ok, first} = build(root, tools, profile: :release)

    namespace = Path.join(root, "priv/static/rekindle")
    entry = Path.join(namespace, "entry.js")
    selected = File.read!(entry)

    File.write!(tools.mode, "success-two")
    assert {:ok, candidate} = build(root, tools)

    assert {:ok, project} =
             Rekindle.Config.load(:rekindle_web_build_test, project_root: root)

    destination =
      Path.join([
        namespace,
        "web",
        candidate.metadata.generation
      ])

    File.chmod!(namespace, 0o555)

    publication =
      try do
        Rekindle.Web.Release.publish(project, %{candidate | profile: :release})
      after
        File.chmod!(namespace, 0o755)
      end

    assert {:error, %Rekindle.Web.Error{kind: :selector_write}} = publication
    assert File.read!(entry) == selected
    assert File.regular?(first.artifact)
    refute File.exists?(destination)
  end

  test "preserves the selected release when retention cleanup fails", %{root: root} do
    tools = fake_tools(root, "success-one")
    assert {:ok, selected} = build(root, tools, profile: :release)

    File.write!(tools.mode, "success-two")
    assert {:ok, candidate} = build(root, tools)

    assert {:ok, project} =
             Rekindle.Config.load(:rekindle_web_build_test, project_root: root)

    namespace = Path.join(root, "priv/static/rekindle")
    web_root = Path.join(namespace, "web")
    backup = Path.join(root, "public-web-backup")
    selector = File.read!(Path.join(namespace, "entry.js"))
    selected_manifest = File.read!(selected.metadata.manifest)
    selected_artifact = File.read!(selected.artifact)
    relative_manifest = Path.relative_to(selected.metadata.manifest, web_root)
    relative_artifact = Path.relative_to(selected.artifact, web_root)

    File.rename!(web_root, backup)
    File.write!(web_root, "not a directory")

    try do
      assert {:error, %Rekindle.Web.Error{kind: :cleanup}} =
               Rekindle.Web.Release.publish(project, %{candidate | profile: :release})

      assert File.read!(Path.join(namespace, "entry.js")) == selector
      assert File.read!(Path.join(backup, relative_manifest)) == selected_manifest
      assert File.read!(Path.join(backup, relative_artifact)) == selected_artifact
    after
      File.rm!(web_root)
      File.rename!(backup, web_root)
    end

    assert File.read!(Path.join(namespace, "entry.js")) == selector
    assert File.read!(selected.metadata.manifest) == selected_manifest
    assert File.read!(selected.artifact) == selected_artifact

    refute File.exists?(Path.join([web_root, candidate.metadata.generation]))
  end

  test "does not activate a release when a stale generation cannot be removed", %{root: root} do
    tools = fake_tools(root, "success-one")
    assert {:ok, first} = build(root, tools, profile: :release)

    File.write!(tools.mode, "success-two")
    assert {:ok, second} = build(root, tools, profile: :release)

    File.write!(tools.mode, "success-three")
    assert {:ok, candidate} = build(root, tools)

    assert {:ok, project} =
             Rekindle.Config.load(:rekindle_web_build_test, project_root: root)

    namespace = Path.join(root, "priv/static/rekindle")
    web_root = Path.join(namespace, "web")
    selector = File.read!(Path.join(namespace, "entry.js"))
    selected_manifest = File.read!(second.metadata.manifest)
    selected_artifact = File.read!(second.artifact)
    stale = Path.dirname(first.artifact)

    File.chmod!(stale, 0o555)

    publication =
      try do
        Rekindle.Web.Release.publish(project, %{candidate | profile: :release})
      after
        if File.exists?(stale), do: File.chmod!(stale, 0o755)
      end

    assert {:error, %Rekindle.Web.Error{kind: :cleanup}} = publication
    assert File.read!(Path.join(namespace, "entry.js")) == selector
    assert File.read!(second.metadata.manifest) == selected_manifest
    assert File.read!(second.artifact) == selected_artifact
    refute File.exists?(Path.join(web_root, candidate.metadata.generation))

    assert release_generations(web_root) ==
             MapSet.new([first.metadata.generation, second.metadata.generation])

    assert {:ok, published} =
             Rekindle.Web.Release.publish(project, %{candidate | profile: :release})

    assert published.metadata.generation == candidate.metadata.generation

    assert release_generations(web_root) ==
             MapSet.new([second.metadata.generation, candidate.metadata.generation])
  end

  test "serializes concurrent Web releases in the same public namespace", %{root: root} do
    tools = fake_tools(root, "success-one")
    assert {:ok, first} = build(root, tools)

    File.write!(tools.mode, "success-two")
    assert {:ok, second} = build(root, tools)

    File.write!(tools.mode, "success-three")
    assert {:ok, third} = build(root, tools)

    assert {:ok, project} =
             Rekindle.Config.load(:rekindle_web_build_test, project_root: root)

    parent = self()
    namespace = Path.join(root, "priv/static/rekindle")

    holder =
      Task.async(fn ->
        Rekindle.Publication.with_lock(root, :web_release, fn ->
          send(parent, :publication_locked)

          receive do
            :release_publication -> :ok
          end
        end)
      end)

    assert_receive :publication_locked

    tasks =
      for candidate <-
            List.duplicate(first, 4) ++
              List.duplicate(second, 4) ++
              List.duplicate(third, 4) do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :publish -> Rekindle.Web.Release.publish(project, %{candidate | profile: :release})
          end
        end)
      end

    pids =
      for _index <- 1..length(tasks) do
        assert_receive {:ready, pid}
        pid
      end

    try do
      Enum.each(pids, &send(&1, :publish))
      Enum.each(tasks, &assert(Task.yield(&1, 50) == nil))
    after
      send(holder.pid, :release_publication)
      assert :ok = Task.await(holder)
    end

    assert Enum.all?(tasks, fn task ->
             match?({:ok, %Rekindle.Build.Result{}}, Task.await(task, 10_000))
           end)

    entry = namespace |> Path.join("entry.js") |> read_entry()
    generation_root = Path.join([namespace, "web", entry.generation])
    manifest = generation_root |> Path.join("manifest.json") |> read_json()

    assert File.regular?(Path.join(namespace, String.trim_leading(entry.module, "./")))
    assert File.regular?(Path.join(generation_root, "manifest.json"))
    assert :ok = Rekindle.Web.Manifest.validate(generation_root, manifest)

    assert namespace
           |> Path.join("web")
           |> File.ls!()
           |> Enum.count(&(&1 =~ ~r/^[0-9a-f]{64}$/)) <= 2
  end

  test "keeps the selected generation when the next package is incomplete", %{root: root} do
    tools = fake_tools(root, "success")
    assert {:ok, result} = build(root, tools)
    selector = Path.join(root, ".rekindle/dev/web-current.json")
    selected = File.read!(selector)

    File.write!(tools.mode, "missing-reference")

    assert {:error, %Rekindle.Web.Error{kind: :missing_reference}} = build(root, tools)
    assert File.read!(selector) == selected
    assert File.regular?(result.artifact)
    assert Path.wildcard(Path.join(root, ".rekindle/tmp/web/*")) == []
  end

  test "does not select a generation pruned by another activation", %{root: root} do
    tools = fake_tools(root, "success-one")

    candidates =
      for {mode, second} <-
            Enum.zip(["success-one", "success-two", "success-three"], [1, 2, 3]) do
        File.write!(tools.mode, mode)
        assert {:ok, candidate} = build(root, tools, activate: false)
        File.touch!(Path.dirname(candidate.artifact), {{2026, 1, 1}, {0, 0, second}})
        candidate
      end

    assert {:ok, project} =
             Rekindle.Config.load(:rekindle_web_build_test, project_root: root)

    assert :ok = Rekindle.Web.Builder.activate(project, Enum.at(candidates, 0))
    refute File.exists?(Enum.at(candidates, 1).artifact)
    assert File.exists?(Enum.at(candidates, 2).artifact)

    selector_path = Path.join(root, ".rekindle/dev/web-current.json")
    selected = File.read!(selector_path)

    assert {:error, %Rekindle.Web.Error{kind: :manifest_read}} =
             Rekindle.Web.Builder.activate(project, Enum.at(candidates, 1))

    assert File.read!(selector_path) == selected

    selected_generation = read_json(selector_path)["generation"]
    assert File.dir?(Path.join([root, ".rekindle", "dev", "web", selected_generation]))
  end

  test "rejects an unlisted member when reusing a development generation", %{root: root} do
    tools = fake_tools(root, "success")
    assert {:ok, result} = build(root, tools)

    generation_root = Path.dirname(result.artifact)
    manifest = generation_root |> Path.join("manifest.json") |> read_json()
    selector_path = Path.join(root, ".rekindle/dev/web-current.json")
    selected = File.read!(selector_path)

    File.write!(Path.join(generation_root, "unlisted.txt"), "unlisted")

    assert {:error, %Rekindle.Web.Error{kind: :invalid_manifest}} =
             Rekindle.Web.Manifest.validate(generation_root, manifest)

    assert {:error, %Rekindle.Web.Error{kind: :invalid_manifest}} = build(root, tools)
    assert File.read!(selector_path) == selected
  end

  test "rejects an unlisted member when reusing a release build generation", %{root: root} do
    tools = fake_tools(root, "success")
    assert {:ok, result} = build(root, tools, profile: :release)

    selector_path = Path.join(root, "priv/static/rekindle/entry.js")
    selected = File.read!(selector_path)

    generation_root =
      Path.join([root, ".rekindle/release/web", result.metadata.generation])

    manifest = generation_root |> Path.join("manifest.json") |> read_json()
    File.write!(Path.join(generation_root, "unlisted.txt"), "unlisted")

    assert {:error, %Rekindle.Web.Error{kind: :invalid_manifest}} =
             Rekindle.Web.Manifest.validate(generation_root, manifest)

    assert {:error, %Rekindle.Web.Error{kind: :invalid_manifest}} =
             build(root, tools, profile: :release)

    assert File.read!(selector_path) == selected
  end

  test "binds the runtime entry to the Web generation identity", %{root: root} do
    tools = fake_tools(root, "success-one")
    assert {:ok, selected_result} = build(root, tools, profile: :release)

    selector_path = Path.join(root, "priv/static/rekindle/entry.js")
    selected = File.read!(selector_path)

    File.write!(tools.mode, "success-two")
    assert {:ok, candidate} = build(root, tools, activate: false)

    generation_root = Path.dirname(candidate.artifact)
    manifest_path = candidate.metadata.manifest
    manifest = read_json(manifest_path)
    tampered = %{manifest | "entry" => "snippets/helper.js"}

    assert tampered["generation"] == manifest["generation"]

    assert {:error, %Rekindle.Web.Error{kind: :invalid_manifest}} =
             Rekindle.Web.Manifest.validate(generation_root, tampered)

    File.write!(manifest_path, Jason.encode!(tampered))

    assert {:ok, project} =
             Rekindle.Config.load(:rekindle_web_build_test, project_root: root)

    assert {:error, %Rekindle.Web.Error{kind: :invalid_manifest}} =
             Rekindle.Web.Release.publish(project, %{candidate | profile: :release})

    assert File.read!(selector_path) == selected
    assert File.regular?(selected_result.artifact)

    selected_manifest =
      selected_result.metadata.manifest
      |> File.read!()
      |> Jason.decode!()

    assert :ok =
             Rekindle.Web.Manifest.validate_deployment(
               Path.dirname(selected_result.metadata.manifest),
               selected_manifest
             )
  end

  test "rejects noncanonical members under a recomputed generation", %{root: root} do
    tools = fake_tools(root, "success-one")
    assert {:ok, selected_result} = build(root, tools, profile: :release)

    selector_path = Path.join(root, "priv/static/rekindle/entry.js")
    selected = File.read!(selector_path)

    File.write!(tools.mode, "success-two")
    assert {:ok, candidate} = build(root, tools, activate: false)

    generation_root = Path.dirname(candidate.artifact)
    manifest_path = candidate.metadata.manifest
    manifest = read_json(manifest_path)
    members = Enum.reverse(manifest["members"])

    reordered =
      manifest
      |> Map.put("members", members)
      |> Map.put(
        "generation",
        sha256(Jason.encode!([manifest["version"], manifest["entry"], members]))
      )

    refute reordered["generation"] == manifest["generation"]

    assert {:error, %Rekindle.Web.Error{kind: :invalid_manifest}} =
             Rekindle.Web.Manifest.validate(generation_root, reordered)

    assert {:error, %Rekindle.Web.Error{kind: :invalid_manifest}} =
             Rekindle.Web.Manifest.validate_deployment(generation_root, reordered)

    members_with_extra =
      List.update_at(manifest["members"], 0, &Map.put(&1, "ignored", true))

    with_extra =
      manifest
      |> Map.put("members", members_with_extra)
      |> Map.put(
        "generation",
        sha256(Jason.encode!([manifest["version"], manifest["entry"], members_with_extra]))
      )

    refute with_extra["generation"] == manifest["generation"]

    assert {:error, %Rekindle.Web.Error{kind: :invalid_manifest}} =
             Rekindle.Web.Manifest.validate(generation_root, with_extra)

    assert {:error, %Rekindle.Web.Error{kind: :invalid_manifest}} =
             Rekindle.Web.Manifest.validate_deployment(generation_root, with_extra)

    File.write!(manifest_path, Jason.encode!(reordered))

    assert {:ok, project} =
             Rekindle.Config.load(:rekindle_web_build_test, project_root: root)

    assert {:error, %Rekindle.Web.Error{kind: :invalid_manifest}} =
             Rekindle.Web.Release.publish(project, %{candidate | profile: :release})

    assert File.read!(selector_path) == selected
    assert File.regular?(selected_result.artifact)
  end

  test "rejects noncanonical Web manifest fields without replacing the release", %{root: root} do
    tools = fake_tools(root, "success-one")
    assert {:ok, selected_result} = build(root, tools, profile: :release)

    selector_path = Path.join(root, "priv/static/rekindle/entry.js")
    selected = File.read!(selector_path)

    File.write!(tools.mode, "success-two")
    assert {:ok, candidate} = build(root, tools, activate: false)

    generation_root = Path.dirname(candidate.artifact)
    manifest_path = candidate.metadata.manifest
    manifest = read_json(manifest_path)
    unknown = Map.put(manifest, "metadata", %{"ignored" => true})

    for invalid <- [
          unknown,
          Map.delete(manifest, "entry"),
          Map.put(manifest, "members", %{})
        ] do
      assert {:error, %Rekindle.Web.Error{kind: :invalid_manifest}} =
               Rekindle.Web.Manifest.validate(generation_root, invalid)

      assert {:error, %Rekindle.Web.Error{kind: :invalid_manifest}} =
               Rekindle.Web.Manifest.validate_deployment(generation_root, invalid)
    end

    File.write!(manifest_path, Jason.encode!(unknown))

    assert {:ok, project} =
             Rekindle.Config.load(:rekindle_web_build_test, project_root: root)

    assert {:error, %Rekindle.Web.Error{kind: :invalid_manifest}} =
             Rekindle.Web.Release.publish(project, %{candidate | profile: :release})

    assert File.read!(selector_path) == selected

    selected_manifest = read_json(selected_result.metadata.manifest)

    assert :ok =
             Rekindle.Web.Manifest.validate_deployment(
               Path.dirname(selected_result.metadata.manifest),
               selected_manifest
             )
  end

  test "reports incomplete and failed wasm-bindgen output", %{root: root} do
    tools = fake_tools(root, "missing-entry")

    assert {:error, %Rekindle.Web.Error{kind: :missing_entry}} = build(root, tools)

    File.write!(tools.mode, "failure")

    assert {:error, %Rekindle.Web.Error{kind: :wasm_bindgen, output: output}} =
             build(root, tools)

    assert output =~ "bindgen failed"
    refute File.exists?(Path.join(root, ".rekindle/dev/web-current.json"))
  end

  test "rejects disabled and missing Web entries before running tools", %{root: root} do
    tools = fake_tools(root, "failure")

    Application.put_env(:rekindle_web_build_test, Rekindle,
      integration: :gpui,
      targets: [desktop: []]
    )

    assert {:error, %Rekindle.Build.Error{kind: :disabled_target}} = build(root, tools)

    Application.put_env(:rekindle_web_build_test, Rekindle,
      integration: :gpui,
      targets: [web: []]
    )

    File.rm!(Path.join(root, "client/src/bin/web.rs"))
    assert {:error, %Rekindle.Build.Error{kind: :missing_entry}} = build(root, tools)
  end

  test "rejects public collisions and symbolic links", %{root: root} do
    tools = fake_tools(root, "success")
    File.mkdir_p!(Path.join(root, "client/public"))
    File.write!(Path.join(root, "client/public/app.js"), "collision")

    assert {:error, %Rekindle.Web.Error{kind: :asset_collision}} = build(root, tools)

    File.rm!(Path.join(root, "client/public/app.js"))
    File.ln_s!("elsewhere", Path.join(root, "client/public/link"))

    assert {:error, %Rekindle.Web.Error{kind: :copy_public}} = build(root, tools)
  end

  test "rejects symbolic links in Web generation paths", %{root: root} do
    tools = fake_tools(root, "success")
    assert {:ok, result} = build(root, tools)

    generation_root = Path.dirname(result.artifact)
    manifest = generation_root |> Path.join("manifest.json") |> read_json()
    linked_root = Path.join(root, "linked-generation")
    File.ln_s!(generation_root, linked_root)

    assert {:error, %Rekindle.Web.Error{kind: :unsupported_member}} =
             Rekindle.Web.Manifest.validate(linked_root, manifest)

    assert {:error, %Rekindle.Web.Error{kind: :unsupported_member}} =
             Rekindle.Web.Manifest.validate_deployment(linked_root, manifest)

    derivative = Path.join(generation_root, "snippets/helper-digested.js")
    File.write!(derivative, "digest derivative")

    assert :ok = Rekindle.Web.Manifest.validate_deployment(generation_root, manifest)

    assert {:error, %Rekindle.Web.Error{kind: :invalid_manifest}} =
             Rekindle.Web.Manifest.validate(generation_root, manifest)

    File.rm!(derivative)

    external_member = Path.join(root, "external-member")
    File.write!(external_member, "external")
    unlisted = Path.join(generation_root, "unlisted")
    File.ln_s!(external_member, unlisted)

    assert {:error, %Rekindle.Web.Error{kind: :unsupported_member}} =
             Rekindle.Web.Manifest.validate(generation_root, manifest)

    assert {:error, %Rekindle.Web.Error{kind: :unsupported_member}} =
             Rekindle.Web.Manifest.validate_deployment(generation_root, manifest)

    File.rm!(unlisted)

    external = Path.join(root, "external-snippets")
    File.mkdir_p!(external)

    File.cp!(
      Path.join(generation_root, "snippets/helper.js"),
      Path.join(external, "helper.js")
    )

    File.rm_rf!(Path.join(generation_root, "snippets"))
    File.ln_s!(external, Path.join(generation_root, "snippets"))

    assert {:error, %Rekindle.Web.Error{kind: :unsupported_member}} =
             Rekindle.Web.Manifest.validate(generation_root, manifest)

    assert {:error, %Rekindle.Web.Error{kind: :unsupported_member}} =
             Rekindle.Web.Manifest.validate_deployment(generation_root, manifest)
  end

  test "preserves the selected release when reuse crosses a symbolic link", %{root: root} do
    tools = fake_tools(root, "success-one")
    assert {:ok, _selected_result} = build(root, tools, profile: :release)

    File.write!(tools.mode, "success-two")
    assert {:ok, candidate} = build(root, tools, profile: :release)

    File.write!(tools.mode, "success-one")
    assert {:ok, selected_result} = build(root, tools, profile: :release)

    selector_path = Path.join(root, "priv/static/rekindle/entry.js")
    selected = File.read!(selector_path)
    selected_root = Path.dirname(selected_result.artifact)
    selected_manifest = read_json(selected_result.metadata.manifest)
    candidate_root = Path.dirname(candidate.artifact)
    candidate_manifest = read_json(candidate.metadata.manifest)
    external = Path.join(root, "external-release-snippets")
    File.mkdir_p!(external)

    File.cp!(
      Path.join(candidate_root, "snippets/helper.js"),
      Path.join(external, "helper.js")
    )

    File.rm_rf!(Path.join(candidate_root, "snippets"))
    File.ln_s!(external, Path.join(candidate_root, "snippets"))

    assert {:error, %Rekindle.Web.Error{kind: :unsupported_member}} =
             Rekindle.Web.Manifest.validate_deployment(candidate_root, candidate_manifest)

    File.write!(tools.mode, "success-two")

    assert {:error, %Rekindle.Web.Error{kind: :unsupported_member}} =
             build(root, tools, profile: :release)

    assert File.read!(selector_path) == selected
    assert :ok = Rekindle.Web.Manifest.validate_deployment(selected_root, selected_manifest)

    File.rm!(Path.join(candidate_root, "snippets"))
    File.mkdir!(Path.join(candidate_root, "snippets"))

    File.cp!(
      Path.join(external, "helper.js"),
      Path.join(candidate_root, "snippets/helper.js")
    )

    external_member = Path.join(root, "external-release-member")
    File.write!(external_member, "external")
    File.ln_s!(external_member, Path.join(candidate_root, "unlisted"))

    assert {:error, %Rekindle.Web.Error{kind: :unsupported_member}} =
             Rekindle.Web.Manifest.validate_deployment(candidate_root, candidate_manifest)

    assert {:error, %Rekindle.Web.Error{kind: :unsupported_member}} =
             build(root, tools, profile: :release)

    assert File.read!(selector_path) == selected
    assert :ok = Rekindle.Web.Manifest.validate_deployment(selected_root, selected_manifest)
  end

  test "reports publication state failures without leaving a selector", %{root: root} do
    tools = fake_tools(root, "success")
    File.mkdir_p!(Path.join(root, ".rekindle"))
    File.write!(Path.join(root, ".rekindle/dev"), "not a directory")

    assert {:error, %Rekindle.Web.Error{kind: :mkdir}} = build(root, tools)
    refute File.exists?(Path.join(root, ".rekindle/dev/web-current.json"))
  end

  test "rejects a Web release source reached through linked state ancestry", %{root: root} do
    tools = fake_tools(root, "success")
    assert {:ok, selected} = build(root, tools, profile: :release)
    selector_path = Path.join(root, "priv/static/rekindle/entry.js")
    selector = File.read!(selector_path)

    assert {:ok, candidate} = build(root, tools)
    candidate_manifest = File.read!(candidate.metadata.manifest)
    dev = Path.join(root, ".rekindle/dev")
    external = Path.join(root, "external-dev")
    File.rename!(dev, external)
    File.ln_s!(external, dev)

    assert {:ok, project} =
             Rekindle.Config.load(:rekindle_web_build_test, project_root: root)

    assert {:error, %Rekindle.Web.Error{kind: :manifest_read}} =
             Rekindle.Web.Release.publish(project, %{candidate | profile: :release})

    assert File.read!(selector_path) == selector
    assert File.regular?(selected.artifact)
    assert File.read!(candidate.metadata.manifest) == candidate_manifest
  end

  test "detects changed, duplicate, and escaping manifest members", %{root: root} do
    tools = fake_tools(root, "success")
    assert {:ok, result} = build(root, tools)
    generation_root = Path.dirname(result.artifact)
    manifest = generation_root |> Path.join("manifest.json") |> read_json()
    original = File.read!(result.artifact)
    selector = File.read!(Path.join(root, ".rekindle/dev/web-current.json"))

    File.write!(result.artifact, "changed")

    assert {:error, %Rekindle.Web.Error{kind: :member_hash}} =
             Rekindle.Web.Manifest.validate(generation_root, manifest)

    assert {:error, %Rekindle.Web.Error{kind: :member_hash}} = build(root, tools)
    assert File.read!(Path.join(root, ".rekindle/dev/web-current.json")) == selector

    File.write!(result.artifact, original)
    File.rm!(result.artifact)
    File.ln_s!("snippets/helper.js", result.artifact)

    assert {:error, %Rekindle.Web.Error{kind: :unsupported_member}} =
             Rekindle.Web.Manifest.validate(generation_root, manifest)

    File.rm!(result.artifact)
    File.write!(result.artifact, original)
    duplicate = update_in(manifest["members"], &(&1 ++ [hd(&1)]))

    assert {:error, %Rekindle.Web.Error{kind: :invalid_manifest}} =
             Rekindle.Web.Manifest.validate(generation_root, duplicate)

    escaping =
      put_in(
        manifest["members"],
        [%{"path" => "../outside.js", "sha256" => sha256("outside")} | manifest["members"]]
      )

    assert {:error, %Rekindle.Web.Error{kind: :invalid_path}} =
             Rekindle.Web.Manifest.validate(generation_root, escaping)
  end

  defp build(root, tools, options \\ []) do
    Rekindle.build(
      :web,
      [
        otp_app: :rekindle_web_build_test,
        project_root: root,
        cargo: tools.cargo,
        env: tools.env
      ] ++ options
    )
  end

  defp fake_tools(root, mode) do
    mode_path = Path.join(root, "bindgen-mode")
    File.write!(mode_path, mode)

    env = %{
      "HOME" => Path.join(root, "home"),
      "XDG_CACHE_HOME" => Path.join(root, "cache")
    }

    cargo = Path.join(root, "fake-cargo")
    wasm_bindgen = Rekindle.Toolchain.wasm_bindgen_path("0.2.126", env)
    File.mkdir_p!(Path.dirname(wasm_bindgen))

    package_id = "fixture_ui 0.1.0"
    artifact = Path.join(root, "client/target/wasm32-unknown-unknown/debug/web.wasm")

    metadata =
      Jason.encode!(%{
        "packages" => [
          %{
            "id" => package_id,
            "name" => "fixture_ui",
            "manifest_path" => Path.join(root, "client/Cargo.toml"),
            "targets" => [
              %{
                "name" => "web",
                "kind" => ["bin"],
                "src_path" => Path.join(root, "client/src/bin/web.rs")
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
        "target" => %{"name" => "web", "kind" => ["bin"]},
        "filenames" => [artifact],
        "executable" => nil
      })

    write_executable(
      cargo,
      """
      #!/bin/sh
      if [ "$1" = "metadata" ]; then
        printf '%s\\n' '#{metadata}'
        exit 0
      fi
      mkdir -p '#{Path.dirname(artifact)}'
      printf 'wasm' > '#{artifact}'
      printf '%s\\n' '#{compiler_artifact}'
      """
    )

    write_executable(
      wasm_bindgen,
      """
      #!/bin/sh
      if [ "$1" = "--version" ]; then
        echo "wasm-bindgen 0.2.126"
        exit 0
      fi
      while [ "$#" -gt 0 ]; do
        if [ "$1" = "--out-dir" ]; then
          output="$2"
          break
        fi
        shift
      done
      mkdir -p "$output"
      mode=$(cat '#{mode_path}')
      case "$mode" in
        success*)
          mkdir -p "$output/snippets"
          printf "/* %s */\\nimport './snippets/helper.js';\\nconst imports = {'./app_bg.js': {}};\\nconst wasm = new URL('app_bg.wasm', import.meta.url);\\nexport default async function init() { return wasm; }\\n" "$mode" > "$output/app.js"
          printf 'wasm-%s' "$mode" > "$output/app_bg.wasm"
          printf 'export const mode = "%s";\\n' "$mode" > "$output/snippets/helper.js"
          ;;
        missing-reference)
          printf "const wasm = new URL('app_bg.wasm', import.meta.url);\\n" > "$output/app.js"
          ;;
        missing-entry)
          printf 'wasm' > "$output/app_bg.wasm"
          ;;
        failure)
          echo "bindgen failed" >&2
          exit 17
          ;;
      esac
      """
    )

    %{cargo: cargo, env: env, mode: mode_path}
  end

  defp write_executable(path, contents) do
    File.write!(path, contents)
    File.chmod!(path, 0o755)
  end

  defp read_json(path), do: path |> File.read!() |> Jason.decode!()

  defp read_entry(path) do
    contents = File.read!(path)

    assert [generation, module] =
             Regex.run(
               ~r/\A\/\/ Rekindle generation: ([0-9a-f]{64})\nimport init from "([^"]+)";\nawait init\(\);\n\z/,
               contents,
               capture: :all_but_first
             )

    %{generation: generation, module: module}
  end

  defp release_generations(root) do
    root
    |> File.ls!()
    |> Enum.filter(&(&1 =~ ~r/^[0-9a-f]{64}$/))
    |> MapSet.new()
  end

  defp sha256(contents),
    do: contents |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
end
