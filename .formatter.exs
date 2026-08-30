[
  import_deps: [:ecto, :ecto_sql, :phoenix],
  subdirectories: ["priv/*/migrations"],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  inputs: [
    "*.{heex,ex,exs}",
    "{config,lib,test}/**/*.{heex,ex,exs}",
    "priv/*/seeds.exs"
  ],
  # Exclude template files that contain EEx syntax. The key is `:excludes`
  # (plural) — Elixir 1.19 added it; `exclude:` was silently ignored, so
  # priv/templates was only ever safe because no :inputs pattern reached it.
  # Note this filters :inputs expansion ONLY (`expand_dot_inputs/4`); an
  # explicit `mix format <path>` goes through `expand_args/5`, which never
  # consults it — hence the same skip in .claude/hooks/format-edited-file.sh.
  excludes: ["priv/templates/**/*.*"]
]
