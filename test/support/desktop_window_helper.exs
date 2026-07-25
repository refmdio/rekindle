defmodule Rekindle.Test.DesktopWindow do
  import ExUnit.Assertions

  @default_timeout 15_000
  @event_parsers [
    {~r/get_xdg_surface\(new id xdg_surface[#@](\d+), wl_surface[#@](\d+)\)/, :xdg_surface},
    {~r/xdg_surface[#@](\d+)\.get_toplevel\(new id xdg_toplevel[#@](\d+)\)/, :toplevel},
    {~r/xdg_toplevel[#@](\d+)\.configure\(/, :toplevel_configure},
    {~r/xdg_surface[#@](\d+)\.configure\((\d+)\)/, :surface_configure},
    {~r/xdg_surface[#@](\d+)\.ack_configure\((\d+)\)/, :ack},
    {~r/wl_surface[#@](\d+)\.attach\(wl_buffer[#@]/, :attach},
    {~r/wl_surface[#@](\d+)\.commit\(\)/, :commit},
    {~r/(?:xdg_surface|xdg_toplevel|wl_surface)[#@](\d+)\.destroy\(\)/, :destroy},
    {~r/wl_display[#@]\d+\.delete_id\((\d+)\)/, :destroy},
    {~r/create_surface\(new id wl_surface[#@](\d+)\)/, :destroy}
  ]

  def assert_starts!(executable, integration) do
    case observe(executable) do
      :ok ->
        :ok

      {:error, message} ->
        flunk("#{integration} desktop startup was not observed: #{message}")
    end
  end

  def observe(executable, arguments \\ [], options \\ []) do
    timeout = Keyword.get(options, :timeout, @default_timeout)
    runtime = temporary_runtime()
    observers = observer_pids()

    try do
      with {:ok, tools} <- tools(),
           {:ok, output} <- run(tools, runtime, executable, arguments, timeout) do
        case classify_protocol(output) do
          :ok -> :ok
          {:error, message} -> {:error, "#{message}\n#{String.slice(output, 0, 8_000)}"}
        end
      end
    after
      File.rm_rf!(runtime)
      assert observer_pids() == observers, "desktop observer processes were not reaped"
    end
  end

  def classify_protocol(output) do
    output
    |> String.split("\n")
    |> Enum.reduce_while(%{}, fn line, surfaces ->
      case event(line) do
        {:xdg_surface, xdg_surface, wl_surface} ->
          surfaces =
            surfaces
            |> drop_object(xdg_surface)
            |> drop_object(wl_surface)
            |> Map.put(xdg_surface, %{
              wl_surface: wl_surface,
              toplevel: nil,
              configured_serial: nil,
              acknowledged?: false,
              attached?: false
            })

          {:cont, surfaces}

        {:toplevel, xdg_surface, toplevel} ->
          surfaces = drop_object(surfaces, toplevel)

          {:cont,
           update_surface(surfaces, xdg_surface, fn surface ->
             %{surface | toplevel: toplevel}
           end)}

        {:toplevel_configure, toplevel} ->
          {:cont,
           update_matching(surfaces, :toplevel, toplevel, fn surface ->
             %{surface | configured_serial: :waiting, acknowledged?: false, attached?: false}
           end)}

        {:surface_configure, xdg_surface, serial} ->
          {:cont,
           update_surface(surfaces, xdg_surface, fn
             %{configured_serial: :waiting} = surface ->
               %{surface | configured_serial: serial}

             surface ->
               surface
           end)}

        {:ack, xdg_surface, serial} ->
          {:cont,
           update_surface(surfaces, xdg_surface, fn surface ->
             %{surface | acknowledged?: surface.configured_serial == serial, attached?: false}
           end)}

        {:attach, wl_surface} ->
          {:cont,
           update_matching(surfaces, :wl_surface, wl_surface, fn surface ->
             %{surface | attached?: surface.acknowledged?}
           end)}

        {:commit, wl_surface} ->
          if Enum.any?(surfaces, fn {_id, surface} ->
               surface.wl_surface == wl_surface and surface.attached?
             end) do
            {:halt, :presented}
          else
            {:cont, surfaces}
          end

        {:destroy, object} ->
          {:cont, drop_object(surfaces, object)}

        :ignore ->
          {:cont, surfaces}
      end
    end)
    |> case do
      :presented -> :ok
      _surfaces -> {:error, "no configured top-level surface presented a buffer"}
    end
  end

  defp run(tools, runtime, executable, arguments, timeout) do
    socket = "rekindle-#{resource_id()}"
    log = Path.join(runtime, "weston.log")
    trace = Path.join(runtime, "wayland-protocol.log")
    {xvfb, display} = start_xvfb!(tools)

    weston =
      try do
        open_observer(
          tools.weston,
          [
            "--backend=x11",
            "--renderer=pixman",
            "--shell=kiosk",
            "--socket=#{socket}",
            "--idle-time=0",
            "--debug",
            "--log=#{log}"
          ],
          [{"XDG_RUNTIME_DIR", runtime}, {"DISPLAY", display}]
        )
      rescue
        error ->
          stop_observer!(xvfb)
          reraise error, __STACKTRACE__
      end

    debug =
      try do
        wait_for_socket!(runtime, socket, log)

        port =
          open_observer(
            tools.weston_debug,
            ["--output", trace, "proto"],
            [{"XDG_RUNTIME_DIR", runtime}, {"WAYLAND_DISPLAY", socket}]
          )

        wait_for_file!(trace)
        Process.sleep(50)
        port
      rescue
        error ->
          stop_observer!(weston)
          stop_observer!(xvfb)
          reraise error, __STACKTRACE__
      end

    command = [
      "--signal=TERM",
      "--kill-after=1s",
      duration(timeout),
      executable
      | arguments
    ]

    {output, status} =
      try do
        System.cmd(tools.timeout, command,
          env: [
            {"XDG_RUNTIME_DIR", runtime},
            {"WAYLAND_DISPLAY", socket},
            {"XDG_SESSION_TYPE", "wayland"},
            {"WINIT_UNIX_BACKEND", "wayland"},
            {"DISPLAY", nil}
          ],
          stderr_to_stdout: true
        )
      after
        stop_observer!(debug)
        stop_observer!(weston)
        stop_observer!(xvfb)
      end

    observed = diagnostics([output, read(trace)], log)

    if status in [0, 124] do
      {:ok, observed}
    else
      {:error,
       "desktop process exited with status #{status}\n#{String.slice(observed, 0, 8_000)}"}
    end
  end

  defp open_observer(executable, arguments, environment, logger \\ fn _line -> :ok end) do
    {:ok, daemon} =
      MuonTrap.Daemon.start_link(executable, arguments,
        delay_to_sigkill: 1_000,
        env: environment,
        exit_status_to_reason: fn _status -> :normal end,
        logger_fun: logger,
        stderr_to_stdout: true
      )

    daemon
  end

  defp start_xvfb!(tools) do
    owner = self()
    output = make_ref()

    observer =
      open_observer(
        tools.xvfb,
        ["-displayfd", "1", "-screen", "0", "1280x720x24", "-nolisten", "tcp", "-noreset"],
        [],
        fn line -> send(owner, {output, line}) end
      )

    deadline = System.monotonic_time(:millisecond) + 5_000
    monitor = Process.monitor(observer)

    try do
      {observer, ":#{wait_for_display!(output, monitor, deadline, "")}"}
    rescue
      error ->
        stop_observer!(observer)
        reraise error, __STACKTRACE__
    end
  end

  defp wait_for_display!(ref, monitor, deadline, output) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^ref, line} ->
        output = output <> line <> "\n"

        case Integer.parse(String.trim(line)) do
          {display, ""} ->
            Process.demonitor(monitor, [:flush])
            Integer.to_string(display)

          _other ->
            wait_for_display!(ref, monitor, deadline, output)
        end

      {:DOWN, ^monitor, :process, _pid, reason} ->
        raise "Xvfb exited before reporting a display number: #{inspect(reason)}\n#{String.slice(output, 0, 8_000)}"
    after
      remaining ->
        Process.demonitor(monitor, [:flush])
        raise "Xvfb did not report a display number\n#{String.slice(output, 0, 8_000)}"
    end
  end

  defp wait_for_socket!(runtime, socket, log) do
    path = Path.join(runtime, socket)
    deadline = System.monotonic_time(:millisecond) + 5_000

    wait_for_path!(
      path,
      deadline,
      fn ->
        "Weston did not create its Wayland socket\n#{String.slice(read(log), 0, 8_000)}"
      end
    )
  end

  defp wait_for_file!(path) do
    deadline = System.monotonic_time(:millisecond) + 5_000
    wait_for_path!(path, deadline, fn -> "weston-debug did not create its protocol trace" end)
  end

  defp wait_for_path!(path, deadline, message) do
    cond do
      File.exists?(path) ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(25)
        wait_for_path!(path, deadline, message)

      true ->
        raise message.()
    end
  end

  defp stop_observer!(daemon) do
    if Process.alive?(daemon) do
      try do
        GenServer.stop(daemon, :normal, 7_000)
      catch
        :exit, {:noproc, _call} -> :ok
      end
    end

    :ok
  end

  defp observer_pids do
    "/proc/[0-9]*/comm"
    |> Path.wildcard()
    |> Enum.reduce(MapSet.new(), fn comm_path, pids ->
      with {:ok, name} <- File.read(comm_path),
           true <- String.trim(name) in ["Xvfb", "weston", "weston-debug"] do
        comm_path
        |> Path.dirname()
        |> Path.basename()
        |> String.to_integer()
        |> then(&MapSet.put(pids, &1))
      else
        _other -> pids
      end
    end)
  end

  defp read(path) do
    if File.regular?(path), do: File.read!(path), else: ""
  end

  defp event(line) do
    Enum.find_value(@event_parsers, :ignore, fn {regex, name} ->
      case Regex.run(regex, line, capture: :all_but_first) do
        nil -> nil
        captures -> List.to_tuple([name | captures])
      end
    end)
  end

  defp update_surface(surfaces, id, update) do
    case Map.fetch(surfaces, id) do
      {:ok, surface} -> Map.put(surfaces, id, update.(surface))
      :error -> surfaces
    end
  end

  defp update_matching(surfaces, key, id, update) do
    Map.new(surfaces, fn {xdg_surface, surface} ->
      if Map.fetch!(surface, key) == id do
        {xdg_surface, update.(surface)}
      else
        {xdg_surface, surface}
      end
    end)
  end

  defp drop_object(surfaces, id) do
    Map.reject(surfaces, fn {xdg_surface, surface} ->
      id in [xdg_surface, surface.wl_surface, surface.toplevel]
    end)
  end

  defp tools do
    [
      timeout: "timeout",
      weston: "weston",
      weston_debug: "weston-debug",
      xvfb: "Xvfb"
    ]
    |> Enum.reduce_while({:ok, %{}}, fn name, {:ok, tools} ->
      {key, executable} = name

      case System.find_executable(executable) do
        nil -> {:halt, {:error, "#{executable} executable is required for desktop startup tests"}}
        path -> {:cont, {:ok, Map.put(tools, key, path)}}
      end
    end)
  end

  defp temporary_runtime do
    path =
      Path.join(
        System.tmp_dir!(),
        "rekindle-wayland-#{resource_id()}"
      )

    File.mkdir_p!(path)
    File.chmod!(path, 0o700)
    path
  end

  defp resource_id do
    token =
      12
      |> :crypto.strong_rand_bytes()
      |> Base.url_encode64(padding: false)

    "#{System.pid()}-#{token}"
  end

  defp duration(milliseconds), do: "#{milliseconds / 1_000}s"

  defp diagnostics(output, log) do
    [output, read(log)]
    |> List.flatten()
    |> Enum.join("\n")
  end
end
