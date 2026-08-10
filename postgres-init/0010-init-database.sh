#!/bin/bash
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    -- Create docker user
	  CREATE ROLE docker LOGIN PASSWORD 'docker';

	  -- Create docker database
	  CREATE DATABASE docker;

	  -- Create required extensions
	  CREATE EXTENSION pg_cron;

	  -- Schedule housekeeping
	  SELECT cron.schedule_in_database(
        job_name := 'housekeeping_books_history_1k',
        schedule := '* * * * *',
        command  := 'SELECT api.housekeeping_books_history(1000);',
        database := 'docker',
        username := 'docker'
    );
EOSQL

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "docker" <<-EOSQL
    -- Create required extensions
    CREATE EXTENSION IF NOT EXISTS btree_gist;
    CREATE EXTENSION IF NOT EXISTS plpgsql;

    -- Create schema
    CREATE SCHEMA IF NOT EXISTS docker;
    CREATE SCHEMA IF NOT EXISTS api;

    -- Add owner role and grant connection
    ALTER DATABASE docker OWNER TO docker;
    ALTER SCHEMA docker OWNER TO docker;
    ALTER SCHEMA api OWNER TO docker;

    -- Set ownership and permissions
    GRANT CONNECT ON DATABASE docker TO docker;
    GRANT USAGE ON SCHEMA docker TO docker;
    GRANT USAGE ON SCHEMA api TO docker;
    ALTER ROLE docker SET search_path TO docker, api, public;
    GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA docker TO docker;
    GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA docker TO docker;
    GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA api TO docker;
    ALTER DEFAULT PRIVILEGES FOR ROLE docker IN SCHEMA docker GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO docker;
    ALTER DEFAULT PRIVILEGES FOR ROLE docker IN SCHEMA docker GRANT USAGE, SELECT ON SEQUENCES TO docker;
    ALTER DEFAULT PRIVILEGES FOR ROLE docker IN SCHEMA api GRANT EXECUTE ON FUNCTIONS TO docker;
EOSQL
