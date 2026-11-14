BEGIN;
SET CONSTRAINTS ALL DEFERRED;

DO $test$
DECLARE
  run_id uuid;
  snapshot_id uuid;
  item_id uuid;
  observation_id uuid;
  conditions jsonb := jsonb_build_object(
    'collectionProfile', jsonb_build_object('state', 'known', 'value', 'test-profile'),
    'targetScope', jsonb_build_object('state', 'known', 'value', 'test-scope'),
    'executionConditions', jsonb_build_object('state', 'known', 'value', 'test-mode')
  );
  compatibility jsonb := jsonb_build_object(
    'collectionProfile', jsonb_build_object('state', 'known', 'value', 'test-profile'),
    'targetScope', jsonb_build_object('state', 'known', 'value', 'test-scope'),
    'executionConditions', jsonb_build_object('state', 'known', 'value', 'test-mode'),
    'autorunscVersion', jsonb_build_object('state', 'known', 'value', '14.3'),
    'analysisVersion', jsonb_build_object('state', 'known', 'value', 'test-analysis'),
    'identityRuleVersion', jsonb_build_object('state', 'known', 'value', 'test-identity')
  );
  observed_fields jsonb := jsonb_build_object(
    'sourceKind', jsonb_build_object('state', 'known', 'value', 'registry'),
    'location', jsonb_build_object('state', 'known', 'value', 'test-location'),
    'name', jsonb_build_object('state', 'known', 'value', 'test-name'),
    'scope', jsonb_build_object('state', 'known', 'value', 'test-scope'),
    'imagePath', jsonb_build_object('state', 'known', 'value', 'test.exe'),
    'signatureStatus', jsonb_build_object('state', 'unavailable', 'reason', 'missing'),
    'signer', jsonb_build_object('state', 'unavailable', 'reason', 'missing'),
    'hashAlgorithm', jsonb_build_object('state', 'unavailable', 'reason', 'hash_algorithm_unavailable'),
    'hash', jsonb_build_object('state', 'unavailable', 'reason', 'hash_algorithm_unavailable')
  );
BEGIN
  IF to_regnamespace('sm_secure') IS NOT NULL
    OR to_regclass('public.collection_runs') IS NULL
    OR to_regclass('public.snapshots') IS NULL
    OR to_regclass('public.snapshot_scopes') IS NULL
    OR to_regclass('public.items') IS NULL
    OR to_regclass('public.observations') IS NULL
    OR to_regclass('public.reviews') IS NULL
  THEN
    RAISE EXCEPTION 'DATABASE_OBJECTS_NOT_IN_PUBLIC_SCHEMA';
  END IF;

  IF has_table_privilege('sm_secure_web', 'public.observations', 'UPDATE')
    OR has_table_privilege('sm_secure_web', 'public.observations', 'DELETE')
    OR has_table_privilege('sm_secure_collector', 'public.observations', 'UPDATE')
    OR has_table_privilege('sm_secure_collector', 'public.observations', 'DELETE')
  THEN
    RAISE EXCEPTION 'OBSERVATION_WRITE_PRIVILEGE_TOO_BROAD';
  END IF;
  IF NOT has_column_privilege(
    'sm_secure_collector',
    'public.collection_runs',
    'state',
    'UPDATE'
  ) OR NOT has_column_privilege(
    'sm_secure_web',
    'public.reviews',
    'observation_id',
    'INSERT'
  ) THEN
    RAISE EXCEPTION 'EXPECTED_ROLE_PRIVILEGE_MISSING';
  END IF;

  INSERT INTO public.collection_runs (conditions)
  VALUES (conditions)
  RETURNING id INTO run_id;

  INSERT INTO public.snapshots (
    collection_run_id,
    compatibility,
    argument_persistence_policy
  )
  VALUES (run_id, compatibility, 'do_not_persist')
  RETURNING id INTO snapshot_id;

  INSERT INTO public.snapshot_scopes (
    snapshot_id,
    scope_id,
    requested,
    coverage
  )
  VALUES (snapshot_id, 'test-logon', true, 'complete');

  INSERT INTO public.items (identity_rule_version, identity_key)
  VALUES ('test-identity', 'opaque-test-key')
  RETURNING id INTO item_id;

  UPDATE public.collection_runs
  SET state = 'succeeded', finished_at = now()
  WHERE id = run_id;

  INSERT INTO public.observations (
    snapshot_id,
    item_id,
    observed_fields,
    arguments
  )
  VALUES (
    snapshot_id,
    item_id,
    observed_fields,
    jsonb_build_object(
      'collectionState', 'collected',
      'persistenceState', 'not_persisted_by_policy',
      'value', NULL
    )
  )
  RETURNING id INTO observation_id;

  INSERT INTO public.reviews (observation_id, note)
  VALUES (observation_id, 'temporary schema test');

  BEGIN
    INSERT INTO public.observations (
      snapshot_id,
      item_id,
      observed_fields,
      arguments
    )
    VALUES (
      snapshot_id,
      item_id,
      observed_fields,
      jsonb_build_object(
        'collectionState', 'collected',
        'persistenceState', 'persisted',
        'value', 'must-not-be-persisted'
      )
    );
    RAISE EXCEPTION 'ARGUMENT_POLICY_REJECTION_NOT_ENFORCED';
  EXCEPTION
    WHEN check_violation THEN NULL;
  END;
END
$test$;

SET CONSTRAINTS ALL IMMEDIATE;
ROLLBACK;
