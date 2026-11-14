BEGIN;

DO $roles$
DECLARE
  role_name text;
BEGIN
  FOREACH role_name IN ARRAY ARRAY[
    'sm_secure_migrator',
    'sm_secure_collector',
    'sm_secure_web'
  ]
  LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = role_name) THEN
      EXECUTE format(
        'CREATE ROLE %I NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE',
        role_name
      );
    ELSIF EXISTS (
      SELECT 1
      FROM pg_roles
      WHERE rolname = role_name
        AND (rolcanlogin OR rolsuper OR rolcreatedb OR rolcreaterole)
    ) THEN
      RAISE EXCEPTION 'DATABASE_ROLE_CONFIGURATION_INVALID';
    END IF;
  END LOOP;
END;
$roles$;

CREATE SCHEMA IF NOT EXISTS sm_secure AUTHORIZATION sm_secure_migrator;
ALTER SCHEMA sm_secure OWNER TO sm_secure_migrator;
REVOKE ALL ON SCHEMA sm_secure FROM PUBLIC;

SET LOCAL ROLE sm_secure_migrator;
SET LOCAL search_path = sm_secure, pg_catalog;

CREATE TABLE IF NOT EXISTS sm_secure.schema_migrations (
  version text PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION sm_secure.is_valid_observed_value(candidate jsonb)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $function$
  SELECT CASE
    WHEN jsonb_typeof(candidate) <> 'object' THEN false
    WHEN candidate->>'state' = 'known' THEN
      (SELECT count(*) FROM jsonb_object_keys(candidate)) = 2
      AND candidate ? 'value'
      AND jsonb_typeof(candidate->'value') = 'string'
      AND NOT (candidate ? 'reason')
    WHEN candidate->>'state' = 'unavailable' THEN
      (SELECT count(*) FROM jsonb_object_keys(candidate)) = 2
      AND candidate ? 'reason'
      AND jsonb_typeof(candidate->'reason') = 'string'
      AND NOT (candidate ? 'value')
    ELSE false
  END
$function$;

CREATE OR REPLACE FUNCTION sm_secure.is_valid_observed_map(
  candidate jsonb,
  required_keys text[]
)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $function$
  SELECT CASE
    WHEN jsonb_typeof(candidate) <> 'object' THEN false
    ELSE
      (SELECT count(*) FROM jsonb_object_keys(candidate)) = cardinality(required_keys)
      AND candidate ?& required_keys
      AND NOT EXISTS (
        SELECT 1
        FROM jsonb_each(candidate) AS entry(field_name, field_value)
        WHERE NOT sm_secure.is_valid_observed_value(entry.field_value)
      )
  END
$function$;

CREATE OR REPLACE FUNCTION sm_secure.is_valid_stored_arguments(candidate jsonb)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $function$
  SELECT CASE
    WHEN jsonb_typeof(candidate) <> 'object' THEN false
    WHEN (SELECT count(*) FROM jsonb_object_keys(candidate)) <> 3 THEN false
    WHEN NOT (candidate ?& ARRAY['collectionState', 'persistenceState', 'value']) THEN false
    WHEN candidate->>'persistenceState' = 'not_persisted_by_policy' THEN
      candidate->>'collectionState' IN ('collected', 'collection_failed', 'not_attempted')
      AND jsonb_typeof(candidate->'value') = 'null'
    WHEN candidate->>'persistenceState' = 'persisted' THEN
      candidate->>'collectionState' = 'collected'
      AND jsonb_typeof(candidate->'value') = 'string'
    WHEN candidate->>'persistenceState' = 'not_persisted_due_to_collection_failure' THEN
      candidate->>'collectionState' = 'collection_failed'
      AND jsonb_typeof(candidate->'value') = 'null'
    ELSE false
  END
$function$;

CREATE TABLE IF NOT EXISTS sm_secure.collection_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  started_at timestamptz NOT NULL DEFAULT now(),
  finished_at timestamptz,
  state text NOT NULL DEFAULT 'running',
  failure_code text,
  conditions jsonb NOT NULL,
  CONSTRAINT collection_runs_conditions_valid CHECK (
    sm_secure.is_valid_observed_map(
      conditions,
      ARRAY['collectionProfile', 'targetScope', 'executionConditions']
    )
  ),
  CONSTRAINT collection_runs_state_valid CHECK (
    (
      state = 'running'
      AND finished_at IS NULL
      AND failure_code IS NULL
    )
    OR (
      state = 'succeeded'
      AND finished_at IS NOT NULL
      AND failure_code IS NULL
    )
    OR (
      state = 'failed'
      AND finished_at IS NOT NULL
      AND failure_code IN (
        'process_start_failed',
        'process_exit_nonzero',
        'database_write_failed',
        'unexpected_failure'
      )
    )
    OR (
      state = 'timed_out'
      AND finished_at IS NOT NULL
      AND failure_code = 'process_timeout'
    )
    OR (
      state = 'parse_failed'
      AND finished_at IS NOT NULL
      AND failure_code = 'csv_parse_failed'
    )
    OR (
      state = 'interrupted'
      AND finished_at IS NOT NULL
      AND failure_code = 'collection_cancelled'
    )
  ),
  CONSTRAINT collection_runs_finished_after_started CHECK (
    finished_at IS NULL OR finished_at >= started_at
  )
);

