defmodule Rekindle.PublicationTest do
  use ExUnit.Case, async: true

  alias Rekindle.Publication

  test "reserves fresh temporary directories and files" do
    root = temporary_root()

    assert {:ok, first_directory} = Publication.temporary_directory(root, "directory-")
    assert {:ok, second_directory} = Publication.temporary_directory(root, "directory-")
    assert first_directory != second_directory
    assert File.dir?(first_directory)
    assert File.dir?(second_directory)

    assert {:ok, first_file} = Publication.temporary_file(root, "file-")
    assert {:ok, second_file} = Publication.temporary_file(root, "file-")
    assert first_file != second_file
    assert File.regular?(first_file)
    assert File.regular?(second_file)
  end

  test "serializes independent BEAM processes and releases after process exit" do
    root = temporary_root()
    ready = Path.join(root, "ready")
    port = lock_process(root, :publication_test, ready)

    on_exit(fn ->
      if Port.info(port), do: Port.close(port)
    end)

    wait_until(fn -> File.regular?(ready) end)

    assert {:error, {:publication_lock, :timeout}} =
             Publication.with_lock(root, :publication_test, fn -> :unexpected end, 50)

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    {_output, 0} = System.cmd("kill", ["-KILL", Integer.to_string(os_pid)])
    assert_receive {^port, {:exit_status, _status}}, 5_000

    assert :released =
             Publication.with_lock(root, :publication_test, fn -> :released end, 5_000)
  end

  defp lock_process(root, key, ready) do
    elixir = System.find_executable("elixir") || flunk("elixir executable is required")
    ebin = Rekindle.Publication |> :code.which() |> Path.dirname()
    arguments = :erlang.term_to_binary({root, key, ready}) |> Base.encode64()

    expression = """
    {root, key, ready} =
      #{inspect(arguments)}
      |> Base.decode64!()
      |> :erlang.binary_to_term()

    Rekindle.Publication.with_lock(root, key, fn ->
      File.write!(ready, "ready")
      Process.sleep(:infinity)
    end)
    """

    Port.open(
      {:spawn_executable, String.to_charlist(elixir)},
      [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: [~c"-pa", String.to_charlist(ebin), ~c"-e", String.to_charlist(expression)]
      ]
    )
  end

  defp wait_until(condition, attempts \\ 100)

  defp wait_until(condition, attempts) when attempts > 0 do
    if condition.() do
      :ok
    else
      Process.sleep(20)
      wait_until(condition, attempts - 1)
    end
  end

  defp wait_until(_condition, 0), do: flunk("independent lock process did not start")

  defp temporary_root do
    path =
      Path.join(
        System.tmp_dir!(),
        "rekindle-publication-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
