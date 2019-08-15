# Pleroma: A lightweight social networking server
# Copyright © 2017-2019 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Application do
  import Cachex.Spec
  use Application

  @name Mix.Project.config()[:name]
  @version Mix.Project.config()[:version]
  @repository Mix.Project.config()[:source_url]
  @env Mix.env()

  def name, do: @name
  def version, do: @version
  def named_version, do: @name <> " " <> @version
  def repository, do: @repository

  def user_agent do
    info = "#{Pleroma.Web.base_url()} <#{Pleroma.Config.get([:instance, :email], "")}>"
    named_version() <> "; " <> info
  end

  # See http://elixir-lang.org/docs/stable/elixir/Application.html
  # for more information on OTP Applications
  def start(_type, _args) do
    Pleroma.Config.DeprecationWarnings.warn()
    setup_instrumenters()

    # Define workers and child supervisors to be supervised
    children =
      [
        Pleroma.Repo,
        Pleroma.Config.TransferTask,
        Pleroma.Emoji,
        Pleroma.Captcha,
        Pleroma.FlakeId,
        Pleroma.ScheduledActivityWorker
      ] ++
        cachex_children() ++
        hackney_pool_children() ++
        [
          Pleroma.Web.Federator.RetryQueue,
          Pleroma.Web.OAuth.Token.CleanWorker,
          Pleroma.Stats,
          %{
            id: :web_push_init,
            start: {Task, :start_link, [&Pleroma.Web.Push.init/0]},
            restart: :temporary
          },
          %{
            id: :federator_init,
            start: {Task, :start_link, [&Pleroma.Web.Federator.init/0]},
            restart: :temporary
          },
          %{
            id: :internal_fetch_init,
            start: {Task, :start_link, [&Pleroma.Web.ActivityPub.InternalFetchActor.init/0]},
            restart: :temporary
          }
        ] ++
        oauth_cleanup_child(oauth_cleanup_enabled?()) ++
        streamer_child(@env) ++
        chat_child(@env, chat_enabled?()) ++
        [
          Pleroma.Web.Endpoint,
          Pleroma.Gopher.Server
        ]

    # See http://elixir-lang.org/docs/stable/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Pleroma.Supervisor]
    result = Supervisor.start_link(children, opts)
    :ok = after_supervisor_start()
    result
  end

  defp setup_instrumenters do
    require Prometheus.Registry

    if Application.get_env(:prometheus, Pleroma.Repo.Instrumenter) do
      :ok =
        :telemetry.attach(
          "prometheus-ecto",
          [:pleroma, :repo, :query],
          &Pleroma.Repo.Instrumenter.handle_event/4,
          %{}
        )

      Pleroma.Repo.Instrumenter.setup()
    end

    Pleroma.Web.Endpoint.MetricsExporter.setup()
    Pleroma.Web.Endpoint.PipelineInstrumenter.setup()
    Pleroma.Web.Endpoint.Instrumenter.setup()
  end

  def enabled_hackney_pools do
    [:media] ++
      if Application.get_env(:tesla, :adapter) == Tesla.Adapter.Hackney do
        [:federation]
      else
        []
      end ++
      if Pleroma.Config.get([Pleroma.Upload, :proxy_remote]) do
        [:upload]
      else
        []
      end
  end

  defp cachex_children do
    [
      build_cachex("used_captcha", ttl_interval: seconds_valid_interval()),
      build_cachex("user", default_ttl: 25_000, ttl_interval: 1000, limit: 2500),
      build_cachex("object", default_ttl: 25_000, ttl_interval: 1000, limit: 2500),
      build_cachex("rich_media", default_ttl: :timer.minutes(120), limit: 5000),
      build_cachex("scrubber", limit: 2500),
      build_cachex("idempotency", expiration: idempotency_expiration(), limit: 2500)
    ]
  end

  defp idempotency_expiration,
    do: expiration(default: :timer.seconds(6 * 60 * 60), interval: :timer.seconds(60))

  defp seconds_valid_interval,
    do: :timer.seconds(Pleroma.Config.get!([Pleroma.Captcha, :seconds_valid]))

  defp build_cachex(type, opts),
    do: %{
      id: String.to_atom("cachex_" <> type),
      start: {Cachex, :start_link, [String.to_atom(type <> "_cache"), opts]},
      type: :worker
    }

  defp chat_enabled?, do: Pleroma.Config.get([:chat, :enabled])

  defp oauth_cleanup_enabled?,
    do: Pleroma.Config.get([:oauth2, :clean_expired_tokens], false)

  defp streamer_child(:test), do: []

  defp streamer_child(_) do
    [Pleroma.Web.Streamer]
  end

  defp oauth_cleanup_child(true),
    do: [Pleroma.Web.OAuth.Token.CleanWorker]

  defp oauth_cleanup_child(_), do: []

  defp chat_child(:test, _), do: []

  defp chat_child(_env, true) do
    [Pleroma.Web.ChatChannel.ChatChannelState]
  end

  defp chat_child(_, _), do: []

  defp hackney_pool_children do
    for pool <- enabled_hackney_pools() do
      options = Pleroma.Config.get([:hackney_pools, pool])
      :hackney_pool.child_spec(pool, options)
    end
  end

  defp after_supervisor_start do
    with digest_config <- Application.get_env(:pleroma, :email_notifications)[:digest],
         true <- digest_config[:active] do
      PleromaJobQueue.schedule(
        digest_config[:schedule],
        :digest_emails,
        Pleroma.DigestEmailWorker
      )
    end

    :ok
  end
end
