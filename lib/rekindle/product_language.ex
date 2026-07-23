defmodule Rekindle.ProductLanguage do
  @moduledoc false

  @text_extensions ~w[.c .cc .css .eex .ex .exs .h .heex .html .js .json .md .rs .sh .toml .ts .txt .xml .yaml .yml]
  @text_names ~w[Cargo.lock Cargo.toml LICENSE Makefile mix.exs README README.md rust-toolchain.toml]
  @private_design_dir List.to_string([
                        46,
                        97,
                        103,
                        101,
                        110,
                        116,
                        45,
                        119,
                        111,
                        114,
                        107,
                        98,
                        101,
                        110,
                        99,
                        104
                      ])
  @excluded_roots [@private_design_dir, ".git", "_build", "deps", "target"]

  @type surface :: %{
          required(:bytes) => binary(),
          required(:kind) => atom(),
          required(:path) => String.t(),
          optional(:ownership) => :rekindle | :third_party,
          optional(:text) => boolean()
        }
  @type issue :: %{
          rule: String.t(),
          location: %{kind: atom(), path: String.t(), line: pos_integer(), column: pos_integer()}
        }

  @spec scan([surface()]) :: :ok | {:error, [issue()]}
  def scan(surfaces) when is_list(surfaces) do
    surfaces
    |> Enum.reduce_while({:ok, []}, &scan_one/2)
    |> case do
      {:ok, []} -> :ok
      {:ok, issues} -> {:error, Enum.sort_by(issues, &issue_key/1)}
      {:error, issues} -> {:error, Enum.sort_by(issues, &issue_key/1)}
    end
  end

  def scan(_surfaces), do: {:error, [surface_issue(:invalid_input, "<input>", "language.input")]}

  @spec scan_tracked(Path.t()) :: :ok | {:error, [issue()]}
  def scan_tracked(root) when is_binary(root) do
    with {:ok, paths} <- tracked_paths(root),
         {:ok, surfaces} <- read_paths(root, paths) do
      scan(surfaces)
    else
      {:error, issue} -> {:error, [issue]}
    end
  end

  @spec scan_paths(Path.t(), [Path.t()], atom()) :: :ok | {:error, [issue()]}
  def scan_paths(root, paths, kind) when is_binary(root) and is_list(paths) and is_atom(kind) do
    with {:ok, surfaces} <- read_paths(root, paths, kind) do
      scan(surfaces)
    else
      {:error, issue} -> {:error, [issue]}
    end
  end

  @spec scan_commit_subjects(Path.t(), String.t() | nil, String.t() | nil) ::
          :ok | {:error, [issue()]}
  def scan_commit_subjects(_root, nil, nil), do: :ok

  def scan_commit_subjects(root, first, last)
      when is_binary(root) and is_binary(first) and is_binary(last) do
    with true <- valid_revision?(first),
         true <- valid_revision?(last),
         {:ok, subjects} <- commit_subjects(root, first, last) do
      scan(subjects)
    else
      _ -> {:error, [surface_issue(:commit, "<range>", "language.commit_range")]}
    end
  end

  def scan_commit_subjects(_root, _first, _last),
    do: {:error, [surface_issue(:commit, "<range>", "language.commit_range")]}

  defp scan_one(surface, {:ok, issues}) when is_map(surface) do
    ownership = Map.get(surface, :ownership, :rekindle)
    kind = Map.get(surface, :kind)
    path = Map.get(surface, :path)
    bytes = Map.get(surface, :bytes)
    text? = Map.get(surface, :text, true)

    cond do
      ownership == :third_party and kind == :source_bundle ->
        {:cont, {:ok, issues}}

      ownership != :rekindle or not is_atom(kind) or not safe_path?(path) or not is_binary(bytes) or
          not is_boolean(text?) ->
        {:halt, {:error, [surface_issue(:invalid_input, "<surface>", "language.input") | issues]}}

      text? and not String.valid?(bytes) ->
        {:halt, {:error, [surface_issue(kind, path, "language.invalid_encoding") | issues]}}

      true ->
        found = find_issues(kind, path, bytes)
        {:cont, {:ok, found ++ issues}}
    end
  end

  defp scan_one(_surface, {:ok, issues}),
    do: {:halt, {:error, [surface_issue(:invalid_input, "<surface>", "language.input") | issues]}}

  defp find_issues(kind, path, bytes) do
    Enum.flat_map(rules(), fn {code, regex} ->
      regex
      |> Regex.scan(bytes, return: :index, capture: :first)
      |> Enum.map(fn [{offset, _length}] ->
        {line, column} = line_column(bytes, offset)
        %{rule: code, location: %{kind: kind, path: path, line: line, column: column}}
      end)
    end)
  end

  defp rules do
    left = "(?<![A-Za-z0-9_-])"
    right = "(?![A-Za-z0-9_-])"

    dotted =
      "." <>
        Enum.join(
          [points([97, 103, 101, 110, 116]), points([119, 111, 114, 107, 98, 101, 110, 99, 104])],
          "-"
        )

    joined =
      Enum.join(
        [points([97, 103, 101, 110, 116]), points([119, 111, 114, 107, 98, 101, 110, 99, 104])],
        "[- ]"
      )

    pairs =
      [
        [points([119, 111, 114, 107]), points([117, 110, 105, 116])],
        [points([114, 101, 118, 105, 101, 119]), points([112, 108, 97, 110])],
        [points([114, 101, 118, 105, 101, 119]), points([114, 117, 110])],
        [points([114, 101, 118, 105, 101, 119]), points([102, 105, 110, 100, 105, 110, 103])],
        [
          points([115, 111, 117, 114, 99, 101]),
          points([99, 111, 114, 114, 101, 99, 116, 105, 111, 110])
        ]
      ]
      |> Enum.map_join("|", fn words -> Enum.join(words, "[- ]") end)

    numbered =
      [points([102, 105, 110, 100, 105, 110, 103]), points([99, 108, 111, 115, 117, 114, 101])]
      |> Enum.join("|")

    [
      {"language.internal_tool",
       compile(left <> "(?:" <> Regex.escape(dotted) <> "|" <> joined <> ")" <> right, "i")},
      {"language.workflow_pair", compile(left <> "(?:" <> pairs <> ")" <> right, "i")},
      {"language.requirement_id", compile(left <> "REQ-[0-9]+" <> right)},
      {"language.gate_id", compile(left <> "GATE-[A-Z0-9-]+" <> right)},
      {"language.numbered_record",
       compile(left <> "(?:" <> numbered <> ")[ #-][0-9]+" <> right, "i")},
      {"language.package_id", compile(left <> "[FCUWDH]-[0-9]{2}" <> right)},
      {"language.numbered_label", compile(left <> "(?:Phase|Task)[ -][0-9]+" <> right)}
    ]
  end

  defp compile(source, options \\ ""), do: Regex.compile!(source, options)
  defp points(values), do: List.to_string(values)

  defp line_column(bytes, offset) do
    prefix = binary_part(bytes, 0, offset)
    lines = :binary.split(prefix, "\n", [:global])
    {length(lines), byte_size(List.last(lines)) + 1}
  end

  defp tracked_paths(root) do
    case System.cmd("git", ["ls-files", "-z"], cd: root, stderr_to_stdout: true) do
      {output, 0} ->
        paths =
          output
          |> :binary.split(<<0>>, [:global])
          |> Enum.reject(&(&1 == "" or excluded?(&1)))

        {:ok, paths}

      _ ->
        {:error, surface_issue(:tracked, "<repository>", "language.repository")}
    end
  rescue
    _ -> {:error, surface_issue(:tracked, "<repository>", "language.repository")}
  end

  defp read_paths(root, paths, kind \\ :tracked) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, surfaces} ->
      cond do
        not safe_path?(path) ->
          {:halt, {:error, surface_issue(kind, "<path>", "language.path")}}

        true ->
          case File.read(Path.join(root, path)) do
            {:ok, bytes} ->
              surface = %{kind: kind, path: path, bytes: bytes, text: text_path?(path)}
              {:cont, {:ok, [surface | surfaces]}}

            _ ->
              {:halt, {:error, surface_issue(kind, path, "language.read")}}
          end
      end
    end)
  end

  defp commit_subjects(root, first, last) do
    with {_, 0} <-
           System.cmd("git", ["merge-base", "--is-ancestor", first, last],
             cd: root,
             stderr_to_stdout: true
           ),
         {output, 0} <-
           System.cmd("git", ["rev-list", "--reverse", first <> ".." <> last],
             cd: root,
             stderr_to_stdout: true
           ),
         commits <- [first | String.split(output, "\n", trim: true)],
         true <- length(commits) <= 10_000 do
      read_subjects(root, commits)
    else
      _ -> {:error, :git}
    end
  rescue
    _ -> {:error, :git}
  end

  defp read_subjects(root, commits) do
    Enum.reduce_while(commits, {:ok, []}, fn commit, {:ok, surfaces} ->
      case System.cmd("git", ["show", "-s", "--format=%s", commit],
             cd: root,
             stderr_to_stdout: true
           ) do
        {subject, 0} ->
          surface = %{
            kind: :commit,
            path: commit,
            bytes: String.trim_trailing(subject, "\n"),
            text: true
          }

          {:cont, {:ok, [surface | surfaces]}}

        _ ->
          {:halt, {:error, :git}}
      end
    end)
  end

  defp valid_revision?(value),
    do: byte_size(value) in 7..64 and Regex.match?(~r/\A[0-9a-f]+\z/, value)

  defp safe_path?(value) when is_binary(value) do
    String.valid?(value) and value != "" and Path.type(value) == :relative and
      String.normalize(value, :nfc) == value and not Regex.match?(~r/\p{Cc}/u, value) and
      not String.contains?(value, ["\\", <<0>>]) and
      Path.split(value) |> Enum.all?(&(&1 not in ["", ".", ".."]))
  end

  defp safe_path?(_value), do: false

  defp excluded?(path) do
    segments = Path.split(path)

    case segments do
      [root | _] when root in @excluded_roots -> true
      ["crates", _crate, "target" | _] -> true
      ["client", ".rekindle", "target" | _] -> true
      _ -> false
    end
  end

  defp text_path?(path) do
    Path.basename(path) in @text_names or Path.extname(path) in @text_extensions
  end

  defp surface_issue(kind, path, code) do
    %{rule: code, location: %{kind: kind, path: path, line: 1, column: 1}}
  end

  defp issue_key(issue) do
    location = issue.location
    {Atom.to_string(location.kind), location.path, location.line, location.column, issue.rule}
  end
end
