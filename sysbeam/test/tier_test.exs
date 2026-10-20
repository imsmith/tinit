defmodule Sysbeam.TierTest do
  use ExUnit.Case, async: true
  alias Sysbeam.Tier

  test "a quick death doubles the delay, capped at a minute" do
    assert Tier.next_backoff(500, 1_000) == 2_000
    assert Tier.next_backoff(500, 40_000) == 60_000
    assert Tier.next_backoff(500, 60_000) == 60_000
  end

  test "a child that lived long enough resets the delay" do
    assert Tier.next_backoff(10_000, 60_000) == 1_000
  end
end
