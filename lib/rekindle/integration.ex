defmodule Rekindle.Integration do
  @moduledoc false

  @spec dependency(:gpui | :egui | :slint) :: String.t()
  def dependency(:gpui), do: "gpui"
  def dependency(:egui), do: "eframe"
  def dependency(:slint), do: "slint"
end
