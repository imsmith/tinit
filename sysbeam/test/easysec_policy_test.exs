defmodule Sysbeam.Easysec.PolicyTest do
  use ExUnit.Case, async: true
  alias Sysbeam.Easysec.Policy

  test "worker argv drops every capability not kept, then execs sysbeam" do
    argv = Policy.exec(%{caps: ["net_admin"], pids_max: 64}, ["worker", "0"])

    assert ["capsh", "--drop=" <> drop, "--no-new-privs", "--shell=/sbin/sysbeam", "--", "worker", "0"] = argv
    dropped = String.split(drop, ",")
    assert "cap_sys_admin" in dropped
    refute "cap_net_admin" in dropped
    # kernel 6.18 has capabilities 0..40
    assert length(dropped) == 40
  end
end
