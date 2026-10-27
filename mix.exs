defmodule SipPhone.MixProject do
  use Mix.Project

  def project do
    [
      app: :sip_phone,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: [
        main: "SipPhone",
        extras: ["README.md": [title: "SIP-телефон"]]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {SipPhone.Application, []}
    ]
  end

  defp deps do
    [
      {:plug_cowboy, "~> 2.7"},
      {:websock_adapter, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end
