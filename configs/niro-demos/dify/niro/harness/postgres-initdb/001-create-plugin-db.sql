-- Runs once, only when the postgres data directory is freshly initialized
-- (mounted at /docker-entrypoint-initdb.d by niro/harness/docker-compose.override.yaml).
--
-- The plugin_daemon service (docker/docker-compose.yaml) connects to a
-- second database ("dify_plugin" by default, see DB_PLUGIN_DATABASE) on the
-- same postgres instance as the main "dify" database, but nothing else in
-- the stack creates that database. Without it, plugin_daemon (and therefore
-- agent_backend, which depends on it) fails to start.
SELECT 'CREATE DATABASE dify_plugin'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'dify_plugin')\gexec
