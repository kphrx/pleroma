# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Signature do
  @behaviour Pleroma.Signature.API
  @behaviour HTTPSignatures.Adapter

  alias Pleroma.EctoType.ActivityPub.ObjectValidators
  alias Pleroma.Keys
  alias Pleroma.User
  alias Pleroma.Web.ActivityPub.ActivityPub

  import Plug.Conn, only: [put_req_header: 3]

  @http_signatures_impl Application.compile_env(
                          :pleroma,
                          [__MODULE__, :http_signatures_impl],
                          HTTPSignatures
                        )

  @known_suffixes ["/publickey", "/main-key"]

  def key_id_to_actor_id(key_id) do
    uri =
      key_id
      |> URI.parse()
      |> Map.put(:fragment, nil)
      |> remove_suffix(@known_suffixes)

    maybe_ap_id = URI.to_string(uri)

    case ObjectValidators.ObjectID.cast(maybe_ap_id) do
      {:ok, ap_id} ->
        {:ok, ap_id}

      _ ->
        case Pleroma.Web.WebFinger.finger(maybe_ap_id) do
          {:ok, %{"ap_id" => ap_id}} -> {:ok, ap_id}
          _ -> {:error, maybe_ap_id}
        end
    end
  end

  defp remove_suffix(uri, [test | rest]) do
    if not is_nil(uri.path) and String.ends_with?(uri.path, test) do
      Map.put(uri, :path, String.replace(uri.path, test, ""))
    else
      remove_suffix(uri, rest)
    end
  end

  defp remove_suffix(uri, []), do: uri

  def fetch_public_key(conn) do
    with {:ok, actor_id} <- get_actor_id(conn),
         {:ok, public_key} <- User.get_or_fetch_public_key_for_ap_id(actor_id) do
      {:ok, public_key}
    else
      e ->
        {:error, e}
    end
  end

  def refetch_public_key(conn) do
    with {:ok, actor_id} <- get_actor_id(conn),
         {:ok, _user} <- ActivityPub.make_user_from_ap_id(actor_id),
         {:ok, public_key} <- User.get_public_key_for_ap_id(actor_id) do
      {:ok, public_key}
    else
      e ->
        {:error, e}
    end
  end

  def get_actor_id(conn) do
    with %{"keyId" => kid} <- HTTPSignatures.signature_for_conn(conn),
         {:ok, actor_id} <- key_id_to_actor_id(kid) do
      {:ok, actor_id}
    else
      e ->
        {:error, e}
    end
  end

  def sign(%User{keys: keys} = user, headers) do
    with {:ok, private_key, _} <- Keys.keys_from_pem(keys) do
      HTTPSignatures.sign(private_key, user.ap_id <> "#main-key", headers)
    end
  end

  def signed_date, do: signed_date(NaiveDateTime.utc_now())

  def signed_date(%NaiveDateTime{} = date) do
    Timex.format!(date, "{WDshort}, {0D} {Mshort} {YYYY} {h24}:{m}:{s} GMT")
  end

  @doc """
  Checks the parts of an incoming signature that the cryptographic check does
  not cover, so that a captured request cannot be replayed later or with a
  different body.

  The signature must cover `date` or `(created)`, and the signed time must be
  within the configured window. Requests other than GET and HEAD must also
  sign `digest`, and DigestPlug must have hashed their body. Based on Akkoma's http_signatures fork and Mastodon's
  SignedRequest.
  """
  @spec check_signature_policy(Plug.Conn.t(), DateTime.t()) :: :ok | {:error, atom()}
  def check_signature_policy(%Plug.Conn{} = conn, now \\ DateTime.utc_now()) do
    signature = HTTPSignatures.signature_for_conn(conn)
    signed = Map.get(signature, "headers", [])

    cond do
      "date" not in signed and "(created)" not in signed ->
        {:error, :date_not_signed}

      conn.method not in ["GET", "HEAD"] and "digest" not in signed ->
        {:error, :digest_not_signed}

      # The plug puts the digest computed by DigestPlug into the header. With
      # no computed digest (e.g. multipart), nothing checked the body.
      conn.method not in ["GET", "HEAD"] and is_nil(conn.assigns[:digest]) ->
        {:error, :body_not_hashed}

      true ->
        with :ok <- check_signed_date(conn, signed, now) do
          check_signed_created(signature, signed, now)
        end
    end
  end

  defp check_signed_date(conn, signed, now) do
    if "date" in signed do
      # Exactly one header: a second one could make this check and the
      # signature check see different dates.
      with [date] <- Plug.Conn.get_req_header(conn, "date"),
           {:ok, %DateTime{} = date} <- Timex.parse(date, "{RFC1123}") do
        check_time_window(date, now)
      else
        _ -> {:error, :invalid_date}
      end
    else
      :ok
    end
  end

  defp check_signed_created(signature, signed, now) do
    if "(created)" in signed do
      with created when is_binary(created) <- signature["created"],
           {created, ""} <- Integer.parse(created),
           {:ok, created} <- DateTime.from_unix(created) do
        check_time_window(created, now)
      else
        _ -> {:error, :invalid_date}
      end
    else
      :ok
    end
  end

  defp check_time_window(signed_at, now) do
    age = DateTime.diff(now, signed_at)

    cond do
      age > Pleroma.Config.get([:activitypub, :signature_max_age], 7200) ->
        {:error, :date_too_old}

      -age > Pleroma.Config.get([:activitypub, :signature_max_clock_skew], 3600) ->
        {:error, :date_in_future}

      true ->
        :ok
    end
  end

  @spec validate_signature(Plug.Conn.t(), String.t()) :: boolean()
  def validate_signature(%Plug.Conn{} = conn, request_target) do
    # Newer drafts for HTTP signatures now use @request-target instead of the
    # old (request-target). We'll now support both for incoming signatures.
    conn =
      conn
      |> put_req_header("(request-target)", request_target)
      |> put_req_header("@request-target", request_target)

    @http_signatures_impl.validate_conn(conn) == true
  end

  @spec validate_signature(Plug.Conn.t()) :: boolean()
  def validate_signature(%Plug.Conn{} = conn) do
    # This (request-target) is non-standard, but many implementations do it
    # this way due to a misinterpretation of
    # https://datatracker.ietf.org/doc/html/draft-cavage-http-signatures-06
    # "path" was interpreted as not having the query, though later examples
    # show that it must be the absolute path + query. This behavior is kept to
    # make sure most software (Pleroma itself, Mastodon, and probably others)
    # do not break.
    request_target = Enum.join([String.downcase(conn.method), conn.request_path], " ")

    # This is the proper way to build the @request-target, as expected by
    # many HTTP signature libraries, clarified in the following draft:
    # https://www.ietf.org/archive/id/draft-ietf-httpbis-message-signatures-11.html#section-2.2.6
    # It is the same as before, but containing the query part as well.
    proper_target = Enum.join([request_target, "?", conn.query_string], "")

    cond do
      # Normal, non-standard behavior but expected by Pleroma and more.
      validate_signature(conn, request_target) ->
        true

      # Has query string and the previous one failed: let's try the standard.
      conn.query_string != "" ->
        validate_signature(conn, proper_target)

      # If there's no query string and signature fails, it's rotten.
      true ->
        false
    end
  end
end
