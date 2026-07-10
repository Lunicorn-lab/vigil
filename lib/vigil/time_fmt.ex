defmodule Vigil.TimeFmt do
  @moduledoc false

  @doc "Formats a non-negative duration in seconds as e.g. \"2d 8h\", \"28h\", \"45m\"."
  def duration(seconds) when is_integer(seconds) and seconds >= 0 do
    days = div(seconds, 86_400)
    hours = div(rem(seconds, 86_400), 3600)
    minutes = div(rem(seconds, 3600), 60)

    cond do
      days > 0 and hours > 0 -> "#{days}d #{hours}h"
      days > 0 -> "#{days}d"
      hours > 0 -> "#{hours}h"
      true -> "#{max(minutes, 0)}m"
    end
  end

  def ago(seconds), do: duration(seconds) <> " ago"
end
