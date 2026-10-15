defmodule Sysbeam.PolicyStore do
  @moduledoc "easysec's security policy. Placeholder: a rule list, seeded with test data."
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)
  def add_rule(rule), do: GenServer.call(__MODULE__, {:add_rule, rule})
  def policies, do: GenServer.call(__MODULE__, :policies)

  @impl true
  def init(_) do
    rules = [
      %{action: :allow, subject: "worker", resource: "network", caps: [:net_admin]},
      %{action: :deny, subject: "worker", resource: "raw_socket", caps: []}
    ]

    Sysbeam.log("easysec", "policies loaded: #{inspect(rules)}")
    Sysbeam.log("easysec", "running -- policy enforcement active")
    {:ok, rules}
  end

  @impl true
  def handle_call({:add_rule, rule}, _from, rules), do: {:reply, :ok, [rule | rules]}
  def handle_call(:policies, _from, rules), do: {:reply, rules, rules}
end
