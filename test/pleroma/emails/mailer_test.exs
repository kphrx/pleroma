# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Emails.MailerTest do
  use Pleroma.DataCase
  alias Pleroma.Emails.Mailer

  import Swoosh.TestAssertions

  @email %Swoosh.Email{
    from: {"Pleroma", "noreply@example.com"},
    html_body: "Test email",
    subject: "Pleroma test email",
    to: [{"Test User", "user1@example.com"}]
  }
  setup do: clear_config([Pleroma.Emails.Mailer, :enabled], true)

  test "not send email when mailer is disabled" do
    clear_config([Pleroma.Emails.Mailer, :enabled], false)
    Mailer.deliver(@email)
    :timer.sleep(100)

    refute_email_sent(
      from: {"Pleroma", "noreply@example.com"},
      to: [{"Test User", "user1@example.com"}],
      html_body: "Test email",
      subject: "Pleroma test email"
    )
  end

  test "send email" do
    Mailer.deliver(@email)
    :timer.sleep(100)

    assert_email_sent(
      from: {"Pleroma", "noreply@example.com"},
      to: [{"Test User", "user1@example.com"}],
      html_body: "Test email",
      subject: "Pleroma test email"
    )
  end

  test "perform" do
    Mailer.perform(:deliver_async, @email, [])
    :timer.sleep(100)

    assert_email_sent(
      from: {"Pleroma", "noreply@example.com"},
      to: [{"Test User", "user1@example.com"}],
      html_body: "Test email",
      subject: "Pleroma test email"
    )
  end

  test "keeps certificate checks for HTTP API adapters" do
    Mailer.deliver(@email)

    assert_received {:email, %Swoosh.Email{private: %{hackney_options: hackney_options}}}

    assert hackney_options[:ssl_options] ==
             Pleroma.HTTP.TLS.ssl_options()
  end

  describe "put_mua_cacertfile/1" do
    test "makes Mua trust the CAStore bundle" do
      config = Mailer.put_mua_cacertfile(adapter: Swoosh.Adapters.Mua, relay: "mail.example.com")

      assert config[:ssl] == [cacertfile: CAStore.file_path()]
      assert config[:relay] == "mail.example.com"
    end

    test "keeps other ssl options" do
      config = Mailer.put_mua_cacertfile(adapter: Swoosh.Adapters.Mua, ssl: [depth: 3])

      assert config[:ssl] == [cacertfile: CAStore.file_path(), depth: 3]
    end

    test "keeps a CA that the admin set" do
      config = [adapter: Swoosh.Adapters.Mua, ssl: [cacertfile: "/etc/ssl/smtp.pem"]]
      assert Mailer.put_mua_cacertfile(config) == config

      config = [adapter: Swoosh.Adapters.Mua, ssl: [cacerts: []]]
      assert Mailer.put_mua_cacertfile(config) == config
    end

    test "leaves other adapters alone" do
      config = [adapter: Swoosh.Adapters.SMTP, relay: "mail.example.com"]

      assert Mailer.put_mua_cacertfile(config) == config
    end
  end
end
