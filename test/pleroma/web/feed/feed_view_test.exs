# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.Feed.FeedViewTest do
  use Pleroma.DataCase, async: true

  alias Pleroma.Web.Feed.FeedView

  test "escapes fallback content" do
    data = %{
      "attachment" => [],
      "content" => "",
      "summary" => "<script>alert('feed')</script>"
    }

    expected = "&lt;script&gt;alert(&#39;feed&#39;)&lt;/script&gt;"

    assert FeedView.atom_content_encoded(data) == expected
    assert FeedView.rss_content_encoded(data) == expected
  end
end
