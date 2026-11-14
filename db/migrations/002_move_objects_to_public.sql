BEGIN;

DO $migration$
BEGIN
  IF to_regnamespace('sm_secure') IS NULL THEN
    RAISE EXCEPTION 'SOURCE_SCHEMA_NOT_FOUND';
  END IF;

  IF to_regclass('public.schema_migrations') IS NOT NULL
    OR to_regclass('public.collection_runs') IS NOT NULL
    OR to_regclass('public.snapshots') IS NOT NULL
    OR to_regclass('public.snapshot_scopes') IS NOT NULL
    OR to_regclass('public.items') IS NOT NULL
    OR to_regclass('public.observations') IS NOT NULL
    OR to_regclass('public.reviews') IS NOT NULL
    OR to_regprocedure('public.is_valid_observed_value(jsonb)') IS NOT NULL
    OR to_regprocedure('public.is_valid_observed_map(jsonb,text[])') IS NOT NULL
    OR to_regprocedure('public.is_valid_stored_arguments(jsonb)') IS NOT NULL
    OR to_regprocedure('public.validate_observation_snapshot()') IS NOT NULL
    OR to_regprocedure('public.prevent_terminal_run_update()') IS NOT NULL
    OR to_regprocedure('public.ensure_successful_run_has_snapshot()') IS NOT NULL
    OR to_regprocedure('public.ensure_snapshot_run_succeeded()') IS NOT NULL
  THEN
    RAISE EXCEPTION 'PUBLIC_SCHEMA_OBJECT_CONFLICT';
  END IF;
END
$migration$;

ALTER TABLE sm_secure.schema_migrations SET SCHEMA public;
ALTER TABLE sm_secure.collection_runs SET SCHEMA public;
ALTER TABLE sm_secure.snapshots SET SCHEMA public;
ALTER TABLE sm_secure.snapshot_scopes SET SCHEMA public;
ALTER TABLE sm_secure.items SET SCHEMA public;
ALTER TABLE sm_secure.observations SET SCHEMA public;
ALTER TABLE sm_secure.reviews SET SCHEMA public;

ALTER FUNCTION sm_secure.is_valid_observed_value(jsonb) SET SCHEMA public;
ALTER FUNCTION sm_secure.is_valid_observed_map(jsonb, text[]) SET SCHEMA public;
ALTER FUNCTION sm_secure.is_valid_stored_arguments(jsonb) SET SCHEMA public;
ALTER FUNCTION sm_secure.validate_observation_snapshot() SET SCHEMA public;
ALTER FUNCTION sm_secure.prevent_terminal_run_update() SET SCHEMA public;
ALTER FUNCTION sm_secure.ensure_successful_run_has_snapshot() SET SCHEMA public;
ALTER FUNCTION sm_secure.ensure_snapshot_run_succeeded() SET SCHEMA public;

DO $rewrite_functions$
DECLARE
  function_oid oid;
  function_definition text;
BEGIN
  FOR function_oid IN
    SELECT p.oid
    FROM pg_catalog.pg_proc AS p
    JOIN pg_catalog.pg_namespace AS n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = ANY (ARRAY[
        'is_valid_observed_value',
        'is_valid_observed_map',
        'is_valid_stored_arguments',
        'validate_observation_snapshot',
        'prevent_terminal_run_update',
        'ensure_successful_run_has_snapshot',
        'ensure_snapshot_run_succeeded'
      ])
  LOOP
    function_definition := pg_catalog.pg_get_functiondef(function_oid);
    EXECUTE replace(function_definition, 'sm_secure.', 'public.');
  END LOOP;
END
$rewrite_functions$;

REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE, CREATE ON SCHEMA public TO sm_secure_migrator;
GRANT USAGE ON SCHEMA public TO sm_secure_collector, sm_secure_web;

DROP SCHEMA IF EXISTS sm_secure;

INSERT INTO public.schema_migrations (version)
VALUES ('002_move_objects_to_public')
ON CONFLICT (version) DO NOTHING;

COMMIT;
