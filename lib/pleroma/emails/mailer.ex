# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Emails.Mailer do
  @moduledoc """
  Defines the Pleroma mailer.

  The module contains functions to delivery email using Swoosh.Mailer.
  """

  alias Pleroma.Workers.MailerWorker
  alias Swoosh.DeliveryError

  @otp_app :pleroma
  @mailer_config [otp: :pleroma]

  @spec enabled?() :: boolean()
  def enabled?, do: Pleroma.Config.get([__MODULE__, :enabled])

  @doc "add email to queue"
  def deliver_async(email, config \\ []) do
    encoded_email =
      email
      |> :erlang.term_to_binary()
      |> Base.encode64()

    MailerWorker.new(%{"op" => "email", "encoded_email" => encoded_email, "config" => config})
    |> Oban.insert()
  end

  @doc "callback to perform send email from queue"
  def perform(:deliver_async, email, config), do: deliver(email, config)

  @spec deliver(Swoosh.Email.t(), Keyword.t()) :: {:ok, term} | {:error, term}
  def deliver(email, config \\ [])

  def deliver(email, config) do
    # Swoosh HTTP adapters use Hackney, which otherwise trusts its certifi bundle
    email =
      Swoosh.Email.put_private(email, :hackney_options,
        ssl_options: Pleroma.HTTP.TLS.ssl_options()
      )

    case enabled?() do
      true -> Swoosh.Mailer.deliver(email, parse_config(config))
      false -> {:error, :deliveries_disabled}
    end
  end

  @spec deliver!(Swoosh.Email.t(), Keyword.t()) :: term | no_return
  def deliver!(email, config \\ [])

  def deliver!(email, config) do
    case deliver(email, config) do
      {:ok, result} -> result
      {:error, reason} -> raise DeliveryError, reason: reason
    end
  end

  @on_load :validate_dependency

  @doc false
  def validate_dependency do
    parse_config([])
    |> Keyword.get(:adapter)
    |> Swoosh.Mailer.validate_dependency()
  end

  defp parse_config(config) do
    @otp_app
    |> Swoosh.Mailer.parse_config(__MODULE__, @mailer_config, config)
    |> put_mua_cacertfile()
  end

  @doc false
  # Mua otherwise trusts the OS CA store. Keep a CA that the admin set.
  def put_mua_cacertfile(config) do
    ssl = Keyword.get(config, :ssl, [])

    if config[:adapter] == Swoosh.Adapters.Mua and
         not Keyword.has_key?(ssl, :cacertfile) and not Keyword.has_key?(ssl, :cacerts) do
      Keyword.put(config, :ssl, [{:cacertfile, CAStore.file_path()} | ssl])
    else
      config
    end
  end
end
