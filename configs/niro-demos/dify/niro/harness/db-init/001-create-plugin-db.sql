-- Runs once, only when the `db` container initializes an empty data
-- directory (official postgres image convention). The plugin daemon
-- needs its own database alongside the main `dify` one.
CREATE DATABASE dify_plugin;
