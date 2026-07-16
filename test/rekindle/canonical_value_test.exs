defmodule Rekindle.CanonicalValueTest do
  use ExUnit.Case, async: true

  alias Rekindle.CanonicalValue

  test "accepts the closed recursive value domain" do
    value = %{"boolean" => true, "integer" => -10, "list" => [nil, false, %{"x" => "y"}]}

    assert :ok = CanonicalValue.validate(value)
    assert CanonicalValue.valid?(value)
  end

  test "accepts the interoperable integer boundaries" do
    assert :ok = CanonicalValue.validate(-9_007_199_254_740_991)
    assert :ok = CanonicalValue.validate(9_007_199_254_740_991)

    assert {:error, %{code: :integer_out_of_range}} =
             CanonicalValue.validate(-9_007_199_254_740_992)

    assert {:error, %{code: :integer_out_of_range}} =
             CanonicalValue.validate(9_007_199_254_740_992)
  end

  test "rejects unsupported runtime values without creating atoms" do
    unsupported = [1.0, :value, {:tuple}, self(), fn -> :ok end, make_ref(), URI.parse("/")]

    for value <- unsupported do
      assert {:error, %{code: :unsupported_value}} = CanonicalValue.validate(value)
    end
  end

  test "requires string NFC map keys and reports the nested path" do
    assert {:error, %{code: :invalid_map_key, path: []}} = CanonicalValue.validate(%{atom: 1})

    assert {:error, %{code: :non_nfc_key, path: ["é"]}} =
             CanonicalValue.validate(%{"é" => 1})

    assert {:error, %{path: ["outer", 0]}} =
             CanonicalValue.validate(%{"outer" => [1.5]})
  end

  test "accepts proper lists without an undocumented collection bound" do
    for size <- [127, 128, 129, 256] do
      value = List.duplicate(%{"nested" => [nil, true, size]}, size)

      assert :ok = CanonicalValue.validate(value)
      assert {:ok, encoded} = CanonicalValue.encode(value)
      assert String.starts_with?(encoded, "[")
      assert String.ends_with?(encoded, "]")
    end
  end

  test "rejects improper lists before item traversal" do
    for {value, path} <- [
          {[1 | :improper_tail], []},
          {%{"nested" => [1 | :improper_tail]}, ["nested"]}
        ] do
      assert {:error,
              %{
                code: :unsupported_value,
                path: ^path,
                message: "list must be proper"
              }} = CanonicalValue.validate(value)

      refute CanonicalValue.valid?(value)

      assert {:error, %{code: :unsupported_value, path: ^path}} =
               CanonicalValue.encode(value)
    end
  end

  test "encodes maps in RFC 8785 UTF-16 property order" do
    value = %{"€" => 5, "\r" => 1, "😀" => 6, "1" => 2, "ö" => 4, "\u0080" => 3}

    assert {:ok, encoded} = CanonicalValue.encode(value)

    assert encoded ==
             "{\"\\r\":1,\"1\":2,\"\":3,\"ö\":4,\"€\":5,\"😀\":6}"
  end

  test "produces the domain-separated options digest" do
    value = %{"b" => [true, nil], "a" => 1}

    assert CanonicalValue.encode!(value) == ~s({"a":1,"b":[true,null]})

    assert CanonicalValue.options_digest!(value) ==
             "0f6e6d1ce31b22b0b4db59a021485668dcf633616d117a6466526b72bbf60214"
  end
end
