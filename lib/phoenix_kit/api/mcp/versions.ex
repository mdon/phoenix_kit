defmodule PhoenixKit.API.MCP.Versions do
  @moduledoc """
  The MCP protocol revisions this server knows, and which of them it speaks.

  There is ONE table of known revisions (`@table`, newest first). Each revision
  has a profile: a map of feature flags. Everything that depends on the
  revision asks this module (`profile/1`, `feature?/2`) instead of comparing
  revision strings, so a revision is one row here and nowhere else.

  ## Flags

    * `:structured_content` - a `tools/call` result carries `structuredContent`;
    * `:output_schema` - a tool descriptor carries `outputSchema`;
    * `:tool_title` - a tool descriptor carries `title`;
    * `:server_title` - `serverInfo` carries `title`.

  Batching is not a flag: this server refuses a JSON-RPC batch under every
  revision (`PhoenixKit.API.MCP.Rpc`).

  ## Which revisions are served

  By default every known revision. The application environment narrows and
  orders that set, read at call time (so it needs no recompile and no restart
  of anything but the config change):

      config :phoenix_kit, :mcp_protocol_versions, ["2025-06-18", "2025-03-26"]

  The list is in preference order: `latest/0` is its head, and `negotiate/1`
  answers with it when the client asks for something this server does not
  serve. An entry that is not in the table is ignored; a list that ends up
  empty (or is not a list) is replaced by the default. Each of these is logged
  once per node, as a warning that names the key and never the value.

  A revision that is known but not enabled is answered like any unsupported
  one: HTTP 400 with JSON-RPC `-32600` on the `MCP-Protocol-Version` header, and
  a lower revision from `initialize`.

  ## Adding or retiring a revision

  Retire one without a code change: leave it out of `:mcp_protocol_versions`.
  Keep serving an older one when a newer one is added to the table: list the
  older ones there.

  Adding a revision is one `@table` entry with its flags, **when its wire format
  is one the code already produces** (the same envelope, the same handshake, the
  same result and descriptor shapes, differing at most in which of the flags
  above are on). A revision that changes the wire format in any other way (a
  different handshake, a new required field, another message shape; `2026-07-28`
  is such a revision) **cannot be added by data**: it needs code in the places
  that read the flags (`PhoenixKit.API.MCP`, `PhoenixKit.API.MCP.Shape`,
  `PhoenixKit.API.MCP.Rpc`), and a new flag where the code must branch.

  ## For hosts and tests

  `config :phoenix_kit, :mcp_extra_revisions, [{"2027-01-01", %{...flags}}]`
  adds revisions to the table, for a host that has to speak one before core
  does and for the tests of this mechanism. Flags that are left out are off;
  an entry with a bad version, bad flags or the version of a built-in row is
  ignored (the built-in row wins), with the same one-time warning.
  """

  require Logger

  @flags [:structured_content, :output_schema, :tool_title, :server_title]

  # No `MCP-Protocol-Version` header means this revision (the MCP rule).
  @implied "2025-03-26"

  # Newest first.
  @table [
    {"2025-11-25",
     %{structured_content: true, output_schema: true, tool_title: true, server_title: true}},
    {"2025-06-18",
     %{structured_content: true, output_schema: true, tool_title: true, server_title: true}},
    {"2025-03-26",
     %{structured_content: false, output_schema: false, tool_title: false, server_title: false}}
  ]

  @type version :: String.t()
  @type flag :: :structured_content | :output_schema | :tool_title | :server_title
  @type profile :: %{flag() => boolean()}

  @doc "The feature flags a profile has."
  @spec flags() :: [flag()]
  def flags, do: @flags

  @doc "The revision a request without an `MCP-Protocol-Version` header is taken to be."
  @spec implied() :: version()
  def implied, do: @implied

  @doc "Every revision in the table (the built-in ones and `:mcp_extra_revisions`), newest first."
  @spec known() :: [version()]
  def known, do: Enum.map(table(), &elem(&1, 0))

  @doc """
  The revisions this server speaks, in preference order.

  Every known revision unless `:mcp_protocol_versions` narrows or orders them.
  Never empty.
  """
  @spec supported() :: [version()]
  def supported do
    known = known()

    case Application.get_env(:phoenix_kit, :mcp_protocol_versions) do
      nil -> known
      configured -> restrict(configured, known)
    end
  end

  @doc "The most preferred revision this server speaks: the newest unless the configuration orders otherwise."
  @spec latest() :: version()
  def latest, do: hd(supported())

  @doc "Whether this server speaks `version`."
  @spec supported?(term()) :: boolean()
  def supported?(version), do: is_binary(version) and version in supported()

  @doc """
  The revision `initialize` answers with: what the client asked for when this
  server speaks it, else `latest/0`. Any term is accepted.
  """
  @spec negotiate(term()) :: version()
  def negotiate(requested) do
    if supported?(requested), do: requested, else: latest()
  end

  @doc "The profile of a known revision (enabled or not), `nil` for any other term."
  @spec profile(term()) :: profile() | nil
  def profile(version) when is_binary(version) do
    Enum.find_value(table(), fn {known, profile} -> if known == version, do: profile end)
  end

  def profile(_other), do: nil

  @doc "Whether the profile of `version` has `flag` on. A revision that is not known has none."
  @spec feature?(term(), flag()) :: boolean()
  def feature?(version, flag) when flag in @flags do
    case profile(version) do
      %{^flag => true} -> true
      _off_or_unknown -> false
    end
  end

  # --- the table --------------------------------------------------------------

  defp table do
    @table
    |> Enum.concat(extra_rows())
    |> Enum.sort_by(&elem(&1, 0), :desc)
  end

  defp extra_rows do
    case Application.get_env(:phoenix_kit, :mcp_extra_revisions, []) do
      rows when is_list(rows) ->
        {valid, invalid} = rows |> Enum.map(&extra_row/1) |> Enum.split_with(&(&1 != :invalid))

        if invalid != [] do
          warn_once(
            :extra_revisions,
            ":mcp_extra_revisions has an entry that is not {\"YYYY-MM-DD\", flags}; it is ignored."
          )
        end

        valid
        |> Enum.uniq_by(&elem(&1, 0))
        |> Enum.reject(fn {version, _profile} -> List.keymember?(@table, version, 0) end)

      _not_a_list ->
        warn_once(:extra_revisions, ":mcp_extra_revisions is not a list; it is ignored.")
        []
    end
  end

  defp extra_row({version, flags}) when is_binary(version) do
    if Regex.match?(~r/\A\d{4}-\d{2}-\d{2}\z/, version) and flags?(flags),
      do: {version, extra_profile(flags)},
      else: :invalid
  end

  defp extra_row(_other), do: :invalid

  defp flags?(flags), do: is_map(flags) or (is_list(flags) and Keyword.keyword?(flags))

  defp extra_profile(flags) do
    given = Map.new(flags)
    Map.new(@flags, fn flag -> {flag, Map.get(given, flag) == true} end)
  end

  # --- the enabled set --------------------------------------------------------

  defp restrict(configured, known) when is_list(configured) do
    {kept, ignored} = configured |> Enum.uniq() |> Enum.split_with(&(&1 in known))

    if ignored != [] do
      warn_once(
        :unknown_revision,
        ":mcp_protocol_versions has an entry that is not a known MCP revision; it is ignored."
      )
    end

    case kept do
      [] ->
        warn_once(
          :empty_revisions,
          ":mcp_protocol_versions enables no known MCP revision; every known revision is served."
        )

        known

      kept ->
        kept
    end
  end

  defp restrict(_not_a_list, known) do
    warn_once(
      :empty_revisions,
      ":mcp_protocol_versions is not a list of revisions; every known revision is served."
    )

    known
  end

  # Once per node: the key lives in `:persistent_term` until the node stops.
  defp warn_once(kind, text) do
    key = {__MODULE__, :warned, kind}

    if :persistent_term.get(key, false) == false do
      :persistent_term.put(key, true)
      Logger.warning("[PhoenixKit.API] MCP revisions: #{text}")
    end

    :ok
  end
end