CREATE INDEX IF NOT EXISTS collection_runs_started_at_idx
  ON sm_secure.collection_runs (started_at DESC, id);

CREATE TABLE IF NOT EXISTS sm_secure.snapshots (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  collection_run_id uuid NOT NULL UNIQUE
    REFERENCES sm_secure.collection_runs (id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  compatibility jsonb NOT NULL,
  argument_persistence_policy text NOT NULL,
  CONSTRAINT snapshots_compatibility_valid CHECK (
    sm_secure.is_valid_observed_map(
      compatibility,
      ARRAY[
        'collectionProfile',
        'targetScope',
        'executionConditions',
        'autorunscVersion',
        'analysisVersion',
        'identityRuleVersion'
      ]
    )
  ),
  CONSTRAINT snapshots_argument_policy_valid CHECK (
    argument_persistence_policy IN ('persist', 'do_not_persist')
  )
);

CREATE INDEX IF NOT EXISTS snapshots_created_at_idx
  ON sm_secure.snapshots (created_at DESC, id);

CREATE TABLE IF NOT EXISTS sm_secure.snapshot_scopes (
  snapshot_id uuid NOT NULL
    REFERENCES sm_secure.snapshots (id) ON DELETE RESTRICT,
  scope_id text NOT NULL CHECK (length(scope_id) > 0),
  requested boolean NOT NULL,
  coverage text NOT NULL CHECK (
    coverage IN ('complete', 'partial', 'failed', 'not_attempted', 'unknown')
  ),
  reason_code text CHECK (
    reason_code IS NULL OR reason_code ~ '^[a-z][a-z0-9_]*$'
  ),
  PRIMARY KEY (snapshot_id, scope_id),
  CONSTRAINT snapshot_scopes_complete_has_no_reason CHECK (
    coverage <> 'complete' OR reason_code IS NULL
  )
);

CREATE TABLE IF NOT EXISTS sm_secure.items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  identity_rule_version text NOT NULL CHECK (length(identity_rule_version) > 0),
  identity_key text NOT NULL CHECK (length(identity_key) > 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT items_identity_unique UNIQUE (identity_rule_version, identity_key)
);

CREATE TABLE IF NOT EXISTS sm_secure.observations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  snapshot_id uuid NOT NULL
    REFERENCES sm_secure.snapshots (id) ON DELETE RESTRICT,
  item_id uuid REFERENCES sm_secure.items (id) ON DELETE RESTRICT,
  unresolved_reason text,
  observed_fields jsonb NOT NULL,
  arguments jsonb NOT NULL,
  CONSTRAINT observations_identity_valid CHECK (
    (item_id IS NOT NULL AND unresolved_reason IS NULL)
    OR (
      item_id IS NULL
      AND unresolved_reason IN (
        'duplicate_identity',
        'missing_identity',
        'unsupported_identity'
      )
    )
  ),
  CONSTRAINT observations_fields_valid CHECK (
    sm_secure.is_valid_observed_map(
      observed_fields,
      ARRAY[
        'sourceKind',
        'location',
        'name',
        'scope',
        'imagePath',
        'signatureStatus',
        'signer',
        'hashAlgorithm',
        'hash'
      ]
    )
  ),
  CONSTRAINT observations_arguments_valid CHECK (
    sm_secure.is_valid_stored_arguments(arguments)
  )
);

