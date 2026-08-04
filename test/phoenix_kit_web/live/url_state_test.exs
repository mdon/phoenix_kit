defmodule PhoenixKitWeb.Live.UrlStateTest do
  @moduledoc """
  Codec tests for `PhoenixKitWeb.Live.UrlState`.

  Encoding and decoding are pure functions over maps, so they need no database
  — which is what makes the URL-state contract cheap to pin.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitWeb.Live.UrlState

  defp cfg(params \\ nil, opts \\ []) do
    params =
      params ||
        [
          search_query: [default: "", url_key: "q", alias: "search"],
          filter_role: [default: "all", url_key: "role"],
          sort_dir: [default: :desc, cast: :atom, in: [:asc, :desc]],
          archived: [default: false, cast: :boolean],
          page: [default: 1, cast: :integer, min: 1]
        ]

    UrlState.normalize!(params, opts)
  end

  describe "normalize!/2" do
    test "requires a default for every param" do
      assert_raise ArgumentError, ~r/is missing :default/, fn ->
        cfg(q: [url_key: "q"])
      end
    end

    test "refuses cast: :atom without an :in whitelist" do
      assert_raise ArgumentError, ~r/requires\s+:in/, fn ->
        cfg(sort_dir: [default: :desc, cast: :atom])
      end
    end

    test "rejects an unsupported cast" do
      assert_raise ArgumentError, ~r/unsupported cast/, fn ->
        cfg(page: [default: 1, cast: :float])
      end
    end

    test "rejects two params claiming the same URL key" do
      assert_raise ArgumentError, ~r/duplicate URL keys/, fn ->
        cfg(a: [default: "", url_key: "q"], b: [default: "", url_key: "q"])
      end
    end

    test "rejects an empty spec" do
      assert_raise ArgumentError, ~r/non-empty :params/, fn -> cfg([]) end
    end

    test "detects :page as the page param, and honours :page_param false" do
      assert cfg().page_param == :page
      assert cfg(nil, page_param: false).page_param == false
      assert cfg(q: [default: ""]).page_param == false
    end

    test "rejects a :page_param that is not declared" do
      assert_raise ArgumentError, ~r/is not declared/, fn ->
        cfg([q: [default: ""]], page_param: :page)
      end
    end

    test "defaults dead_render to :call and validates it" do
      assert cfg().dead_render == :call
      assert cfg(nil, dead_render: :skip).dead_render == :skip

      assert_raise ArgumentError, ~r/:dead_render must be/, fn ->
        cfg(nil, dead_render: :maybe)
      end
    end
  end

  describe "decode/2" do
    test "returns defaults for an empty query" do
      assert UrlState.decode(%{}, cfg()) == %{
               search_query: "",
               filter_role: "all",
               sort_dir: :desc,
               archived: false,
               page: 1
             }
    end

    test "reads a param through its url_key, not its assign name" do
      state = UrlState.decode(%{"q" => "ivan"}, cfg())
      assert state.search_query == "ivan"

      # the assign name is not a valid URL key
      assert UrlState.decode(%{"search_query" => "ivan"}, cfg()).search_query == ""
    end

    test "accepts a legacy alias so already-published links keep resolving" do
      assert UrlState.decode(%{"search" => "ivan"}, cfg()).search_query == "ivan"
    end

    test "prefers the canonical key when both it and the alias are present" do
      assert UrlState.decode(%{"q" => "new", "search" => "old"}, cfg()).search_query == "new"
    end

    test "casts integers and falls back to the default below :min" do
      assert UrlState.decode(%{"page" => "4"}, cfg()).page == 4
      assert UrlState.decode(%{"page" => "0"}, cfg()).page == 1
      assert UrlState.decode(%{"page" => "-2"}, cfg()).page == 1
      assert UrlState.decode(%{"page" => "abc"}, cfg()).page == 1
      assert UrlState.decode(%{"page" => "3junk"}, cfg()).page == 1
    end

    test "casts booleans from both 1/0 and true/false" do
      assert UrlState.decode(%{"archived" => "1"}, cfg()).archived == true
      assert UrlState.decode(%{"archived" => "true"}, cfg()).archived == true
      assert UrlState.decode(%{"archived" => "0"}, cfg()).archived == false
      assert UrlState.decode(%{"archived" => "nope"}, cfg()).archived == false
    end

    test "matches atoms against the whitelist without creating any" do
      forged = "pk_url_state_forged_direction"

      assert UrlState.decode(%{"sort_dir" => "asc"}, cfg()).sort_dir == :asc
      assert UrlState.decode(%{"sort_dir" => forged}, cfg()).sort_dir == :desc

      # the forged value must not have become an atom
      assert_raise ArgumentError, fn -> String.to_existing_atom(forged) end
    end

    test "honours an :in whitelist for strings" do
      spec = cfg(status: [default: "any", in: ~w(any open closed)])
      assert UrlState.decode(%{"status" => "open"}, spec).status == "open"
      assert UrlState.decode(%{"status" => "hacked"}, spec).status == "any"
    end

    test "ignores non-binary values, such as a nested form map" do
      assert UrlState.decode(%{"q" => %{"nested" => "x"}}, cfg()).search_query == ""
    end

    test "survives params that are not a map at all" do
      assert UrlState.decode(:not_mounted_at_router, cfg()).page == 1
    end
  end

  describe "encode/3" do
    test "omits every value equal to its default" do
      state = UrlState.decode(%{}, cfg())
      assert UrlState.encode(state, cfg()) == %{}
    end

    test "writes non-defaults under the canonical url_key" do
      state = UrlState.decode(%{"q" => "ivan", "page" => "3"}, cfg())

      assert UrlState.encode(state, cfg()) == %{"q" => "ivan", "page" => "3"}
    end

    test "never writes the alias, so links converge on the canonical key" do
      state = UrlState.decode(%{"search" => "ivan"}, cfg())
      encoded = UrlState.encode(state, cfg())

      assert encoded == %{"q" => "ivan"}
      refute Map.has_key?(encoded, "search")
    end

    test "stringifies atoms and booleans" do
      state = UrlState.decode(%{"sort_dir" => "asc", "archived" => "1"}, cfg())

      assert UrlState.encode(state, cfg()) == %{"sort_dir" => "asc", "archived" => "true"}
    end

    test "keeps unknown query keys so an unrelated param is not dropped" do
      state = UrlState.decode(%{"q" => "ivan"}, cfg())

      assert UrlState.encode(state, cfg(), %{"action" => "add"}) == %{
               "q" => "ivan",
               "action" => "add"
             }
    end

    test "clears a key that returned to its default" do
      state = UrlState.decode(%{"q" => "ivan"}, cfg())
      back_to_default = %{state | search_query: ""}

      assert UrlState.encode(back_to_default, cfg(), %{"q" => "ivan"}) == %{}
    end
  end

  describe "build_path/4" do
    test "yields a bare path when nothing differs from the defaults" do
      state = UrlState.decode(%{}, cfg())

      assert UrlState.build_path("/admin/users", state, cfg()) == "/admin/users"
    end

    test "appends an encoded query otherwise" do
      state = UrlState.decode(%{"q" => "ivan petrov", "page" => "2"}, cfg())
      path = UrlState.build_path("/admin/users", state, cfg())

      assert path =~ "/admin/users?"
      assert path =~ "q=ivan+petrov"
      assert path =~ "page=2"
    end

    test "preserves the path it is given, including a locale segment" do
      state = UrlState.decode(%{"q" => "ivan"}, cfg())

      assert UrlState.build_path("/uk/admin/users", state, cfg()) == "/uk/admin/users?q=ivan"
    end
  end

  describe "round trip" do
    test "decode(encode(state)) is the identity for every declared param" do
      original = UrlState.decode(%{"q" => "ivan", "role" => "admin", "sort_dir" => "asc"}, cfg())

      round_tripped =
        original
        |> UrlState.encode(cfg())
        |> UrlState.decode(cfg())

      assert round_tripped == original
    end
  end
end
