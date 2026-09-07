defmodule PhoenixKit.WebsiteAccess.Environment do
  @moduledoc """
  How this install is running — shown on the Website access page so the
  admin can tell a dev box from the live site, and offered a preset. It
  never switches anything on by itself.
  """

  alias PhoenixKit.Settings

  @type t :: %{
          runtime: :release | :mix,
          mix_env: String.t() | nil,
          hostname: String.t(),
          site_url: String.t() | nil,
          looks_like_dev?: boolean(),
          reasons: [{:mix_env | :hostname | :site_url, String.t()}]
        }

  @dev_words ~w(dev staging stage test local localhost sandbox preview)

  @spec read() :: t()
  def read do
    mix_env = mix_env()
    hostname = hostname()
    site_url = Settings.get_setting("site_url", "") |> String.trim()

    reasons =
      Enum.reject(
        [
          if(mix_env not in [nil, "prod"], do: {:mix_env, mix_env}),
          if(word_hit?(hostname), do: {:hostname, hostname}),
          if(site_url != "" and word_hit?(site_url), do: {:site_url, site_url})
        ],
        &is_nil/1
      )

    %{
      runtime: if(System.get_env("RELEASE_NAME"), do: :release, else: :mix),
      mix_env: mix_env,
      hostname: hostname,
      site_url: if(site_url == "", do: nil, else: site_url),
      looks_like_dev?: reasons != [],
      reasons: reasons
    }
  end

  # Read once at compile time: `Mix` is not in a release, and this is the
  # env the host was built under — which is what "how does this install
  # run" asks. The variable, when set, wins.
  @compile_env Atom.to_string(Mix.env())

  defp mix_env, do: System.get_env("MIX_ENV") || @compile_env

  defp hostname do
    {:ok, name} = :inet.gethostname()
    List.to_string(name)
  end

  defp word_hit?(value) do
    down = String.downcase(value)
    Enum.any?(@dev_words, &String.contains?(down, &1))
  end
end
