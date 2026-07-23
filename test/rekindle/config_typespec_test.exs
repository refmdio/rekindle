defmodule Rekindle.ConfigTypespecTest do
  use ExUnit.Case, async: false

  @moduletag timeout: 120_000

  alias Rekindle.Config

  @normalized_structs [
    Rekindle.Config.Project,
    Rekindle.Config.BuildConfig,
    Rekindle.Config.WebTarget,
    Rekindle.Config.DesktopTarget,
    Rekindle.Config.ProcessPolicy,
    Rekindle.Config.CachePolicy,
    Rekindle.Config.EnvironmentPolicy,
    Rekindle.Config.DevConfig
  ]

  test "every normalized configuration struct publishes one closed t/0" do
    for module <- @normalized_structs do
      type = t_type(module)
      assert {:type, _, :map, fields} = type

      assert Enum.sort(exact_field_names(fields)) ==
               module |> struct() |> Map.keys() |> Enum.sort()

      assert length(fields) == map_size(struct(module))
      refute open_type?(type), "#{inspect(module)}.t/0 contains an open term or map"
    end
  end

  test "Config public results reference the normalized project type" do
    assert compact_spec(Config, :load, 2) ==
             "load(atom(),keyword())::{:ok,Rekindle.Config.Project.t()}|{:error,admission_error()}"

    assert compact_spec(Config, :normalize, 4) ==
             "normalize(atom(),keyword()|nil,keyword(),keyword())::{:ok,Rekindle.Config.Project.t()}|{:error,admission_error()}"
  end

  test "Dialyzer admits Config.load/2 and normalize/4 as Project-producing APIs" do
    root = temporary_root()
    on_exit(fn -> File.rm_rf!(root) end)
    File.mkdir_p!(root)

    source = Path.join(root, "config_typespec_fixture.ex")
    output = Path.join(root, "ebin")
    File.mkdir_p!(output)
    File.write!(source, fixture_source())

    project_ebin = Config |> :code.which() |> to_string() |> Path.dirname()

    {compile_output, 0} =
      System.cmd(
        elixirc!(),
        ["-pa", project_ebin, "--ignore-module-conflict", "-o", output, source],
        stderr_to_stdout: true
      )

    assert compile_output == ""

    fixture = Path.join(output, "Elixir.Rekindle.ConfigTypespecFixture.beam")
    {dialyzer_output, status} = dialyze(ensure_core_plt!(), fixture)
    assert status == 0, dialyzer_output
  end

  defp t_type(module) do
    assert {:ok, types} = Code.Typespec.fetch_types(module)

    assert {:type, {:t, type, []}} =
             Enum.find(types, fn
               {_visibility, {:t, _type, []}} -> true
               _other -> false
             end)

    type
  end

  defp exact_field_names(fields) do
    Enum.map(fields, fn
      {:type, _, :map_field_exact, [{:atom, _, name}, _type]} -> name
      field -> flunk("unexpected non-exact struct field: #{inspect(field)}")
    end)
  end

  defp open_type?({:type, _, name, []}) when name in [:any, :term, :map], do: true
  defp open_type?({:type, _, :map, :any}), do: true

  defp open_type?(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.any?(&open_type?/1)

  defp open_type?(value) when is_list(value), do: Enum.any?(value, &open_type?/1)
  defp open_type?(_value), do: false

  defp compact_spec(module, name, arity) do
    assert {:ok, specs} = Code.Typespec.fetch_specs(module)

    assert [spec] =
             Enum.find_value(specs, fn {key, entries} -> if key == {name, arity}, do: entries end)

    name
    |> Code.Typespec.spec_to_quoted(spec)
    |> Macro.to_string()
    |> String.replace(~r/\s+/, "")
  end

  defp fixture_source do
    """
    defmodule Rekindle.ConfigTypespecFixture do
      alias Rekindle.Config
      alias Rekindle.Config.{BuildConfig, DevConfig, Project}

      @spec load(atom(), keyword()) ::
              {:ok, Project.t()} | {:error, [Rekindle.ConfigError.t()]}
      def load(otp_app, options), do: Config.load(otp_app, options)

      @spec normalize(atom(), keyword(), keyword(), keyword()) ::
              {:ok, Project.t()} | {:error, [Rekindle.ConfigError.t()]}
      def normalize(otp_app, build, dev, options),
        do: Config.normalize(otp_app, build, dev, options)

      @spec parts(Project.t()) :: {BuildConfig.t(), DevConfig.t()}
      def parts(%Project{build: build, dev: dev}), do: {build, dev}
    end
    """
  end

  defp dialyze(plt, fixture) do
    arguments =
      ["-Wno_unknown", "-Wno_match", "--plt", plt, "--no_check_plt"] ++
        contract_beams() ++ [fixture]

    System.cmd(dialyzer!(), arguments,
      env: [{"ERL_LIBS", elixir_lib_root()}],
      stderr_to_stdout: true
    )
  end

  defp contract_beams do
    ([Rekindle, Config, Rekindle.ConfigError, Rekindle.TargetBackend, Rekindle.CanonicalValue] ++
       @normalized_structs)
    |> Enum.map(fn module -> module |> :code.which() |> to_string() end)
  end

  defp ensure_core_plt! do
    cache =
      Path.join([
        File.cwd!(),
        "_build",
        "test",
        "target_backend_static",
        "otp-#{System.otp_release()}-elixir-#{System.version()}.plt"
      ])

    unless File.regular?(cache) do
      File.mkdir_p!(Path.dirname(cache))
      temporary = cache <> ".#{System.unique_integer([:positive])}.tmp"

      {output, status} =
        System.cmd(
          dialyzer!(),
          [
            "-Wno_unknown",
            "--build_plt",
            "--apps",
            "erts",
            "kernel",
            "stdlib",
            "crypto",
            "compiler",
            "syntax_tools",
            "parsetools",
            "elixir",
            "--output_plt",
            temporary
          ],
          env: [{"ERL_LIBS", elixir_lib_root()}],
          stderr_to_stdout: true
        )

      assert status == 0, output
      File.rename!(temporary, cache)
    end

    cache
  end

  defp temporary_root do
    Path.join(System.tmp_dir!(), "rekindle-config-types-#{System.unique_integer([:positive])}")
  end

  defp elixir_lib_root,
    do: :elixir |> :code.lib_dir() |> to_string() |> Path.dirname()

  defp dialyzer!, do: System.find_executable("dialyzer") || flunk("dialyzer is unavailable")
  defp elixirc!, do: System.find_executable("elixirc") || flunk("elixirc is unavailable")
end
