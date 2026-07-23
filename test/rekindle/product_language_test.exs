defmodule Rekindle.ProductLanguageTest do
  use ExUnit.Case, async: true

  alias Rekindle.ProductLanguage

  test "detects every closed identifier class without returning source bytes" do
    cases = [
      {join_words([word(:agent), word(:workbench)], " "), "language.internal_tool"},
      {join_words([word(:agent), word(:workbench)], "-"), "language.internal_tool"},
      {"." <> join_words([word(:agent), word(:workbench)], "-"), "language.internal_tool"},
      {join_words([word(:work), word(:unit)], " "), "language.workflow_pair"},
      {join_words([word(:review), word(:plan)], "-"), "language.workflow_pair"},
      {join_words([word(:review), word(:run)], " "), "language.workflow_pair"},
      {join_words([word(:review), word(:finding)], "-"), "language.workflow_pair"},
      {join_words([word(:source), word(:correction)], " "), "language.workflow_pair"},
      {List.to_string([82, 69, 81, 45, 49, 50]), "language.requirement_id"},
      {List.to_string([71, 65, 84, 69, 45, 65, 49, 45, 66]), "language.gate_id"},
      {word(:finding) <> "#42", "language.numbered_record"},
      {word(:closure) <> "-7", "language.numbered_record"},
      {List.to_string([70, 45, 48, 49]), "language.package_id"},
      {List.to_string([72, 45, 57, 57]), "language.package_id"},
      {List.to_string([80, 104, 97, 115, 101, 32, 51]), "language.numbered_label"},
      {List.to_string([84, 97, 115, 107, 45, 49, 50]), "language.numbered_label"}
    ]

    for {bytes, code} <- cases do
      assert {:error, [%{rule: ^code, location: location}]} =
               ProductLanguage.scan([surface(bytes)])

      assert location == %{kind: :generated, path: "client/output.txt", line: 1, column: 1}
      refute inspect(location) =~ bytes
    end
  end

  test "honors identifier boundaries and ordinary language" do
    embedded =
      List.to_string([120, 82, 69, 81, 45, 49, 121]) <>
        " " <>
        List.to_string([70, 45, 48, 49, 45, 120])

    ordinary =
      Enum.join(
        [word(:task), word(:phase), word(:finding), word(:review), word(:closure)],
        " "
      )

    assert :ok = ProductLanguage.scan([surface(embedded <> "\n" <> ordinary)])
  end

  test "reports deterministic byte locations and all occurrences" do
    first = List.to_string([82, 69, 81, 45, 49])
    second = List.to_string([70, 45, 48, 50])
    bytes = "safe\nxx " <> first <> "\n" <> second

    assert {:error, issues} = ProductLanguage.scan([surface(bytes)])

    assert Enum.map(issues, &{&1.rule, &1.location.line, &1.location.column}) == [
             {"language.requirement_id", 2, 4},
             {"language.package_id", 3, 1}
           ]
  end

  test "fails closed for invalid text and paths while admitting binary output" do
    assert {:error, [%{rule: "language.invalid_encoding"}]} =
             ProductLanguage.scan([%{surface(<<255>>) | text: true}])

    assert :ok = ProductLanguage.scan([%{surface(<<255>>) | text: false}])

    assert {:error, [%{rule: "language.input"}]} =
             ProductLanguage.scan([%{surface("safe") | path: "../outside"}])
  end

  test "skips only declared external bundle members" do
    bytes = List.to_string([82, 69, 81, 45, 49])

    external =
      surface(bytes) |> Map.put(:kind, :source_bundle) |> Map.put(:ownership, :third_party)

    owned = %{external | ownership: :rekindle}

    assert :ok = ProductLanguage.scan([external])
    assert {:error, [%{rule: "language.requirement_id"}]} = ProductLanguage.scan([owned])
  end

  test "scans selected paths and applies exact repository exclusions" do
    root = temporary_root()
    on_exit(fn -> File.rm_rf!(root) end)

    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/clean.ex"), "safe")
    excluded = Path.join(private_dir(), "notes.md")
    File.mkdir_p!(Path.dirname(Path.join(root, excluded)))
    File.write!(Path.join(root, excluded), List.to_string([82, 69, 81, 45, 49]))

    assert :ok = ProductLanguage.scan_paths(root, ["lib/clean.ex", excluded], :generated)
  end

  test "scans an inclusive commit interval" do
    root = temporary_root()
    on_exit(fn -> File.rm_rf!(root) end)
    git!(root, ["init", "-q"])
    git!(root, ["config", "user.email", "test@example.invalid"])
    git!(root, ["config", "user.name", "Test"])
    File.write!(Path.join(root, "sample"), "one")
    git!(root, ["add", "sample"])
    git!(root, ["commit", "-q", "-m", "safe subject"])
    first = git!(root, ["rev-parse", "HEAD"])
    File.write!(Path.join(root, "sample"), "two")
    git!(root, ["add", "sample"])
    subject = List.to_string([84, 97, 115, 107, 32, 57])
    git!(root, ["commit", "-q", "-m", subject])
    last = git!(root, ["rev-parse", "HEAD"])

    assert {:error, [%{rule: "language.numbered_label", location: %{kind: :commit}}]} =
             ProductLanguage.scan_commit_subjects(root, first, last)

    assert :ok = ProductLanguage.scan_commit_subjects(root, nil, nil)
  end

  test "its implementation and tests satisfy the same scanner" do
    root = File.cwd!()

    assert :ok =
             ProductLanguage.scan_paths(
               root,
               ["lib/rekindle/product_language.ex", "test/rekindle/product_language_test.exs"],
               :tracked
             )
  end

  defp surface(bytes) do
    %{kind: :generated, path: "client/output.txt", bytes: bytes, text: true}
  end

  defp temporary_root do
    Path.join(System.tmp_dir!(), "rekindle-language-#{System.unique_integer([:positive])}")
    |> tap(&File.mkdir_p!/1)
  end

  defp git!(root, arguments) do
    {output, 0} = System.cmd("git", arguments, cd: root, stderr_to_stdout: true)
    String.trim(output)
  end

  defp private_dir,
    do:
      List.to_string([46, 97, 103, 101, 110, 116, 45, 119, 111, 114, 107, 98, 101, 110, 99, 104])

  defp join_words(words, separator), do: Enum.join(words, separator)

  defp word(:agent), do: List.to_string([97, 103, 101, 110, 116])
  defp word(:workbench), do: List.to_string([119, 111, 114, 107, 98, 101, 110, 99, 104])
  defp word(:work), do: List.to_string([119, 111, 114, 107])
  defp word(:unit), do: List.to_string([117, 110, 105, 116])
  defp word(:review), do: List.to_string([114, 101, 118, 105, 101, 119])
  defp word(:plan), do: List.to_string([112, 108, 97, 110])
  defp word(:run), do: List.to_string([114, 117, 110])
  defp word(:finding), do: List.to_string([102, 105, 110, 100, 105, 110, 103])
  defp word(:source), do: List.to_string([115, 111, 117, 114, 99, 101])
  defp word(:correction), do: List.to_string([99, 111, 114, 114, 101, 99, 116, 105, 111, 110])
  defp word(:closure), do: List.to_string([99, 108, 111, 115, 117, 114, 101])
  defp word(:task), do: List.to_string([116, 97, 115, 107])
  defp word(:phase), do: List.to_string([112, 104, 97, 115, 101])
end