CREATE INDEX IF NOT EXISTS observations_snapshot_id_idx
  ON sm_secure.observations (snapshot_id);
CREATE INDEX IF NOT EXISTS observations_item_id_idx
  ON sm_secure.observations (item_id)
  WHERE item_id IS NOT NULL;

CREATE OR REPLACE FUNCTION sm_secure.validate_observation_snapshot()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
  policy text;
  snapshot_identity_rule jsonb;
  item_identity_rule text;
  argument_state text;
BEGIN
  SELECT argument_persistence_policy, compatibility->'identityRuleVersion'
  INTO policy, snapshot_identity_rule
  FROM sm_secure.snapshots
  WHERE id = NEW.snapshot_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'OBSERVATION_SNAPSHOT_NOT_FOUND'
      USING ERRCODE = '23503';
  END IF;

  argument_state := NEW.arguments->>'persistenceState';
  IF policy = 'do_not_persist' AND argument_state <> 'not_persisted_by_policy' THEN
    RAISE EXCEPTION 'ARGUMENT_PERSISTENCE_POLICY_VIOLATION'
      USING ERRCODE = '23514';
  END IF;
  IF policy = 'persist' AND argument_state = 'not_persisted_by_policy' THEN
    RAISE EXCEPTION 'ARGUMENT_PERSISTENCE_POLICY_VIOLATION'
      USING ERRCODE = '23514';
  END IF;

  IF NEW.item_id IS NOT NULL THEN
    SELECT identity_rule_version
    INTO item_identity_rule
    FROM sm_secure.items
    WHERE id = NEW.item_id;

    IF snapshot_identity_rule->>'state' <> 'known'
      OR item_identity_rule IS DISTINCT FROM snapshot_identity_rule->>'value'
    THEN
      RAISE EXCEPTION 'OBSERVATION_IDENTITY_RULE_MISMATCH'
        USING ERRCODE = '23514';
    END IF;
  END IF;

  RETURN NEW;
END
$function$;

DROP TRIGGER IF EXISTS observations_validate_snapshot ON sm_secure.observations;
CREATE TRIGGER observations_validate_snapshot
  BEFORE INSERT ON sm_secure.observations
  FOR EACH ROW
  EXECUTE FUNCTION sm_secure.validate_observation_snapshot();

CREATE TABLE IF NOT EXISTS sm_secure.reviews (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  observation_id uuid NOT NULL UNIQUE
    REFERENCES sm_secure.observations (id) ON DELETE RESTRICT,
  reviewed_at timestamptz NOT NULL DEFAULT now(),
  note text
);

CREATE OR REPLACE FUNCTION sm_secure.prevent_terminal_run_update()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
  IF OLD.state <> 'running'
    OR NEW.id IS DISTINCT FROM OLD.id
    OR NEW.started_at IS DISTINCT FROM OLD.started_at
    OR NEW.conditions IS DISTINCT FROM OLD.conditions
  THEN
    RAISE EXCEPTION 'COLLECTION_RUN_IMMUTABLE'
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END
$function$;

DROP TRIGGER IF EXISTS collection_runs_immutable_state ON sm_secure.collection_runs;
CREATE TRIGGER collection_runs_immutable_state
  BEFORE UPDATE ON sm_secure.collection_runs
  FOR EACH ROW
  EXECUTE FUNCTION sm_secure.prevent_terminal_run_update();

CREATE OR REPLACE FUNCTION sm_secure.ensure_successful_run_has_snapshot()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
  final_state text;
BEGIN
  SELECT state INTO final_state
  FROM sm_secure.collection_runs
  WHERE id = NEW.id;

  IF final_state = 'succeeded'
    AND NOT EXISTS (
      SELECT 1
      FROM sm_secure.snapshots
      WHERE collection_run_id = NEW.id
    )
  THEN
    RAISE EXCEPTION 'SUCCESSFUL_RUN_REQUIRES_SNAPSHOT'
      USING ERRCODE = '23514';
  END IF;
  RETURN NULL;
