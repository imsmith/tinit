defmodule Sysbeam.Ltd.ConfigTest do
  use ExUnit.Case
  alias Sysbeam.Ltd.Config

  @view %{hostname: "roundtrip", sysctl: %{"kernel.panic" => "10", "net.ipv4.ip_forward" => "1"}, boot: %{"cmdline" => "console=ttyS0 panic=1 quiet"}}

  setup do
    path = Path.join(System.tmp_dir!(), "ltd-test-#{System.unique_integer([:positive])}.tcl")
    on_exit(fn -> File.rm(path); File.rm(path <> ".tmp") end)
    {:ok, path: path}
  end

  test "save renders Tcl that loads back to the same view", %{path: path} do
    assert :ok = Config.save(@view, path)
    assert {:ok, @view} = Config.load(path)
    assert File.read!(path) =~ "hostname roundtrip\n"
    assert File.read!(path) =~ "boot cmdline {console=ttyS0 panic=1 quiet}\n"
  end

  test "config is real Tcl: computed values load", %{path: path} do
    File.write!(path, "set n 4\nhostname host[expr {$n * 2}]\nsysctl kernel.panic $n\n")
    assert {:ok, %{hostname: "host8", sysctl: %{"kernel.panic" => "4"}, boot: %{}}} = Config.load(path)
  end

  test "a file that does not evaluate is an error, not a crash", %{path: path} do
    File.write!(path, "hostname\n")
    assert {:error, msg} = Config.load(path)
    assert msg =~ "wrong # args"
  end
end
