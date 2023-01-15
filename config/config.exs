import Config

config :nostrum,
  token: "",
  ffmpeg: "ffmpeg",
  youtubedl: "youtube-dl"

config :logger, :console, metadata: [:shard, :guild, :channel]

if File.exists?("config/secret.exs"), do: import_config("secret.exs")
