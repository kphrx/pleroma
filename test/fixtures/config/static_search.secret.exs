import Config

config :pleroma, Pleroma.Search, module: Pleroma.Search.ParadeDB
config :pleroma, Pleroma.Search.ParadeDB, url: "postgres://localhost/paradedb"
config :pleroma, Pleroma.Search.ParadeDB.Repo, pool_size: 2
