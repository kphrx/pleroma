# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.ObjectValidators.UserValidatorTest do
  use ExUnit.Case, async: true

  alias Pleroma.Web.ActivityPub.ObjectValidators.UserValidator

  defp actor do
    "test/fixtures/users_mock/user.json"
    |> File.read!()
    |> String.replace("{{nickname}}", "lain")
    |> Jason.decode!()
  end

  test "accepts an actor whose endpoints and collections are on its own host" do
    data = actor()
    assert {:ok, ^data, []} = UserValidator.validate(data, [])
  end

  test "accepts an actor without optional fields" do
    data = Map.drop(actor(), ["endpoints", "featured", "followers", "following", "publicKey"])
    assert {:ok, _, _} = UserValidator.validate(data, [])
  end

  test "accepts all actor fixtures" do
    for path <- Path.wildcard("test/fixtures/**/*.json"),
        {:ok, %{"inbox" => _, "id" => id} = data} when is_binary(id) <-
          [Jason.decode(File.read!(path))] do
      assert {{:ok, _, _}, ^path} = {UserValidator.validate(data, []), path}
    end
  end

  test "treats empty and null fields as missing" do
    data =
      actor()
      |> Map.merge(%{"inbox" => "", "followers" => nil, "following" => "", "featured" => ""})
      |> put_in(["endpoints", "sharedInbox"], "")
      |> put_in(["publicKey", "id"], "")

    assert {:ok, _, _} = UserValidator.validate(data, [])
  end

  for field <- ["inbox", "followers", "following", "featured"] do
    test "rejects an actor whose #{field} is on another host" do
      data = Map.put(actor(), unquote(field), "https://victim.example/users/lain/x")
      assert {:error, _} = UserValidator.validate(data, [])
    end
  end

  test "rejects an actor whose sharedInbox is on another host" do
    data = put_in(actor(), ["endpoints", "sharedInbox"], "https://victim.example/inbox")
    assert {:error, _} = UserValidator.validate(data, [])
  end

  test "rejects an actor whose collection is an object on another host" do
    data = Map.put(actor(), "followers", %{"id" => "https://victim.example/users/v/followers"})
    assert {:error, _} = UserValidator.validate(data, [])
  end

  test "rejects an actor whose key id is on another host" do
    data = put_in(actor(), ["publicKey", "id"], "https://victim.example/users/lain#main-key")
    assert {:error, _} = UserValidator.validate(data, [])
  end

  test "rejects an actor whose key id has no host" do
    data = put_in(actor(), ["publicKey", "id"], "lain")
    assert {:error, _} = UserValidator.validate(data, [])
  end

  test "rejects an actor without an id" do
    assert {:error, _} = UserValidator.validate(Map.delete(actor(), "id"), [])
  end
end
