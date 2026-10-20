defmodule Sysbeam.Easysec.PolicyFileTest do
  use ExUnit.Case
  alias Sysbeam.Easysec.Policy

  setup do
    path = Path.join(System.tmp_dir!(), "easysec-test-#{System.unique_integer([:positive])}.tcl")
    on_exit(fn -> File.rm(path) end)
    {:ok, path: path}
  end

  test "loads one worker per line with caps, pids_max and optional console", %{path: path} do
    File.write!(path, "worker 0 -caps {net_admin sys_boot} -pids_max 128 -console /dev/ttyS0\nworker 1 -caps {} -pids_max 64\n")

    assert {:ok,
            %{
              "0" => %{caps: ["net_admin", "sys_boot"], pids_max: 128, net: :allow, console: "/dev/ttyS0"},
              "1" => %{caps: [], pids_max: 64, net: :allow}
            }} = Policy.load(path)
  end

  test "policy is real Tcl: computed values load", %{path: path} do
    File.write!(path, "set n 2\nforeach i {0 1} { worker $i -caps {} -pids_max [expr {$n * 32}] }\n")
    assert {:ok, %{"0" => %{pids_max: 64}, "1" => %{pids_max: 64}}} = Policy.load(path)
  end

  test "a file that does not evaluate is an error", %{path: path} do
    File.write!(path, "worker 0 -caps\n")
    assert {:error, msg} = Policy.load(path)
    assert msg =~ "worker 0"
  end

  test "net deny loads; anything else is refused", %{path: path} do
    File.write!(path, "worker 1 -caps {} -pids_max 64 -net deny\n")
    assert {:ok, %{"1" => %{net: :deny}}} = Policy.load(path)
    File.write!(path, "worker 1 -caps {} -pids_max 64 -net maybe\n")
    assert {:error, msg} = Policy.load(path)
    assert msg =~ "-net must be allow or deny"
  end

  test "diff: a net change applies live beside pids_max" do
    old = %{"0" => %{caps: [], pids_max: 1, net: :allow}}
    assert Policy.diff(old, %{"0" => %{caps: [], pids_max: 2, net: :deny}}) == [{"0", :pids_max}, {"0", :net}]
    assert Policy.diff(old, %{"0" => %{caps: ["sys_boot"], pids_max: 1, net: :deny}}) == [{"0", :restart}]
  end

  test "a worker without pids_max is refused", %{path: path} do
    File.write!(path, "worker 0 -caps {}\n")
    assert {:error, msg} = Policy.load(path)
    assert msg =~ "pids_max"
  end

  test "pids_max must be a positive integer", %{path: path} do
    File.write!(path, "worker 0 -caps {} -pids_max lots\n")
    assert {:error, msg} = Policy.load(path)
    assert msg =~ "pids_max"
  end

  test "diff: pids_max applies live, caps or console mean a restart, new and gone workers are named" do
    old = %{"0" => %{caps: ["net_admin"], pids_max: 128, console: "/dev/ttyS0"}, "1" => %{caps: [], pids_max: 64}, "2" => %{caps: [], pids_max: 1}}
    new = %{"0" => %{caps: ["net_admin"], pids_max: 256, console: "/dev/ttyS0"}, "1" => %{caps: ["sys_boot"], pids_max: 64}, "3" => %{caps: [], pids_max: 1}}

    assert Policy.diff(old, new) == [{"0", :pids_max}, {"1", :restart}, {"2", :stop}, {"3", :start}]
  end
end