END
$function$;

DROP TRIGGER IF EXISTS collection_runs_success_requires_snapshot
  ON sm_secure.collection_runs;
CREATE CONSTRAINT TRIGGER collection_runs_success_requires_snapshot
  AFTER INSERT OR UPDATE ON sm_secure.collection_runs
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW
  EXECUTE FUNCTION sm_secure.ensure_successful_run_has_snapshot();

CREATE OR REPLACE FUNCTION sm_secure.ensure_snapshot_run_succeeded()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
  final_state text;
  run_conditions jsonb;
BEGIN
  SELECT state, conditions
  INTO final_state, run_conditions
  FROM sm_secure.collection_runs
  WHERE id = NEW.collection_run_id;

  IF final_state IS DISTINCT FROM 'succeeded' THEN
    RAISE EXCEPTION 'SNAPSHOT_REQUIRES_SUCCESSFUL_RUN'
      USING ERRCODE = '23514';
  END IF;

  IF NEW.compatibility->'collectionProfile' IS DISTINCT FROM run_conditions->'collectionProfile'
    OR NEW.compatibility->'targetScope' IS DISTINCT FROM run_conditions->'targetScope'
    OR NEW.compatibility->'executionConditions' IS DISTINCT FROM run_conditions->'executionConditions'
  THEN
    RAISE EXCEPTION 'SNAPSHOT_RUN_CONDITIONS_MISMATCH'
      USING ERRCODE = '23514';
  END IF;
  RETURN NULL;
END
$function$;

DROP TRIGGER IF EXISTS snapshots_require_successful_run
  ON sm_secure.snapshots;
CREATE CONSTRAINT TRIGGER snapshots_require_successful_run
  AFTER INSERT ON sm_secure.snapshots
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW
  EXECUTE FUNCTION sm_secure.ensure_snapshot_run_succeeded();

INSERT INTO sm_secure.schema_migrations (version)
VALUES ('001_initial_schema')
ON CONFLICT (version) DO NOTHING;

RESET ROLE;

GRANT USAGE ON SCHEMA sm_secure TO sm_secure_collector, sm_secure_web;

GRANT SELECT ON
  sm_secure.collection_runs,
  sm_secure.snapshots,
  sm_secure.snapshot_scopes,
  sm_secure.items,
  sm_secure.observations
TO sm_secure_collector;
GRANT INSERT (started_at, conditions)
  ON sm_secure.collection_runs TO sm_secure_collector;
GRANT UPDATE (state, finished_at, failure_code)
  ON sm_secure.collection_runs TO sm_secure_collector;
GRANT INSERT (collection_run_id, created_at, compatibility, argument_persistence_policy)
  ON sm_secure.snapshots TO sm_secure_collector;
GRANT INSERT (snapshot_id, scope_id, requested, coverage, reason_code)
  ON sm_secure.snapshot_scopes TO sm_secure_collector;
GRANT INSERT (identity_rule_version, identity_key)
  ON sm_secure.items TO sm_secure_collector;
GRANT INSERT (
  snapshot_id,
  item_id,
  unresolved_reason,
  observed_fields,
  arguments
) ON sm_secure.observations TO sm_secure_collector;

GRANT SELECT ON
  sm_secure.collection_runs,
  sm_secure.snapshots,
  sm_secure.snapshot_scopes,
  sm_secure.items,
  sm_secure.observations,
  sm_secure.reviews
TO sm_secure_web;
GRANT INSERT (observation_id, note)
  ON sm_secure.reviews TO sm_secure_web;

GRANT EXECUTE ON FUNCTION sm_secure.is_valid_observed_value(jsonb)
  TO sm_secure_collector;
GRANT EXECUTE ON FUNCTION sm_secure.is_valid_observed_map(jsonb, text[])
  TO sm_secure_collector;
GRANT EXECUTE ON FUNCTION sm_secure.is_valid_stored_arguments(jsonb)
  TO sm_secure_collector;

COMMIT;
