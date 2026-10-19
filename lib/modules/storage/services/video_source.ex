defmodule PhoenixKit.Modules.Storage.VideoSource do
  @moduledoc """
  What a video's renditions need to know about the file they are made from, read
  once with `ffprobe`: whether it is HDR, and how long it is.

  ## HDR

  A phone records HDR as 10-bit HEVC with an HLG (`arib-std-b67`) or PQ
  (`smpte2084`) transfer on BT.2020 primaries. A browser plays 8-bit H.264 in
  BT.709, so a rendition made by copying the pixels over keeps the HDR signal
  but loses what interprets it: 10-bit H.264 ("High 10") that most browsers
  refuse, and posters that come out washed out with blown highlights.

  A rendition of an HDR source is therefore **tone-mapped to SDR**
  (`tonemap_filter/0`): linear light, BT.709 primaries, Hable curve, 8-bit
  `yuv420p`. The original is stored untouched, HDR and all.

  ## Duration

  A still frame (the poster) is taken one second in, or halfway when the clip is
  shorter than two seconds; a frame asked for past the end is no frame at all,
  and FFmpeg then writes nothing yet reports success (`poster_second/1`).

  Everything here answers a safe default when `ffprobe` is missing or cannot read
  the file, so a rendition is still attempted exactly as before.
  """

  @hdr_transfers ~w(arib-std-b67 smpte2084)

  # 203 nits is the reference white of HDR in an SDR container (ITU-R BT.2408):
  # ordinary scene brightness lands where an SDR video puts it, and the
  # highlights, the sun for one, keep their detail instead of clipping.
  @tonemap "zscale=t=linear:npl=203,format=gbrpf32le,zscale=p=bt709," <>
             "tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p"

  @type t :: %{hdr?: boolean(), duration: float() | nil}

  @doc "What is known when nothing could be read: not HDR, no duration."
  @spec unknown() :: t()
  def unknown, do: %{hdr?: false, duration: nil}

  @doc "Reads the first video stream of the file at `path`."
  @spec probe(Path.t()) :: t()
  def probe(path) do
    args = [
      "-v",
      "error",
      "-select_streams",
      "v:0",
      "-show_entries",
      "stream=color_transfer:format=duration",
      "-of",
      "json",
      path
    ]

    case System.cmd("ffprobe", args) do
      {output, 0} -> parse(output)
      {_output, _status} -> unknown()
    end
  rescue
    # No `ffprobe` at all (`:enoent`).
    ErlangError -> unknown()
  end

  @doc false
  @spec parse(String.t()) :: t()
  def parse(json) do
    case Jason.decode(json) do
      {:ok, %{} = data} ->
        stream = data |> Map.get("streams") |> List.wrap() |> List.first() || %{}

        %{
          hdr?: Map.get(stream, "color_transfer") in @hdr_transfers,
          duration: data |> get_in(["format", "duration"]) |> duration()
        }

      _ ->
        unknown()
    end
  end

  defp duration(value) when is_binary(value) do
    case Float.parse(value) do
      {seconds, _rest} when seconds > 0 -> seconds
      _ -> nil
    end
  end

  defp duration(_value), do: nil

  @doc "The FFmpeg filters that turn an HDR picture into an SDR one (BT.709, 8-bit)."
  @spec tonemap_filter() :: String.t()
  def tonemap_filter, do: @tonemap

  @doc """
  When to take the poster, as FFmpeg's `-ss` value (`"00:00:01.000"`): one second
  in, or halfway for a clip shorter than two seconds, and one second when the
  length is not known.
  """
  @spec poster_second(t() | map()) :: String.t()
  def poster_second(%{duration: duration}) when is_number(duration) and duration > 0 do
    duration |> Kernel./(2) |> min(1.0) |> clock()
  end

  def poster_second(_source), do: clock(1.0)

  # Only ever 0 to 1 second, which is all a poster is taken from.
  defp clock(seconds) do
    millis = seconds |> Kernel.*(1000) |> round()

    "00:00:" <>
      String.pad_leading(Integer.to_string(div(millis, 1000)), 2, "0") <>
      "." <> String.pad_leading(Integer.to_string(rem(millis, 1000)), 3, "0")
  end
end
