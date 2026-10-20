defmodule Sysbeam.Ltd.ConfigTest do
  use ExUnit.Case
  alias Sysbeam.Ltd.Config

  @view %{hostname: "roundtrip", sysctl: %{"kernel.panic" => "10", "net.ipv4.ip_forward" => "1"}, modules: ["bridge", "wireguard"], bridges: %{"br0" => ["eth0", "eth1"]}, wireguard: %{"wg0" => %{port: 51820, key: "/etc/ltd/wg0.key", peers: %{"cGVlcg==" => %{allowed: ["10.0.0.2/32", "10.1.0.0/16"], endpoint: "192.168.7.2:51820", keepalive: nil}, "cGVlcjI=" => %{allowed: [], endpoint: nil, keepalive: 25}}}}, addresses: %{"wg0" => ["10.0.0.1/24"]}, boot: %{"cmdline" => "console=ttyS0 panic=1 quiet"}}

  setup do
    path = Path.join(System.tmp_dir!(), "ltd-test-#{System.unique_integer([:positive])}.tcl")
    on_exit(fn -> File.rm(path); File.rm(path <> ".tmp") end)
    {:ok, path: path}
  end

  test "save renders Tcl that loads back to the same view", %{path: path} do
    assert :ok = Config.save(@view, path)
    assert {:ok, @view} = Config.load(path)
    assert File.read!(path) =~ "hostname roundtrip\n"
    assert File.read!(path) =~ "module bridge\nmodule wireguard\nbridge br0 eth0 eth1\n"
    assert File.read!(path) =~ "wireguard wg0 -port 51820 -key /etc/ltd/wg0.key\npeer wg0 cGVlcg== -allowed {10.0.0.2/32 10.1.0.0/16} -endpoint 192.168.7.2:51820\npeer wg0 cGVlcjI= -allowed {} -keepalive 25\naddress wg0 10.0.0.1/24\n"
    assert File.read!(path) =~ "boot cmdline {console=ttyS0 panic=1 quiet}\n"
  end

  test "config is real Tcl: computed values load", %{path: path} do
    File.write!(path, "set n 4\nhostname host[expr {$n * 2}]\nsysctl kernel.panic $n\n")
    assert {:ok, %{hostname: "host8", sysctl: %{"kernel.panic" => "4"}, modules: [], bridges: %{}, wireguard: %{}, addresses: %{}, boot: %{}}} = Config.load(path)
  end

  test "an unknown peer option is an error from the loader", %{path: path} do
    File.write!(path, "hostname h\nwireguard wg0 -port 1 -key k\npeer wg0 cGVlcg== -allowd {1.2.3.4/32}\n")
    assert {:error, msg} = Config.load(path)
    assert msg =~ "peer: unknown option -allowd"
  end

  test "a file that does not evaluate is an error, not a crash", %{path: path} do
    File.write!(path, "hostname\n")
    assert {:error, msg} = Config.load(path)
    assert msg =~ "wrong # args"
  end
end
