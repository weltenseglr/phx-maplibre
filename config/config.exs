import Config

import_config "../apps/demo_berlin_districts/config/config.exs"
import_config "../apps/demo_gsd_tracker/config/config.exs"

config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Ash 3.33 requires an explicit global policy for length-constrained strings.
# Codepoints match PostgreSQL's character-counting semantics.
config :ash, default_string_length_count: :codepoints
