defmodule Rekindle.SchedulerTest do
  use ExUnit.Case, async: true

  alias Rekindle.BuildGraph.Invalidation
  alias Rekindle.{Failure, ReloadPlan, Scheduler}
  alias Rekindle.Scheduler.ResourcePool

  test "normalizes rename events and rejects non-relative watcher paths" do
    assert {:ok, [%{kind: :deleted, path: "src/old.rs"}, %{kind: :created, path: "src/new.rs"}]} =
             Invalidation.normalize_event({:renamed, "src/old.rs", "src/new.rs"})

    assert {:ok, [%{kind: :modified, path: "src/lib.rs"}]} =
             Invalidation.normalize_event({:modified, "src/lib.rs"})

    assert {:error, %{code: :contract_violation}} =
             Invalidation.normalize_event({:modified, "../outside"})
  end

  test "all admitted project changes invalidate every canonical Cargo target" do
    for change <- [:project_input, :rust, :manifest, :toolchain, :configuration, :public_asset] do
      assert {:ok, affected} =
               Invalidation.classify(change, [:web, :desktop],
                 canonical_targets: [:web, :desktop]
               )

      assert affected.web == [:cargo_web, :bindgen_web, :package_web, :seal_web]
      assert affected.desktop == [:cargo_desktop, :seal_desktop]
    end

    assert {:ok, %{web: [:package_web, :seal_web]}} =
             Invalidation.classify(:bootstrap, [:web, :desktop])

    assert {:ok, %{}} = Invalidation.classify(:development, [:web, :desktop])
    assert {:ok, %{}} = Invalidation.classify(:projection, [:web, :desktop])

    assert {:ok, %{desktop: [:cargo_desktop, :seal_desktop]}} =
             Invalidation.classify(:uncertain, [:web, :desktop], target: :desktop)

    assert {:ok, %{web: [:external_web, :seal_web], desktop: [:cargo_desktop, :seal_desktop]}} =
             Invalidation.classify(:project_input, [:web, :desktop],
               canonical_targets: [:desktop]
             )
  end

  test "change storms coalesce into one newest revision and reset debounce" do
    assert {:ok, scheduler} = Scheduler.new(:web, 75)
    assert {:ok, scheduler, []} = Scheduler.change(scheduler, [:cargo_web], 100)
    assert scheduler.latest_source_revision == 1
    assert scheduler.debounce_deadline_ms == 175

    assert {:ok, scheduler, []} = Scheduler.change(scheduler, [:package_web], 140)
    assert scheduler.latest_source_revision == 2
    assert scheduler.debounce_deadline_ms == 215
    assert {:ok, ^scheduler, :none} = Scheduler.ready(scheduler, 214)

    assert {:ok, scheduler, {:start, 2, nodes}} = Scheduler.ready(scheduler, 215)
    assert nodes == [:cargo_web, :package_web]
    assert scheduler.state == :building
    assert scheduler.running_revision == 2
  end

  test "changes during a build queue the newest revision and request cancellation once" do
    scheduler = start_build(:desktop)
    assert {:ok, scheduler, [{:cancel, 1}]} = Scheduler.change(scheduler, [:seal_desktop], 100)
    assert scheduler.queued_revision == 2
    assert scheduler.cancel_requested?

    assert {:ok, scheduler, []} = Scheduler.change(scheduler, [:cargo_desktop], 110)
    assert scheduler.latest_source_revision == 3
    assert scheduler.queued_revision == 3
    assert scheduler.queued_nodes == [:cargo_desktop, :seal_desktop]

    assert {:ok, scheduler} = Scheduler.advance(scheduler, 1, :validating)
    assert {:obsolete, ^scheduler} = Scheduler.advance(scheduler, 1, :publishing)

    assert {:ok, scheduler, [{:cached_obsolete, 1}]} =
             Scheduler.succeed(scheduler, 1, :old_generation, 200)

    assert scheduler.state == :debouncing
    assert scheduler.active_generation == nil
    assert {:ok, scheduler, {:start, 3, _nodes}} = Scheduler.ready(scheduler, 200)
    assert scheduler.cancel_requested? == false
  end

  test "publication rechecks newest revision and only then changes last-good state" do
    scheduler = start_build(:web)
    assert {:ok, scheduler} = Scheduler.advance(scheduler, 1, :validating)
    assert {:ok, scheduler} = Scheduler.advance(scheduler, 1, :publishing)

    assert {:ok, scheduler, [{:activated, 1, :generation_one}]} =
             Scheduler.succeed(scheduler, 1, :generation_one, 100)

    assert scheduler.state == :active
    assert scheduler.active_generation == :generation_one

    assert {:ok, scheduler, []} = Scheduler.change(scheduler, [:package_web], 200)
    assert {:ok, scheduler, {:start, 2, _}} = Scheduler.ready(scheduler, 275)

    failure =
      Failure.new!(
        target: :web,
        stage: :execution,
        code: :cargo_failed,
        message: "build failed"
      )

    assert {:ok, scheduler, [{:failed, 2, ^failure}]} = Scheduler.fail(scheduler, 2, failure, 300)
    assert scheduler.state == :active
    assert scheduler.active_generation == :generation_one
  end

  test "a change during publication is never cancelled and cannot publish obsolete state" do
    scheduler = start_build(:web)
    assert {:ok, scheduler} = Scheduler.advance(scheduler, 1, :validating)
    assert {:ok, scheduler} = Scheduler.advance(scheduler, 1, :publishing)
    assert {:ok, scheduler, []} = Scheduler.change(scheduler, [:cargo_web], 50)
    assert scheduler.queued_revision == 2

    assert {:ok, scheduler, [{:obsolete, 1}]} =
             Scheduler.succeed(scheduler, 1, :obsolete_generation, 60)

    assert scheduler.active_generation == nil
    assert scheduler.state == :debouncing
  end

  test "stop rejects later revisions and preserves publication atomicity" do
    scheduler = start_build(:web)
    assert {:ok, scheduler, [{:cancel, 1}]} = Scheduler.stop(scheduler)
    assert scheduler.state == :stopping
    assert {:ok, ^scheduler, [:rejected]} = Scheduler.change(scheduler, [:cargo_web], 10)

    publishing = start_build(:web)
    assert {:ok, publishing} = Scheduler.advance(publishing, 1, :validating)
    assert {:ok, publishing} = Scheduler.advance(publishing, 1, :publishing)
    assert {:ok, stopped, []} = Scheduler.stop(publishing)
    assert stopped.state == :stopping
  end

  test "stopping absorbs every late terminal result and never reopens admission" do
    failure =
      Failure.new!(
        target: :web,
        stage: :execution,
        code: :cargo_failed,
        message: "late failure"
      )

    cancellation =
      Failure.new!(
        target: :web,
        stage: :execution,
        code: :cancelled,
        message: "late cancellation"
      )

    building = start_build(:web)
    assert {:ok, stopped, [{:cancel, 1}]} = Scheduler.stop(building)

    for terminal <- [
          {:succeed, :generation_one},
          {:fail, failure},
          {:fail, cancellation},
          {:succeed, :duplicate_generation},
          {:fail, failure}
        ] do
      result =
        case terminal do
          {:succeed, generation} -> Scheduler.succeed(stopped, 1, generation, 10)
          {:fail, reason} -> Scheduler.fail(stopped, 1, reason, 10)
        end

      assert {:ok, ^stopped, []} = result
      assert {:ok, ^stopped, [:rejected]} = Scheduler.change(stopped, [:cargo_web], 11)
    end

    assert stopped.state == :stopping
    assert stopped.active_generation == nil

    publishing = start_build(:web)
    assert {:ok, publishing} = Scheduler.advance(publishing, 1, :validating)
    assert {:ok, publishing} = Scheduler.advance(publishing, 1, :publishing)
    assert {:ok, publishing_stopped, []} = Scheduler.stop(publishing)

    assert {:ok, ^publishing_stopped, []} =
             Scheduler.succeed(publishing_stopped, 1, :forbidden_generation, 20)

    assert publishing_stopped.state == :stopping
    assert publishing_stopped.active_generation == nil
  end

  test "resource leases serialize matching Cargo caches and bound independent work" do
    assert {:ok, pool} = ResourcePool.new(2, 1)
    assert {:ok, pool} = ResourcePool.acquire_cargo(pool, :web, "cache-a")
    assert {:busy, :cache_key, ^pool} = ResourcePool.acquire_cargo(pool, :desktop, "cache-a")
    assert {:ok, pool} = ResourcePool.acquire_cargo(pool, :desktop, "cache-b")
    assert {:busy, :capacity, ^pool} = ResourcePool.acquire_cargo(pool, :other, "cache-c")
    assert {:ok, pool} = ResourcePool.release_cargo(pool, :web)

    assert {:ok, pool} = ResourcePool.acquire_helper(pool, :bindgen)
    assert {:busy, :capacity, ^pool} = ResourcePool.acquire_helper(pool, :package)
    assert {:ok, pool} = ResourcePool.release_helper(pool, :bindgen)

    assert {:ok, pool} = ResourcePool.acquire_target(pool, :web, :publisher)
    assert {:busy, :target, ^pool} = ResourcePool.acquire_target(pool, :web, :other)
    assert {:ok, _pool} = ResourcePool.release_target(pool, :web, :publisher)
  end

  test "reload plans apply ordered page reasons and a closed hot-style graph" do
    old = manifest("a", "old-css", "old-image")
    candidate = manifest("b", "new-css", "new-image")

    assert {:ok, nil} = ReloadPlan.compare(candidate["artifact_id"], old, candidate)

    assert {:ok, %{"mode" => "page", "reason" => "initial"}} =
             ReloadPlan.compare(nil, nil, candidate)

    assert {:ok, %{"mode" => "page", "reason" => "history_unavailable"}} =
             ReloadPlan.compare(old["artifact_id"], nil, candidate)

    assert {:ok, static} = ReloadPlan.compare(old["artifact_id"], old, candidate)
    assert static["mode"] == "static"
    assert static["reason"] == "hot_styles_only"
    assert static["styles"] == [%{"old_path" => "app.css", "new_path" => "app.css"}]
    assert static["assets"] == ["image.png"]

    code_changed = put_in(candidate, ["members", Access.at(0), "sha256"], "new-js")

    assert {:ok, %{"reason" => "code_changed", "styles" => [], "assets" => []}} =
             ReloadPlan.compare(old["artifact_id"], old, code_changed)

    graph_changed = put_in(candidate, ["hot_styles"], ["other.css"])

    assert {:ok, %{"reason" => "graph_changed"}} =
             ReloadPlan.compare(old["artifact_id"], old, graph_changed)

    undeclared =
      update_in(candidate, ["members"], fn members ->
        Enum.map(members, fn
          %{"path" => "other.txt"} = member -> %{member | "sha256" => "changed"}
          member -> member
        end)
      end)

    assert {:ok, %{"reason" => "undeclared_asset"}} =
             ReloadPlan.compare(old["artifact_id"], old, undeclared)
  end

  test "reload plan reason precedence prefers code over graph changes" do
    old = manifest("a", "old", "old")

    changed =
      manifest("b", "new", "new")
      |> put_in(["entry"], "different.js")
      |> put_in(["hot_styles"], ["different.css"])

    assert {:ok, %{"reason" => "code_changed"}} =
             ReloadPlan.compare(old["artifact_id"], old, changed)
  end

  defp start_build(target) do
    node = if target == :web, do: :cargo_web, else: :cargo_desktop
    {:ok, scheduler} = Scheduler.new(target, 0)
    {:ok, scheduler, []} = Scheduler.change(scheduler, [node], 0)
    {:ok, scheduler, {:start, 1, [^node]}} = Scheduler.ready(scheduler, 0)
    scheduler
  end

  defp manifest(id, css_hash, image_hash) do
    %{
      "artifact_id" => String.duplicate(id, 64),
      "application_id" => "demo",
      "rekindle_version" => "0.1.0",
      "target" => "web",
      "build" => %{"profile" => "dev"},
      "producer" => %{"kind" => "canonical"},
      "host_requirements" => %{"webgpu" => true},
      "entry" => "bootstrap.js",
      "hot_styles" => ["app.css"],
      "members" => [
        %{"path" => "bootstrap.js", "role" => "bootstrap", "sha256" => "same-js"},
        %{"path" => "app.css", "role" => "css", "sha256" => css_hash},
        %{"path" => "image.png", "role" => "asset", "sha256" => image_hash},
        %{"path" => "other.txt", "role" => "asset", "sha256" => "same-other"}
      ],
      "edges" => [
        %{"from" => "app.css", "to" => "image.png", "kind" => "css_url"}
      ]
    }
  end
end
