defmodule PhoenixKit.API.Validator do
  @moduledoc """
  A small JSON Schema validator for the input of API tools.

  Core is installed in every PhoenixKit application, so it does not take a JSON
  Schema dependency for this. The validator implements exactly the subset the
  tools use. Any other validating keyword (`const`, `exclusiveMinimum`,
  `multipleOf`, `uniqueItems`, `oneOf`, `anyOf`, `allOf`, `not`, `$ref`,
  `patternProperties`, `minProperties` and so on) would be ignored by `validate/2`,
  so `check_schema/2` refuses a schema that uses one; `PhoenixKit.API.Tool`
  runs it on every tool, so a schema mistake fails at registration, not as a
  500 on one request.

  Annotations constrain nothing and are accepted and ignored: `description`,
  `title`, `default`, `examples` and `format`, and also `$schema`,
  `$id`, `$comment`, `example`, `deprecated`, `readOnly`, `writeOnly` and any key
  that starts with a lowercase `x-`. `format` is not enforced: a tool that needs
  a shape checked declares a `pattern`.

  | Keyword | Applies to | Error `limit` / `allowed` |
  |---|---|---|
  | `type` (one name or a list) | any | |
  | `enum` | any | `allowed` |
  | `required`, `properties`, `additionalProperties` | objects | |
  | `minimum`, `maximum` (inclusive) | numbers | `limit` |
  | `minLength`, `maxLength` (characters) | strings | `limit` |
  | `pattern` (unanchored, ECMA-262 style) | strings | `limit` |
  | `minItems`, `maxItems`, `items` | arrays | `limit` |

  `type` is one of `"object"`, `"array"`, `"string"`, `"integer"`, `"number"`,
  `"boolean"`, `"null"`. A schema with an unsupported type, or a `pattern` that
  is not a valid regular expression, is a bug in the tool and raises
  `ArgumentError` (`validate/2` compiles every pattern of the schema once, up
  front). A pattern follows JSON Schema (ECMA-262), not PCRE defaults: `$`
  does not match before a trailing newline, and `\\d`, `\\w` and `[[:alpha:]]`
  are ASCII only, while `.` still matches one code point. Booleans are valid
  sub-schemas (`true` accepts anything, `false` accepts nothing).

  ## Input and schema

  Input is what `Jason` decodes: maps with string keys, lists, strings, numbers,
  booleans and `nil`. A schema is a JSON-shaped map. Its keys may be strings or
  atoms (they are normalised to strings first), so `%{type: "object"}` works.
  Atom values of `enum` are compared as strings. A number member matches a
  number that is equal to it (`1` and `1.0`); a list or an object member matches
  strictly, so `[1.0]` does not match `[1]`.

  A float with no fractional part is accepted for `"integer"` and comes back as an
  integer (JSON has one number type, and `2.0` is an integer in JSON Schema). The
  validated value is otherwise the input unchanged. A tool that must not accept
  an absurdly large integer declares `maximum` (`1.0e300` is an integral float).

  ## Errors

  Every problem is reported, not just the first. Each error names the offending
  value by `path`:

      "name"              a property of the input
      "items[2].quantity" a property of the third element of `items`
      "[0]"               the first element when the input itself is an array
      ""                  the input as a whole

  `message` is for people, `limit` carries the bound that was broken and `allowed`
  the permitted values, so a client can show them without parsing text.

  At most 100 errors are returned. The input is untrusted and can be megabytes
  large (20 000 unknown keys against a closed schema, a list of 100 000 wrong
  elements). String lengths are counted without building a list, patterns are
  compiled once per call, and error lists are built by prepending (never
  `errors ++ more` per key). The walk stops as soon as it has collected 100
  errors, and the answer is `{:error, first_100}`. A result of exactly 100
  errors may therefore be incomplete. Error paths shorten a key longer than 64
  bytes, so an error response is not as large as the body that caused it.
  A string that is not valid UTF-8 never matches a `pattern`.
  """

  @type error :: %{
          path: String.t(),
          message: String.t(),
          limit: term() | nil,
          allowed: [term()] | nil
        }

  @types ~w(object array string integer number boolean null)

  # Keywords that annotate a schema and constrain nothing (`check_schema/2` lets them pass).
  @annotations ~w($schema $id $comment title description default examples example format deprecated readOnly writeOnly)

  # Longest key kept in an error path.
  @max_segment 64

  # Regex options: UTF-8 subject, but no :ucp (so \d and \w stay ASCII) and no
  # PCRE "$ matches before a trailing newline" (JSON Schema / ECMA-262 semantics).
  @regex_options [:unicode, :dollar_endonly]

  # The most errors one call returns (shared decision SD7).
  @max_errors 100

  @doc """
  Validates `input` against `schema`.

  Returns `{:ok, value}` (the input, with integral floats turned into integers
  where the schema says `"integer"`) or `{:error, errors}` with the violations,
  at most 100 of them.
  """
  @spec validate(map(), term()) :: {:ok, term()} | {:error, [error()]}
  def validate(schema, input) when is_map(schema) do
    case check(schema |> stringify() |> prepare(), input, "") do
      {value, []} -> {:ok, value}
      {_value, errors} -> {:error, Enum.take(errors, @max_errors)}
    end
  end

  @doc """
  Adds executor control fields (`dry_run`, `confirm_token`, `idempotency_key`) to a
  tool's input schema.

  `extra_properties` maps field names to their schemas. They are merged into the
  schema's `properties`, replacing a property of the same name (a module never
  declares them), and the schema is closed with `additionalProperties: false`, so
  every other unknown field is still refused. The result has string keys.
  """
  @spec close_schema(map(), map()) :: map()
  def close_schema(schema, extra_properties) when is_map(schema) and is_map(extra_properties) do
    extra = stringify(extra_properties)

    schema = stringify(schema)

    properties =
      case Map.get(schema, "properties") do
        %{} = declared -> Map.merge(declared, extra)
        _ -> extra
      end

    schema
    |> Map.put("properties", properties)
    |> Map.put("additionalProperties", false)
  end

  @doc """
  Checks that a tool's schema only uses what `validate/2` enforces.

  Returns `:ok` or `{:error, messages}`. A message names the offending keyword
  (`"input_schema.properties.sku.format is not supported ..."`). It refuses a
  validating keyword `validate/2` would silently ignore, an unsupported `type`, a
  bound that is not a number (a length or item count that is not a non-negative
  integer), a `pattern` that is not a valid regular expression, and a sub-schema
  that is neither an object nor a boolean. Annotations (`description`, `title`,
  `default`, `examples`, `format` ...) and `x-` extensions pass. `root` is the label used
  at the start of every message.
  """
  @spec check_schema(term(), String.t()) :: :ok | {:error, [String.t()]}
  def check_schema(schema, root \\ "schema") do
    case schema |> stringify() |> schema_problems(root) do
      [] -> :ok
      problems -> {:error, problems}
    end
  end

  @doc """
  Whether `keyword` only annotates a schema: `check_schema/2` accepts it and
  `validate/2` ignores it. True for the annotations listed in the moduledoc and
  for any key that starts with a lowercase `x-`.
  """
  @spec annotation?(String.t()) :: boolean()
  def annotation?(keyword) when is_binary(keyword),
    do: keyword in @annotations or String.starts_with?(keyword, "x-")

  # --- Walking the schema ------------------------------------------------

  # Returns {value, errors}: the (possibly converted) value and what is wrong.
  defp check(true, value, _path), do: {value, []}
  defp check(false, value, path), do: {value, [error(path, "is not allowed")]}

  defp check(schema, value, path) do
    case coerce(Map.get(schema, "type"), value) do
      {:ok, value} ->
        {value, kind_errors} = by_kind(schema, value, path)
        {value, enum_errors(schema, value, path) ++ kind_errors}

      {:error, message} ->
        {value, [error(path, message)]}
    end
  end

  defp by_kind(schema, value, path) when is_map(value) and not is_struct(value),
    do: object(schema, value, path)

  defp by_kind(schema, value, path) when is_list(value), do: array(schema, value, path)

  defp by_kind(schema, value, path) when is_binary(value),
    do: {value, string(schema, value, path)}

  defp by_kind(schema, value, path) when is_number(value),
    do: {value, number(schema, value, path)}

  defp by_kind(_schema, value, _path), do: {value, []}

  # --- type and enum -------------------------------------------------------

  defp coerce(nil, value), do: {:ok, value}

  defp coerce(types, value) when is_list(types) do
    names = Enum.map(types, &type_name/1)

    case Enum.find_value(names, &ok_or_nil(coerce_one(&1, value))) do
      nil -> {:error, "must be of type " <> Enum.join(names, " or ")}
      {:ok, _} = ok -> ok
    end
  end

  defp coerce(type, value) do
    name = type_name(type)

    case coerce_one(name, value) do
      {:ok, _} = ok -> ok
      :error -> {:error, "must be " <> article(name)}
    end
  end

  defp ok_or_nil({:ok, _} = ok), do: ok
  defp ok_or_nil(:error), do: nil

  defp coerce_one("object", value) when is_map(value) and not is_struct(value), do: {:ok, value}
  defp coerce_one("array", value) when is_list(value), do: {:ok, value}
  defp coerce_one("string", value) when is_binary(value), do: {:ok, value}
  defp coerce_one("number", value) when is_number(value), do: {:ok, value}
  defp coerce_one("integer", value) when is_integer(value), do: {:ok, value}

  defp coerce_one("integer", value) when is_float(value) and value == trunc(value),
    do: {:ok, trunc(value)}

  defp coerce_one("boolean", value) when is_boolean(value), do: {:ok, value}
  defp coerce_one("null", nil), do: {:ok, nil}
  defp coerce_one(_name, _value), do: :error

  defp type_name(type) do
    name = to_string(type)

    if name in @types,
      do: name,
      else: raise(ArgumentError, "unsupported JSON Schema type #{inspect(type)}")
  end

  defp article("null"), do: "null"
  defp article(name) when name in ["object", "array", "integer"], do: "an " <> name
  defp article(name), do: "a " <> name

  defp enum_errors(schema, value, path) do
    case Map.get(schema, "enum") do
      allowed when is_list(allowed) ->
        allowed = Enum.map(allowed, &enum_member/1)

        if Enum.any?(allowed, &json_equal?(&1, value)),
          do: [],
          else: [
            error(
              path,
              "must be one of: " <> Enum.map_join(allowed, ", ", &display/1),
              nil,
              allowed
            )
          ]

      _ ->
        []
    end
  end

  defp enum_member(member) when is_atom(member) and member not in [nil, true, false],
    do: Atom.to_string(member)

  defp enum_member(member), do: member

  # JSON has one number type: 1 and 1.0 are the same enum member.
  defp json_equal?(left, right) when is_number(left) and is_number(right), do: left == right
  defp json_equal?(left, right), do: left === right

  defp display(value) when is_binary(value), do: value
  defp display(nil), do: "null"
  defp display(value), do: inspect(value)

  # --- objects -------------------------------------------------------------

  defp object(schema, input, path) do
    properties = Map.get(schema, "properties", %{})

    missing =
      for name <- required(schema), not Map.has_key?(input, name) do
        error(child(path, name), "is required")
      end

    # Errors are consed in reverse (never `errors ++ more` per key, which is
    # quadratic) and the walk halts once the cap is reached: the result is an
    # error then, so the rest of a hostile object is never looked at.
    {value, errors, _count} =
      input
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce_while({%{}, [], length(missing)}, fn {name, field}, {acc, errors, count} ->
        {checked, field_errors} = field_check(schema, properties, name, field, path)
        count = count + length(field_errors)
        step = {Map.put(acc, name, checked), Enum.reverse(field_errors, errors), count}
        if count >= @max_errors, do: {:halt, step}, else: {:cont, step}
      end)

    {value, Enum.take(missing ++ Enum.reverse(errors), @max_errors)}
  end

  defp required(schema) do
    case Map.get(schema, "required") do
      names when is_list(names) -> Enum.map(names, &to_string/1)
      _ -> []
    end
  end

  defp field_check(schema, properties, name, field, path) do
    case Map.fetch(properties, name) do
      {:ok, sub_schema} -> check(sub_schema, field, child(path, name))
      :error -> additional(Map.get(schema, "additionalProperties", true), name, field, path)
    end
  end

  defp additional(false, name, field, path),
    do: {field, [error(child(path, name), "is not allowed")]}

  defp additional(sub_schema, name, field, path) when is_map(sub_schema),
    do: check(sub_schema, field, child(path, name))

  defp additional(_allowed, _name, field, _path), do: {field, []}

  defp child("", name), do: segment(name)
  defp child(path, name), do: path <> "." <> segment(name)

  defp segment(name) do
    case to_string(name) do
      long when byte_size(long) > @max_segment ->
        String.byte_slice(long, 0, @max_segment) <> "..."

      short ->
        short
    end
  end

  # --- arrays --------------------------------------------------------------

  defp array(schema, list, path) do
    {items, item_errors} = items(Map.get(schema, "items"), list, path)
    {items, Enum.take(size_errors(schema, length(list), path) ++ item_errors, @max_errors)}
  end

  # Same discipline as `object/3`: errors are consed in reverse, and the walk
  # halts at the cap (the partial list of values is then never used, the result
  # is an error).
  defp items(sub_schema, list, path) when is_map(sub_schema) or sub_schema == false do
    {checked, errors, _count} =
      list
      |> Enum.with_index()
      |> Enum.reduce_while({[], [], 0}, fn {element, index}, {acc, errors, count} ->
        {value, element_errors} = check(sub_schema, element, path <> "[#{index}]")
        count = count + length(element_errors)
        step = {[value | acc], Enum.reverse(element_errors, errors), count}
        if count >= @max_errors, do: {:halt, step}, else: {:cont, step}
      end)

    {Enum.reverse(checked), Enum.reverse(errors)}
  end

  defp items(_none, list, _path), do: {list, []}

  defp size_errors(schema, size, path) do
    min = Map.get(schema, "minItems")
    max = Map.get(schema, "maxItems")

    [
      if(is_integer(min) and size < min,
        do: error(path, "must have at least #{plural(min, "item")}", min)
      ),
      if(is_integer(max) and size > max,
        do: error(path, "must have at most #{plural(max, "item")}", max)
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  # --- strings and numbers -------------------------------------------------

  defp string(schema, value, path) do
    min = Map.get(schema, "minLength")
    max = Map.get(schema, "maxLength")

    [
      if(too_short?(value, min),
        do: error(path, "must be at least #{plural(min, "character")}", min)
      ),
      if(too_long?(value, max),
        do: error(path, "must be at most #{plural(max, "character")}", max)
      ),
      pattern_error(Map.get(schema, "pattern"), value, path)
    ]
    |> Enum.reject(&is_nil/1)
  end

  # Lengths count code points. A string of N bytes has between ceil(N / 4) and N
  # code points, which settles most cases without looking at the string; the rest
  # is counted by a tail-recursive walk that allocates nothing, so a 2 MB string
  # costs no more heap than a short one.
  defp too_short?(_value, min) when not is_integer(min), do: false

  defp too_short?(value, min) do
    bytes = byte_size(value)

    cond do
      bytes < min -> true
      div(bytes + 3, 4) >= min -> false
      true -> count_codepoints(value, 0) < min
    end
  end

  defp too_long?(_value, max) when not is_integer(max), do: false

  defp too_long?(value, max) do
    bytes = byte_size(value)

    cond do
      bytes <= max -> false
      div(bytes + 3, 4) > max -> true
      true -> count_codepoints(value, 0) > max
    end
  end

  # A byte that is not valid UTF-8 counts as one character, as in String.codepoints/1.
  defp count_codepoints(<<_::utf8, rest::binary>>, count), do: count_codepoints(rest, count + 1)
  defp count_codepoints(<<_, rest::binary>>, count), do: count_codepoints(rest, count + 1)
  defp count_codepoints(<<>>, count), do: count

  defp pattern_error(nil, _value, _path), do: nil

  defp pattern_error({pattern, regex}, value, path) do
    if String.valid?(value) and Regex.match?(regex, value),
      do: nil,
      else: error(path, "must match the pattern #{pattern}", pattern)
  end

  # --- compiling patterns once -----------------------------------------------

  # Replaces every `pattern` of the schema with `{source, compiled_regex}`, so a
  # list of 500 000 strings does not compile the regex 500 000 times. The walk
  # follows the schema (properties, items, additionalProperties), never the data.
  defp prepare(%{} = schema) when not is_struct(schema) do
    Map.new(schema, fn
      {"pattern", pattern} when is_binary(pattern) ->
        {"pattern", {pattern, compile_pattern!(pattern)}}

      {"properties", %{} = properties} ->
        {"properties", Map.new(properties, fn {name, sub} -> {name, prepare(sub)} end)}

      {key, sub} when key in ["items", "additionalProperties"] ->
        {key, prepare(sub)}

      other ->
        other
    end)
  end

  defp prepare(other), do: other

  defp compile_pattern!(pattern) do
    case Regex.compile(pattern, @regex_options) do
      {:ok, regex} ->
        regex

      {:error, reason} ->
        raise ArgumentError,
              "invalid pattern #{inspect(pattern)} in a tool schema: #{inspect(reason)}"
    end
  end

  # --- checking a schema ---------------------------------------------------------

  defp schema_problems(schema, _where) when is_boolean(schema), do: []

  defp schema_problems(%{} = schema, where) when not is_struct(schema) do
    schema
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {key, value} -> keyword_problems(key, value, "#{where}.#{key}") end)
  end

  defp schema_problems(other, where),
    do: ["#{where} must be an object or a boolean, got #{inspect(other)}"]

  defp keyword_problems("type", value, where) do
    names = if is_list(value), do: value, else: [value]

    if names != [] and Enum.all?(names, &type_member?/1),
      do: [],
      else: [
        "#{where} must be one of #{Enum.join(@types, ", ")} or a non-empty list of them, got #{inspect(value)}"
      ]
  end

  defp keyword_problems("enum", value, _where) when is_list(value), do: []
  defp keyword_problems("enum", _value, where), do: ["#{where} must be a list"]

  defp keyword_problems("required", value, where) do
    if is_list(value) and
         Enum.all?(value, &(is_binary(&1) or (is_atom(&1) and &1 not in [nil, true, false]))),
       do: [],
       else: ["#{where} must be a list of property names"]
  end

  defp keyword_problems("properties", %{} = value, where) when not is_struct(value) do
    value
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {name, sub} -> schema_problems(sub, "#{where}.#{name}") end)
  end

  defp keyword_problems("properties", _value, where), do: ["#{where} must be an object"]

  defp keyword_problems("additionalProperties", value, where), do: schema_problems(value, where)
  defp keyword_problems("items", value, where), do: schema_problems(value, where)

  defp keyword_problems(key, value, where) when key in ["minimum", "maximum"] do
    if is_number(value), do: [], else: ["#{where} must be a number, got #{inspect(value)}"]
  end

  defp keyword_problems(key, value, where)
       when key in ["minLength", "maxLength", "minItems", "maxItems"] do
    if is_integer(value) and value >= 0,
      do: [],
      else: ["#{where} must be a non-negative integer, got #{inspect(value)}"]
  end

  defp keyword_problems("pattern", value, where) when is_binary(value) do
    case Regex.compile(value, @regex_options) do
      {:ok, _regex} -> []
      {:error, reason} -> ["#{where} is not a valid regular expression: #{inspect(reason)}"]
    end
  end

  defp keyword_problems("pattern", value, where),
    do: ["#{where} must be a string, got #{inspect(value)}"]

  defp keyword_problems(key, _value, where) do
    if annotation?(key),
      do: [],
      else: ["#{where} is not supported (it would be ignored, so the input would go unchecked)"]
  end

  defp type_member?(type) when is_binary(type) or (is_atom(type) and not is_nil(type)),
    do: to_string(type) in @types

  defp type_member?(_type), do: false

  defp number(schema, value, path) do
    min = Map.get(schema, "minimum")
    max = Map.get(schema, "maximum")

    [
      if(is_number(min) and value < min, do: error(path, "must be at least #{min}", min)),
      if(is_number(max) and value > max, do: error(path, "must be at most #{max}", max))
    ]
    |> Enum.reject(&is_nil/1)
  end

  # --- helpers -------------------------------------------------------------

  defp error(path, message, limit \\ nil, allowed \\ nil),
    do: %{path: path, message: message, limit: limit, allowed: allowed}

  defp plural(1, noun), do: "1 #{noun}"
  defp plural(count, noun), do: "#{count} #{noun}s"

  # Schemas may be written with atom keys; everything below works on strings.
  defp stringify(%{} = map) when not is_struct(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)
  end

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(other), do: other
end
