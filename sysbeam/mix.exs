defmodule Sysbeam.MixProject do
  use Mix.Project

  def project do
    [
      app: :sysbeam,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: true,
      # Tests cover pure modules; booting the app would mount filesystems.
      aliases: [test: "test --no-start"],
      releases: [
        # ERTS comes from the image's /usr/lib/erlang (Buildroot), not the release.
        sysbeam: [include_erts: false, include_executables_for: [], strip_beams: true]
      ]
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {Sysbeam.Application, []}]
  end
end
