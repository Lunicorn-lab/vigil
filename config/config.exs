import Config

config :elixir, :time_zone_database, Tz.TimeZoneDatabase

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:module]

import_config "#{config_env()}.exs"
