defmodule Rekindle.Test.DesktopWindow do
  import ExUnit.Assertions

  @default_timeout 5_000
  @weston_timeout 8_000

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
    end
  end

  def classify_protocol(output) do
    output
    |> surfaces()
    |> Enum.find_value(fn [xdg_surface, wl_surface] ->
      with {:ok, toplevel} <- toplevel(output, xdg_surface),
           true <- configured?(output, xdg_surface, toplevel),
           true <- presented?(output, wl_surface) do
        :ok
      else
        _ -> nil
      end
    end)
    |> case do
      :ok -> :ok
      nil -> {:error, "no configured top-level surface presented a buffer"}
    end
  end

  defp run(tools, runtime, executable, arguments, timeout) do
    socket = "rekindle-#{System.unique_integer([:positive, :monotonic])}"
    log = Path.join(runtime, "weston.log")

    command = [
      "--signal=TERM",
      "--kill-after=1s",
      duration(@weston_timeout),
      tools.weston,
      "--backend=headless",
      "--fake-seat",
      "--socket=#{socket}",
      "--idle-time=0",
      "--log=#{log}",
      "--",
      tools.env,
      "WAYLAND_DEBUG=client",
      "WINIT_UNIX_BACKEND=wayland",
      tools.timeout,
      "--signal=TERM",
      "--kill-after=1s",
      duration(timeout),
      executable
      | arguments
    ]

    {output, status} =
      System.cmd(tools.timeout, command,
        env: [{"XDG_RUNTIME_DIR", runtime}],
        stderr_to_stdout: true
      )

    cond do
      status == 124 ->
        {:error, "desktop observer timed out\n#{diagnostics(output, log)}"}

      true ->
        {:ok, output}
    end
  end

  defp surfaces(output) do
    ~r/get_xdg_surface\(new id xdg_surface#(\d+), wl_surface#(\d+)\)/
    |> Regex.scan(output, capture: :all_but_first)
    |> Enum.uniq()
  end

  defp toplevel(output, xdg_surface) do
    regex =
      ~r/xdg_surface##{Regex.escape(xdg_surface)}\.get_toplevel\(new id xdg_toplevel#(\d+)\)/

    case Regex.run(regex, output, capture: :all_but_first) do
      [toplevel] -> {:ok, toplevel}
      nil -> :error
    end
  end

  defp configured?(output, xdg_surface, toplevel) do
    Regex.match?(~r/xdg_toplevel##{Regex.escape(toplevel)}\.configure\(/, output) and
      Regex.match?(~r/xdg_surface##{Regex.escape(xdg_surface)}\.ack_configure\(/, output)
  end

  defp presented?(output, wl_surface) do
    attach = ~r/wl_surface##{Regex.escape(wl_surface)}\.attach\(wl_buffer#/
    commit = ~r/wl_surface##{Regex.escape(wl_surface)}\.commit\(\)/

    with [{attach_index, attach_length}] <- Regex.run(attach, output, return: :index),
         remainder <-
           binary_part(
             output,
             attach_index + attach_length,
             byte_size(output) - attach_index - attach_length
           ) do
      Regex.match?(commit, remainder)
    else
      _ -> false
    end
  end

  defp tools do
    [:weston, :timeout, :env]
    |> Enum.reduce_while({:ok, %{}}, fn name, {:ok, tools} ->
      case System.find_executable(Atom.to_string(name)) do
        nil -> {:halt, {:error, "#{name} executable is required for desktop startup tests"}}
        path -> {:cont, {:ok, Map.put(tools, name, path)}}
      end
    end)
  end

  defp temporary_runtime do
    path =
      Path.join(
        System.tmp_dir!(),
        "rekindle-wayland-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(path)
    File.chmod!(path, 0o700)
    path
  end

  defp duration(milliseconds), do: "#{milliseconds / 1_000}s"

  defp diagnostics(output, log) do
    [output, if(File.regular?(log), do: File.read!(log), else: "")]
    |> Enum.join("\n")
    |> String.slice(0, 8_000)
  end
end
