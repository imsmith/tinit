defmodule Sysbeam.Easysec.PolicyTest do
  use ExUnit.Case, async: true
  alias Sysbeam.Easysec.Policy

  test "worker args: join cgroup, drop all but kept caps, then role and index" do
    assert Policy.exec(%{caps: ["net_admin", "sys_boot"], pids_max: 64}, "/sys/fs/cgroup/easysec/worker-0", ["worker", "0"]) ==
             ["-c", "/sys/fs/cgroup/easysec/worker-0", "-d", "-k", "net_admin", "-k", "sys_boot", "worker", "0"]
  end

  test "a worker that keeps nothing still drops" do
    assert Policy.exec(%{caps: [], pids_max: 64}, "/cg", ["worker", "1"]) == ["-c", "/cg", "-d", "worker", "1"]
  end

  test "a worker with a console gets its tty" do
    assert Policy.exec(%{caps: [], pids_max: 1, console: "/dev/ttyS0"}, "/cg", ["worker", "0"]) ==
             ["-c", "/cg", "-d", "-t", "/dev/ttyS0", "worker", "0"]
  end
end
