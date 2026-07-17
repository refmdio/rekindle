defmodule Rekindle.AdmittedSealStaticTest do
  use ExUnit.Case, async: true

  test "the admission boundary exposes only construction and verified consumption" do
    functions = Rekindle.AdmittedSeal.__info__(:functions)

    assert {:admit, 2} in functions
    assert {:fetch, 1} in functions

    refute Enum.any?(functions, fn {name, _arity} ->
             name in [:activate, :publish, :project, :export]
           end)
  end
end
