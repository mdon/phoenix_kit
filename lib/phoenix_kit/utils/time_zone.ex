defmodule PhoenixKit.Utils.TimeZone do
  @moduledoc """
  Timezone identity for users and for the site: the picker list, the label for
  a stored value, and the one place a `DateTime` is moved into someone's zone.

  ## Why IANA ids and not an offset

  This used to store an integer offset — `"2"` for a row labelled
  "UTC+2 (Kyiv, Athens, Helsinki, Cairo, Johannesburg)". A number cannot carry
  a location, and that broke in three compounding ways:

    * **The labels were winter times.** Kyiv, Athens, Helsinki and Cairo are
      all UTC+3 from spring to autumn, so for half the year the row named
      cities that were not on the offset it claimed.
    * **The rows mixed zones that only agree in winter.** Johannesburg is
      UTC+2 every day of the year; the other four are not. One row could not be
      right for all of them at once.
    * **A stored offset cannot follow DST.** Pick Helsinki in January and `"2"`
      is written down; come summer Helsinki is UTC+3 and every timestamp shown
      is an hour behind until the profile is edited by hand.

  An IANA id names the *place*. `Europe/Warsaw` is UTC+1 in January and UTC+2
  in August without anything being re-saved, and it stays correct while the
  person travels.

  ## Legacy values

  Rows written before this change still hold offsets, and they keep working:
  `shift/2` reads `"2"` as a fixed +2 exactly as before, so nobody's
  timestamps move underneath them. Such a value is **not** upgraded
  automatically — `"2"` is genuinely ambiguous between `Europe/Warsaw` in
  summer and `Africa/Johannesburg` in any season, and guessing would put a
  location on the account that its owner never chose. `legacy_offset?/1` marks
  them so the UI can ask.

  `"5.5"` and `"9.5"` also start shifting for the first time here. The old
  code parsed offsets with `Integer.parse/1` and required an empty remainder,
  so `"5.5"` left `".5"` over, failed the match, and returned the timestamp
  **unshifted** — every account on UTC+5:30 (Mumbai, Delhi, Kolkata, Colombo)
  or UTC+9:30 (Adelaide, Darwin) was silently reading UTC.

  ## The list

  `identifiers/0` is the IANA region list, aliases included. Aliases are kept
  on purpose: tzdata links `Europe/Oslo`, `Europe/Stockholm` and
  `Europe/Copenhagen` to `Europe/Berlin`, and dropping them to "canonical"
  entries would leave a Norwegian unable to find Oslo — the same complaint
  that started this ("Warsaw is missing"). Every id is asserted resolvable
  against the compiled tz database in `time_zone_test.exs`.
  """

  @database Tz.TimeZoneDatabase

  @identifiers [
    "Africa/Abidjan",
    "Africa/Accra",
    "Africa/Addis_Ababa",
    "Africa/Algiers",
    "Africa/Asmara",
    "Africa/Bamako",
    "Africa/Bangui",
    "Africa/Banjul",
    "Africa/Bissau",
    "Africa/Blantyre",
    "Africa/Brazzaville",
    "Africa/Bujumbura",
    "Africa/Cairo",
    "Africa/Casablanca",
    "Africa/Ceuta",
    "Africa/Conakry",
    "Africa/Dakar",
    "Africa/Dar_es_Salaam",
    "Africa/Djibouti",
    "Africa/Douala",
    "Africa/El_Aaiun",
    "Africa/Freetown",
    "Africa/Gaborone",
    "Africa/Harare",
    "Africa/Johannesburg",
    "Africa/Juba",
    "Africa/Kampala",
    "Africa/Khartoum",
    "Africa/Kigali",
    "Africa/Kinshasa",
    "Africa/Lagos",
    "Africa/Libreville",
    "Africa/Lome",
    "Africa/Luanda",
    "Africa/Lubumbashi",
    "Africa/Lusaka",
    "Africa/Malabo",
    "Africa/Maputo",
    "Africa/Maseru",
    "Africa/Mbabane",
    "Africa/Mogadishu",
    "Africa/Monrovia",
    "Africa/Nairobi",
    "Africa/Ndjamena",
    "Africa/Niamey",
    "Africa/Nouakchott",
    "Africa/Ouagadougou",
    "Africa/Porto-Novo",
    "Africa/Sao_Tome",
    "Africa/Timbuktu",
    "Africa/Tripoli",
    "Africa/Tunis",
    "Africa/Windhoek",
    "America/Adak",
    "America/Anchorage",
    "America/Anguilla",
    "America/Antigua",
    "America/Araguaina",
    "America/Argentina/Buenos_Aires",
    "America/Argentina/Catamarca",
    "America/Argentina/Cordoba",
    "America/Argentina/Jujuy",
    "America/Argentina/La_Rioja",
    "America/Argentina/Mendoza",
    "America/Argentina/Rio_Gallegos",
    "America/Argentina/Salta",
    "America/Argentina/San_Juan",
    "America/Argentina/San_Luis",
    "America/Argentina/Tucuman",
    "America/Argentina/Ushuaia",
    "America/Aruba",
    "America/Asuncion",
    "America/Atikokan",
    "America/Atka",
    "America/Bahia",
    "America/Bahia_Banderas",
    "America/Barbados",
    "America/Belem",
    "America/Belize",
    "America/Blanc-Sablon",
    "America/Boa_Vista",
    "America/Bogota",
    "America/Boise",
    "America/Cambridge_Bay",
    "America/Campo_Grande",
    "America/Cancun",
    "America/Caracas",
    "America/Cayenne",
    "America/Cayman",
    "America/Chicago",
    "America/Chihuahua",
    "America/Ciudad_Juarez",
    "America/Coral_Harbour",
    "America/Costa_Rica",
    "America/Coyhaique",
    "America/Creston",
    "America/Cuiaba",
    "America/Curacao",
    "America/Danmarkshavn",
    "America/Dawson",
    "America/Dawson_Creek",
    "America/Denver",
    "America/Detroit",
    "America/Dominica",
    "America/Edmonton",
    "America/Eirunepe",
    "America/El_Salvador",
    "America/Ensenada",
    "America/Fort_Nelson",
    "America/Fortaleza",
    "America/Glace_Bay",
    "America/Goose_Bay",
    "America/Grand_Turk",
    "America/Grenada",
    "America/Guadeloupe",
    "America/Guatemala",
    "America/Guayaquil",
    "America/Guyana",
    "America/Halifax",
    "America/Havana",
    "America/Hermosillo",
    "America/Indiana/Indianapolis",
    "America/Indiana/Knox",
    "America/Indiana/Marengo",
    "America/Indiana/Petersburg",
    "America/Indiana/Tell_City",
    "America/Indiana/Vevay",
    "America/Indiana/Vincennes",
    "America/Indiana/Winamac",
    "America/Inuvik",
    "America/Iqaluit",
    "America/Jamaica",
    "America/Juneau",
    "America/Kentucky/Louisville",
    "America/Kentucky/Monticello",
    "America/Kralendijk",
    "America/La_Paz",
    "America/Lima",
    "America/Los_Angeles",
    "America/Lower_Princes",
    "America/Maceio",
    "America/Managua",
    "America/Manaus",
    "America/Marigot",
    "America/Martinique",
    "America/Matamoros",
    "America/Mazatlan",
    "America/Menominee",
    "America/Merida",
    "America/Metlakatla",
    "America/Mexico_City",
    "America/Miquelon",
    "America/Moncton",
    "America/Monterrey",
    "America/Montevideo",
    "America/Montreal",
    "America/Montserrat",
    "America/Nassau",
    "America/New_York",
    "America/Nipigon",
    "America/Nome",
    "America/Noronha",
    "America/North_Dakota/Beulah",
    "America/North_Dakota/Center",
    "America/North_Dakota/New_Salem",
    "America/Nuuk",
    "America/Ojinaga",
    "America/Panama",
    "America/Pangnirtung",
    "America/Paramaribo",
    "America/Phoenix",
    "America/Port-au-Prince",
    "America/Port_of_Spain",
    "America/Porto_Acre",
    "America/Porto_Velho",
    "America/Puerto_Rico",
    "America/Punta_Arenas",
    "America/Rainy_River",
    "America/Rankin_Inlet",
    "America/Recife",
    "America/Regina",
    "America/Resolute",
    "America/Rio_Branco",
    "America/Santa_Isabel",
    "America/Santarem",
    "America/Santiago",
    "America/Santo_Domingo",
    "America/Sao_Paulo",
    "America/Scoresbysund",
    "America/Shiprock",
    "America/Sitka",
    "America/St_Barthelemy",
    "America/St_Johns",
    "America/St_Kitts",
    "America/St_Lucia",
    "America/St_Thomas",
    "America/St_Vincent",
    "America/Swift_Current",
    "America/Tegucigalpa",
    "America/Thule",
    "America/Thunder_Bay",
    "America/Tijuana",
    "America/Toronto",
    "America/Tortola",
    "America/Vancouver",
    "America/Virgin",
    "America/Whitehorse",
    "America/Winnipeg",
    "America/Yakutat",
    "America/Yellowknife",
    "Antarctica/Casey",
    "Antarctica/Davis",
    "Antarctica/DumontDUrville",
    "Antarctica/Macquarie",
    "Antarctica/Mawson",
    "Antarctica/McMurdo",
    "Antarctica/Palmer",
    "Antarctica/Rothera",
    "Antarctica/Syowa",
    "Antarctica/Troll",
    "Antarctica/Vostok",
    "Arctic/Longyearbyen",
    "Asia/Aden",
    "Asia/Almaty",
    "Asia/Amman",
    "Asia/Anadyr",
    "Asia/Aqtau",
    "Asia/Aqtobe",
    "Asia/Ashgabat",
    "Asia/Atyrau",
    "Asia/Baghdad",
    "Asia/Bahrain",
    "Asia/Baku",
    "Asia/Bangkok",
    "Asia/Barnaul",
    "Asia/Beirut",
    "Asia/Bishkek",
    "Asia/Brunei",
    "Asia/Chita",
    "Asia/Chongqing",
    "Asia/Colombo",
    "Asia/Damascus",
    "Asia/Dhaka",
    "Asia/Dili",
    "Asia/Dubai",
    "Asia/Dushanbe",
    "Asia/Famagusta",
    "Asia/Gaza",
    "Asia/Harbin",
    "Asia/Hebron",
    "Asia/Ho_Chi_Minh",
    "Asia/Hong_Kong",
    "Asia/Hovd",
    "Asia/Irkutsk",
    "Asia/Istanbul",
    "Asia/Jakarta",
    "Asia/Jayapura",
    "Asia/Jerusalem",
    "Asia/Kabul",
    "Asia/Kamchatka",
    "Asia/Karachi",
    "Asia/Kashgar",
    "Asia/Kathmandu",
    "Asia/Khandyga",
    "Asia/Kolkata",
    "Asia/Krasnoyarsk",
    "Asia/Kuala_Lumpur",
    "Asia/Kuching",
    "Asia/Kuwait",
    "Asia/Macau",
    "Asia/Magadan",
    "Asia/Makassar",
    "Asia/Manila",
    "Asia/Muscat",
    "Asia/Nicosia",
    "Asia/Novokuznetsk",
    "Asia/Novosibirsk",
    "Asia/Omsk",
    "Asia/Oral",
    "Asia/Phnom_Penh",
    "Asia/Pontianak",
    "Asia/Pyongyang",
    "Asia/Qatar",
    "Asia/Qostanay",
    "Asia/Qyzylorda",
    "Asia/Riyadh",
    "Asia/Sakhalin",
    "Asia/Samarkand",
    "Asia/Seoul",
    "Asia/Shanghai",
    "Asia/Singapore",
    "Asia/Srednekolymsk",
    "Asia/Taipei",
    "Asia/Tashkent",
    "Asia/Tbilisi",
    "Asia/Tehran",
    "Asia/Tel_Aviv",
    "Asia/Thimphu",
    "Asia/Tokyo",
    "Asia/Tomsk",
    "Asia/Ulaanbaatar",
    "Asia/Urumqi",
    "Asia/Ust-Nera",
    "Asia/Vientiane",
    "Asia/Vladivostok",
    "Asia/Yakutsk",
    "Asia/Yangon",
    "Asia/Yekaterinburg",
    "Asia/Yerevan",
    "Atlantic/Azores",
    "Atlantic/Bermuda",
    "Atlantic/Canary",
    "Atlantic/Cape_Verde",
    "Atlantic/Faroe",
    "Atlantic/Jan_Mayen",
    "Atlantic/Madeira",
    "Atlantic/Reykjavik",
    "Atlantic/South_Georgia",
    "Atlantic/St_Helena",
    "Atlantic/Stanley",
    "Australia/Adelaide",
    "Australia/Brisbane",
    "Australia/Broken_Hill",
    "Australia/Canberra",
    "Australia/Currie",
    "Australia/Darwin",
    "Australia/Eucla",
    "Australia/Hobart",
    "Australia/Lindeman",
    "Australia/Lord_Howe",
    "Australia/Melbourne",
    "Australia/Perth",
    "Australia/Sydney",
    "Australia/Yancowinna",
    "Europe/Amsterdam",
    "Europe/Andorra",
    "Europe/Astrakhan",
    "Europe/Athens",
    "Europe/Belfast",
    "Europe/Belgrade",
    "Europe/Berlin",
    "Europe/Bratislava",
    "Europe/Brussels",
    "Europe/Bucharest",
    "Europe/Budapest",
    "Europe/Busingen",
    "Europe/Chisinau",
    "Europe/Copenhagen",
    "Europe/Dublin",
    "Europe/Gibraltar",
    "Europe/Guernsey",
    "Europe/Helsinki",
    "Europe/Isle_of_Man",
    "Europe/Istanbul",
    "Europe/Jersey",
    "Europe/Kaliningrad",
    "Europe/Kirov",
    "Europe/Kyiv",
    "Europe/Lisbon",
    "Europe/Ljubljana",
    "Europe/London",
    "Europe/Luxembourg",
    "Europe/Madrid",
    "Europe/Malta",
    "Europe/Mariehamn",
    "Europe/Minsk",
    "Europe/Monaco",
    "Europe/Moscow",
    "Europe/Nicosia",
    "Europe/Oslo",
    "Europe/Paris",
    "Europe/Podgorica",
    "Europe/Prague",
    "Europe/Riga",
    "Europe/Rome",
    "Europe/Samara",
    "Europe/San_Marino",
    "Europe/Sarajevo",
    "Europe/Saratov",
    "Europe/Simferopol",
    "Europe/Skopje",
    "Europe/Sofia",
    "Europe/Stockholm",
    "Europe/Tallinn",
    "Europe/Tirane",
    "Europe/Tiraspol",
    "Europe/Ulyanovsk",
    "Europe/Vaduz",
    "Europe/Vatican",
    "Europe/Vienna",
    "Europe/Vilnius",
    "Europe/Volgograd",
    "Europe/Warsaw",
    "Europe/Zagreb",
    "Europe/Zurich",
    "Indian/Antananarivo",
    "Indian/Chagos",
    "Indian/Christmas",
    "Indian/Cocos",
    "Indian/Comoro",
    "Indian/Kerguelen",
    "Indian/Mahe",
    "Indian/Maldives",
    "Indian/Mauritius",
    "Indian/Mayotte",
    "Indian/Reunion",
    "Pacific/Apia",
    "Pacific/Auckland",
    "Pacific/Bougainville",
    "Pacific/Chatham",
    "Pacific/Chuuk",
    "Pacific/Easter",
    "Pacific/Efate",
    "Pacific/Fakaofo",
    "Pacific/Fiji",
    "Pacific/Funafuti",
    "Pacific/Galapagos",
    "Pacific/Gambier",
    "Pacific/Guadalcanal",
    "Pacific/Guam",
    "Pacific/Honolulu",
    "Pacific/Johnston",
    "Pacific/Kanton",
    "Pacific/Kiritimati",
    "Pacific/Kosrae",
    "Pacific/Kwajalein",
    "Pacific/Majuro",
    "Pacific/Marquesas",
    "Pacific/Midway",
    "Pacific/Nauru",
    "Pacific/Niue",
    "Pacific/Norfolk",
    "Pacific/Noumea",
    "Pacific/Pago_Pago",
    "Pacific/Palau",
    "Pacific/Pitcairn",
    "Pacific/Pohnpei",
    "Pacific/Port_Moresby",
    "Pacific/Rarotonga",
    "Pacific/Saipan",
    "Pacific/Samoa",
    "Pacific/Tahiti",
    "Pacific/Tarawa",
    "Pacific/Tongatapu",
    "Pacific/Wake",
    "Pacific/Wallis",
    "Pacific/Yap"
  ]

  @doc """
  Every selectable IANA identifier, sorted.
  """
  @spec identifiers() :: [String.t()]
  def identifiers, do: @identifiers

  @doc """
  The timezone database backing every lookup here.

  Passed explicitly to `DateTime.shift_zone/3` rather than set as
  `config :elixir, :time_zone_database`: this is a library, and a library
  reaching into the host's Elixir config to swap a global would decide for
  every other dependency in the app too.
  """
  @spec database() :: module()
  def database, do: @database

  @doc """
  Picker options as `{label, identifier}`, ordered by current UTC offset.

  Labels carry the offset as it is **right now** ("(UTC+02:00) Europe/Warsaw"),
  so the same zone reads +01:00 in January and +02:00 in August — which is the
  fact the old static labels got wrong. The identifier is shown verbatim
  because it is also what the browser reports, so a mismatch warning can name
  the two sides in the same vocabulary.
  """
  @spec options() :: [{String.t(), String.t()}]
  def options do
    now = DateTime.utc_now()

    @identifiers
    |> Enum.map(fn id -> {offset_seconds(now, id), id} end)
    |> Enum.sort_by(fn {offset, id} -> {offset, id} end)
    |> Enum.map(fn {offset, id} -> {"(UTC#{format_offset(offset)}) #{id}", id} end)
  end

  @doc """
  Human label for a stored value — an IANA id, a legacy offset, or nothing.

  ## Examples

      iex> PhoenixKit.Utils.TimeZone.label("Europe/Warsaw") =~ "Europe/Warsaw"
      true

      iex> PhoenixKit.Utils.TimeZone.label(nil)
      "Use System Default"

  """
  @spec label(String.t() | nil) :: String.t()
  def label(value) when value in [nil, ""], do: "Use System Default"

  def label(value) do
    cond do
      identifier?(value) ->
        "(UTC#{format_offset(offset_seconds(DateTime.utc_now(), value))}) #{value}"

      legacy_offset?(value) ->
        {:ok, hours} = parse_offset(value)
        "UTC#{format_offset(round(hours * 3600))}"

      true ->
        value
    end
  end

  @doc """
  Whether `value` is one of the selectable IANA identifiers.
  """
  @spec identifier?(term()) :: boolean()
  def identifier?(value) when is_binary(value), do: value in @identifiers
  def identifier?(_), do: false

  @doc """
  Whether `value` is a pre-IANA numeric offset, e.g. `"2"`, `"-5"`, `"5.5"`.

  Kept working by `shift/2`, but the UI should offer to replace it: the number
  says nothing about where the account holder is, so it cannot follow DST.
  """
  @spec legacy_offset?(term()) :: boolean()
  def legacy_offset?(value) when is_binary(value), do: match?({:ok, _}, parse_offset(value))
  def legacy_offset?(_), do: false

  @doc """
  Whether `value` is storable — an identifier, a legacy offset, or blank.
  """
  @spec valid?(term()) :: boolean()
  def valid?(value) when value in [nil, ""], do: true
  def valid?(value), do: identifier?(value) or legacy_offset?(value)

  @doc """
  Moves `datetime` into the zone named by `value`.

  An identifier goes through `DateTime.shift_zone/3`, so DST is applied for the
  instant being shown rather than for the moment the preference was saved. A
  legacy offset is added as a fixed number of seconds. Anything unusable —
  including a zone the database cannot resolve — returns `datetime` untouched,
  because a page of timestamps is worth more than a crash over a preference.
  """
  @spec shift(DateTime.t(), String.t() | nil) :: DateTime.t()
  def shift(datetime, value) when value in [nil, ""], do: datetime

  def shift(%DateTime{} = datetime, value) do
    if identifier?(value) do
      case DateTime.shift_zone(datetime, value, @database) do
        {:ok, shifted} -> shifted
        {:error, _reason} -> datetime
      end
    else
      case parse_offset(value) do
        {:ok, hours} -> DateTime.add(datetime, round(hours * 3600), :second)
        :error -> datetime
      end
    end
  end

  def shift(datetime, _value), do: datetime

  # Current offset of `id` in seconds, 0 if the database cannot place it.
  defp offset_seconds(now, id) do
    case DateTime.shift_zone(now, id, @database) do
      {:ok, shifted} -> shifted.utc_offset + shifted.std_offset
      {:error, _reason} -> 0
    end
  end

  # Accepts "2", "+2", "-5", "5.5" — the shapes the pre-IANA picker wrote.
  # Float.parse over Integer.parse is the half-hour fix: Integer.parse("5.5")
  # leaves ".5", which the old guard rejected into a no-op.
  defp parse_offset("+" <> rest), do: parse_offset(rest)

  defp parse_offset(value) when is_binary(value) do
    case Float.parse(value) do
      {hours, ""} when hours >= -12.0 and hours <= 14.0 -> {:ok, hours}
      _ -> :error
    end
  end

  defp parse_offset(_), do: :error

  defp format_offset(seconds) do
    sign = if seconds < 0, do: "-", else: "+"
    total = abs(div(seconds, 60))
    hours = total |> div(60) |> Integer.to_string() |> String.pad_leading(2, "0")
    minutes = total |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")
    "#{sign}#{hours}:#{minutes}"
  end
end
