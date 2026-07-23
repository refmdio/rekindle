defmodule Rekindle.SchedulerTest do
  use ExUnit.Case, async: true

  alias Rekindle.BuildGraph.Invalidation
  alias Rekindle.Scheduler.{ResourcePool, RevisionAllocator, Session}
  alias Rekindle.{Failure, ReloadPlan, Scheduler}

  @safe_integer 9_007_199_254_740_991

  test "one allocator seeds above every retained target and checks overflow" do
    assert {:ok, allocator, 0} = RevisionAllocator.new([])
    assert {:ok, allocator, 1} = RevisionAllocator.allocate(allocator)
    assert allocator.current == 1

    assert {:ok, allocator, 42} = RevisionAllocator.new([4, 41, 9])
    assert {:ok, %{current: 43}, 43} = RevisionAllocator.allocate(allocator)

    assert {:error, %{code: :contract_violation}} = RevisionAllocator.new([@safe_integer])
    assert {:error, %{code: :contract_violation}} = RevisionAllocator.new([-1])
  end

  test "session admission uses one snapshot for unequal retained targets" do
    retained = %{
      web: %{source_revision: 7, generation: :web_current},
      desktop: %{source_revision: 12, generation: :desktop_current}
    }

    assert {:ok, session, 13, []} = Session.new(target_nodes(), retained, 75)
    assert session.allocator.current == 13

    assert Scheduler.public_state(session.workers.web) == %{
             phase: :active,
             source_revision: 13,
             active_generation: :web_current,
             last_failure: nil
           }

    assert Scheduler.public_state(session.workers.desktop).source_revision == 13
  end

  test "targets without retained current request admission-bound tokens" do
    assert {:ok, session, 0, effects} = Session.new(target_nodes(), %{}, 75)

    assert [
             {:request_token, :web, web_token, 0},
             {:request_token, :desktop, desktop_token, 0}
           ] = effects

    assert Regex.match?(~r/\A[0-9a-f]{32}\z/, web_token)
    assert Regex.match?(~r/\A[0-9a-f]{32}\z/, desktop_token)
    assert session.workers.web.pending_revision == 0
    assert session.workers.desktop.pending_revision == 0
    assert session.workers.web.affected_nodes == [:cargo_web]
    assert session.workers.desktop.affected_nodes == [:cargo_desktop]
  end

  test "allocation overflow rejects synchronous and watcher work before state changes" do
    retained = %{web: %{source_revision: @safe_integer - 1, generation: :current}}

    assert {:ok, session, @safe_integer, []} =
             Session.new(%{web: [:cargo_web]}, retained, 0)

    assert {:error, %{code: :contract_violation}} =
             Session.request(session, :web, [:cargo_web], make_ref())

    assert {:error, %{code: :contract_violation}} =
             Session.watch(session, %{web: [:cargo_web]}, 0)

    assert session.allocator.current == @safe_integer
    assert session.workers.web.state == :active
  end

  test "one watcher batch assigns the same revision to every affected target" do
    retained = %{
      web: %{source_revision: 3, generation: :web_current},
      desktop: %{source_revision: 8, generation: :desktop_current}
    }

    assert {:ok, session, 9, []} = Session.new(target_nodes(), retained, 50)

    assert {:ok, session, 10, []} =
             Session.watch(
               session,
               %{web: [:cargo_web], desktop: [:cargo_desktop]},
               100
             )

    assert session.workers.web.pending_revision == 10
    assert session.workers.desktop.pending_revision == 10
    assert session.workers.web.debounce_deadline_ms == 150
    assert session.workers.desktop.debounce_deadline_ms == 150
  end

  test "change storms replace pending work and bind grants to revision and token" do
    {:ok, scheduler} =
      Scheduler.new(:web, 75, 1, %{source_revision: 0, generation: :current})

    assert {:ok, scheduler, []} = Scheduler.change(scheduler, [:cargo_web], 2, 100)
    assert {:ok, scheduler, []} = Scheduler.ready(scheduler, 174)
    assert {:ok, scheduler, [{:request_token, token, 2}]} = Scheduler.ready(scheduler, 175)

    assert {:ok, ^scheduler, [{:release_token, "stale", 2}]} =
             Scheduler.grant(scheduler, "stale", 2)

    assert {:ok, scheduler, effects} = Scheduler.change(scheduler, [:package_web], 3, 180)
    assert effects == [{:cancel_token, token, 2}, {:cancelled, 2, :obsolete}]
    assert scheduler.pending_revision == 3
    assert scheduler.affected_nodes == [:cargo_web, :package_web]

    assert {:ok, scheduler, [{:request_token, next_token, 3}]} =
             Scheduler.ready(scheduler, 255)

    assert {:ok, scheduler, [{:start, 3, [:cargo_web, :package_web]}]} =
             Scheduler.grant(scheduler, next_token, 3)

    assert scheduler.state == :building
    assert scheduler.running_revision == 3
  end

  test "synchronous requests allocate once and replace callers in every resting phase" do
    retained = %{web: %{source_revision: 4, generation: :current}}
    assert {:ok, session, 5, []} = Session.new(%{web: [:cargo_web]}, retained, 50)
    first_caller = make_ref()
    second_caller = make_ref()

    assert {:ok, session, 6, [{:request_token, :web, first_token, 6}]} =
             Session.request(session, :web, [:cargo_web], first_caller)

    assert {:ok, session, 7, effects} =
             Session.request(session, :web, [:package_web], second_caller)

    assert [
             {:cancel_token, :web, ^first_token, 6},
             {:cancelled, :web, 6, :obsolete},
             {:caller, ^first_caller, {:error, %{code: :cancelled}}},
             {:request_token, :web, next_token, 7}
           ] = effects

    assert session.allocator.current == 7
    assert session.workers.web.pending_revision == 7
    assert session.workers.web.token_request.id == next_token
    assert session.callers == %{7 => second_caller}
  end

  test "changes during work queue only the newest revision and cancel once" do
    scheduler = running_worker(:desktop, 1)

    assert {:ok, scheduler, [{:cancel, 1, :obsolete}, {:cancelled, 1, :obsolete}]} =
             Scheduler.change(scheduler, [:seal_desktop], 2, 100)

    assert {:ok, scheduler, [{:cancelled, 2, :obsolete}]} =
             Scheduler.change(scheduler, [:cargo_desktop], 3, 110)

    assert scheduler.latest_source_revision == 3
    assert scheduler.queued_revision == 3
    assert scheduler.queued_nodes == [:cargo_desktop, :seal_desktop]

    cancellation = failure(:cancelled)

    assert {:ok, scheduler, effects} = Scheduler.fail(scheduler, 1, cancellation)
    assert [{:discarded, 1}, {:request_token, token, 3}] = effects
    assert scheduler.last_failure == nil
    assert scheduler.pending_revision == 3

    assert {:ok, scheduler, [{:start, 3, [:cargo_desktop, :seal_desktop]}]} =
             Scheduler.grant(scheduler, token, 3)

    assert scheduler.running_revision == 3
  end

  test "synchronous replacement is total in every running phase" do
    building = running_worker(:web, 1)
    assert {:ok, validating} = Scheduler.advance(building, 1, :validating)
    assert {:ok, publishing} = Scheduler.advance(validating, 1, :publishing)

    for {scheduler, expected} <- [
          {building, [{:cancel, 1, :obsolete}, {:cancelled, 1, :obsolete}]},
          {validating, [{:cancel, 1, :obsolete}, {:cancelled, 1, :obsolete}]},
          {publishing, [{:cancelled, 1, :obsolete}]}
        ] do
      assert {:ok, queued, ^expected} = Scheduler.request(scheduler, [:package_web], 2)
      assert queued.queued_revision == 2
      assert queued.running_revision == 1
      assert queued.running_terminal?
    end
  end

  test "caller departure detaches only the reply and leaves scheduled work intact" do
    retained = %{web: %{source_revision: 0, generation: :current}}
    assert {:ok, session, 1, []} = Session.new(%{web: [:cargo_web]}, retained, 0)
    caller = make_ref()

    assert {:ok, session, 2, [{:request_token, :web, token, 2}]} =
             Session.request(session, :web, [:cargo_web], caller)

    assert {:ok, session} = Session.detach_caller(session, caller)
    assert session.callers == %{}
    assert session.workers.web.pending_revision == 2

    assert {:ok, session, [{:start, :web, 2, [:cargo_web]}]} =
             Session.grant(session, :web, token, 2)

    failure = failure(:cargo_failed)

    assert {:ok, _session, [{:failed, :web, 2, ^failure}]} =
             Session.fail(session, :web, 2, failure)

    assert {:error, %{code: :contract_violation}} = Session.detach_caller(session, caller)
  end

  test "publication clears failure while a failed retry preserves last-good" do
    scheduler = running_worker(:web, 1)
    assert {:ok, scheduler} = Scheduler.advance(scheduler, 1, :validating)
    assert {:ok, scheduler} = Scheduler.advance(scheduler, 1, :publishing)

    assert {:ok, scheduler, [{:activated, 1, :generation_one}]} =
             Scheduler.succeed(scheduler, 1, :generation_one)

    assert scheduler.state == :active
    assert scheduler.last_failure == nil

    assert {:ok, scheduler, effects} = Scheduler.request(scheduler, [:package_web], 2)
    token = scheduler.token_request.id
    assert effects == [{:request_token, token, 2}]
    assert {:ok, scheduler, [{:start, 2, [:package_web]}]} = Scheduler.grant(scheduler, token, 2)

    failure = failure(:cargo_failed)
    assert {:ok, scheduler, [{:failed, 2, ^failure}]} = Scheduler.fail(scheduler, 2, failure)
    assert scheduler.state == :failed
    assert scheduler.active_generation == :generation_one
    assert scheduler.last_failure == %{source_revision: 2, stage: :execution, code: :cargo_failed}
  end

  test "session wrappers preserve revision correlation and supervisor health" do
    retained = %{web: %{source_revision: 0, generation: :previous_generation}}
    assert {:ok, session, 1, []} = Session.new(%{web: [:cargo_web]}, retained, 0)
    caller = make_ref()

    assert {:ok, session, 2, [{:request_token, :web, token, 2}]} =
             Session.request(session, :web, [:cargo_web], caller)

    assert {:ok, session, [{:start, :web, 2, [:cargo_web]}]} =
             Session.grant(session, :web, token, 2)

    failure = failure(:cargo_failed)

    assert {:ok, session, effects} =
             Session.fail(session, :web, 2, failure)

    assert [{:failed, :web, 2, ^failure}, {:caller, ^caller, {:error, ^failure}}] = effects

    assert Session.health(session) == :degraded
    next_caller = make_ref()

    assert {:ok, session, 3, [{:request_token, :web, next_token, 3}]} =
             Session.request(session, :web, [:cargo_web], next_caller)

    assert {:ok, session, [{:start, :web, 3, [:cargo_web]}]} =
             Session.grant(session, :web, next_token, 3)

    assert {:ok, session} = Session.advance(session, :web, 3, :validating)
    assert {:ok, session} = Session.advance(session, :web, 3, :publishing)

    assert {:ok, session, effects} =
             Session.succeed(session, :web, 3, :generation_one, :build_result)

    assert [
             {:activated, :web, 3, :generation_one},
             {:caller, ^next_caller, {:ok, :build_result}}
           ] = effects

    assert Session.health(session) == :ready
    assert session.workers.web.last_failure == nil
  end

  test "obsolete and duplicate completions never publish" do
    scheduler = running_worker(:web, 1)

    assert {:ok, scheduler, [{:cancel, 1, :obsolete}, {:cancelled, 1, :obsolete}]} =
             Scheduler.change(scheduler, [:cargo_web], 2, 10)

    assert {:ok, scheduler, effects} = Scheduler.succeed(scheduler, 1, :obsolete)
    assert [{:cached_obsolete, 1}, {:request_token, token, 2}] = effects
    assert scheduler.active_generation == nil

    assert {:ok, ^scheduler, []} = Scheduler.succeed(scheduler, 1, :duplicate)
    assert {:ok, scheduler, [{:start, 2, [:cargo_web]}]} = Scheduler.grant(scheduler, token, 2)
    assert scheduler.running_revision == 2
  end

  test "stop freezes allocation and cancels every nonterminal revision once" do
    retained = %{web: %{source_revision: 0, generation: :current}}
    assert {:ok, session, 1, []} = Session.new(%{web: [:cargo_web]}, retained, 0)
    caller = make_ref()

    assert {:ok, session, 2, [{:request_token, :web, token, 2}]} =
             Session.request(session, :web, [:cargo_web], caller)

    assert {:ok, session, effects} = Session.stop(session)

    assert [
             {:cancel_token, :web, ^token, 2},
             {:cancelled, :web, 2, :shutdown},
             {:caller, ^caller, {:error, %{code: :cancelled}}}
           ] = effects

    assert session.workers.web.state == :stopping
    assert session.allocator.current == 2

    assert {:error, %{code: :cancelled}} =
             Session.request(session, :web, [:cargo_web], make_ref())

    assert {:error, %{code: :cancelled}} =
             Session.watch(session, %{web: [:cargo_web]}, 10)

    assert session.allocator.current == 2
    assert {:ok, ^session, []} = Session.stop(session)
  end

  test "shutdown does not re-terminalize work already superseded" do
    retained = %{web: %{source_revision: 0, generation: :current}}
    assert {:ok, session, 1, []} = Session.new(%{web: [:cargo_web]}, retained, 0)
    first_caller = make_ref()
    second_caller = make_ref()

    assert {:ok, session, 2, [{:request_token, :web, token, 2}]} =
             Session.request(session, :web, [:cargo_web], first_caller)

    assert {:ok, session, [{:start, :web, 2, [:cargo_web]}]} =
             Session.grant(session, :web, token, 2)

    assert {:ok, session, 3, effects} =
             Session.request(session, :web, [:package_web], second_caller)

    assert [
             {:cancel, :web, 2, :obsolete},
             {:cancelled, :web, 2, :obsolete},
             {:caller, ^first_caller, {:error, %{code: :cancelled}}}
           ] = effects

    assert {:ok, session, effects} = Session.stop(session)

    assert [
             {:cancelled, :web, 3, :shutdown},
             {:caller, ^second_caller, {:error, %{code: :cancelled}}}
           ] = effects

    refute Enum.any?(effects, &match?({:cancelled, :web, 2, _reason}, &1))
    assert session.callers == %{}
  end

  test "unlisted and malformed transitions fail while stale completions are inert" do
    scheduler = running_worker(:web, 1)

    assert {:error, %{code: :contract_violation}} =
             Scheduler.advance(scheduler, 1, :publishing)

    assert {:error, %{code: :contract_violation}} =
             Scheduler.succeed(scheduler, 1, :premature)

    assert {:error, %{code: :contract_violation}} = Scheduler.ready(scheduler, -1)
    assert {:obsolete, ^scheduler} = Scheduler.advance(scheduler, 0, :validating)
    assert {:ok, ^scheduler, []} = Scheduler.succeed(scheduler, 0, :stale)
    assert {:ok, ^scheduler, []} = Scheduler.fail(scheduler, 0, failure(:cargo_failed))
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
  end

  test "normalizes rename events and rejects non-relative watcher paths" do
    assert {:ok, [%{kind: :deleted, path: "src/old.rs"}, %{kind: :created, path: "src/new.rs"}]} =
             Invalidation.normalize_event({:renamed, "src/old.rs", "src/new.rs"})

    assert {:error, %{code: :contract_violation}} =
             Invalidation.normalize_event({:modified, "../outside"})
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

    assert {:ok, static} = ReloadPlan.compare(old["artifact_id"], old, candidate)
    assert static["mode"] == "static"
    assert static["reason"] == "hot_styles_only"
    assert static["styles"] == [%{"old_path" => "app.css", "new_path" => "app.css"}]
    assert static["assets"] == ["image.png"]

    code_changed = put_in(candidate, ["members", Access.at(0), "sha256"], "new-js")

    assert {:ok, %{"reason" => "code_changed", "styles" => [], "assets" => []}} =
             ReloadPlan.compare(old["artifact_id"], old, code_changed)
  end

  defp running_worker(target, revision) do
    node = if target == :web, do: :cargo_web, else: :cargo_desktop
    {:ok, scheduler} = Scheduler.new(target, 0, revision)
    token = scheduler.token_request.id

    {:ok, scheduler, [{:start, ^revision, [^node]}]} =
      Scheduler.grant(%{scheduler | affected_nodes: [node]}, token, revision)

    scheduler
  end

  defp target_nodes do
    %{web: [:cargo_web], desktop: [:cargo_desktop]}
  end

  defp failure(code) do
    Failure.new!(
      target: :web,
      stage: elem(Failure.stage_for(code), 1),
      code: code,
      message: Atom.to_string(code)
    )
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
      "edges" => [%{"from" => "app.css", "to" => "image.png", "kind" => "css_url"}]
    }
  end
end
