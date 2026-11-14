import assert from "node:assert/strict";
import { test } from "node:test";
import {
  areSnapshotsCompatible,
  selectComparisonBaseline,
  type SnapshotDescriptor,
} from "./snapshot.ts";
import type { ObservedValue } from "./observation.ts";

const known = (value: string): ObservedValue => ({ state: "known", value });
const missing: ObservedValue = { state: "unavailable", reason: "missing" };

function snapshot(
  id: string,
  createdAt: string,
  overrides: Partial<SnapshotDescriptor> = {},
): SnapshotDescriptor {
  return {
    id,
    createdAt,
    compatibility: {
      collectionProfile: known("profile"),
      targetScope: known("current-user"),
      executionConditions: known("normal"),
      autorunscVersion: known("14.3"),
      analysisVersion: known("analysis-v1"),
      identityRuleVersion: known("identity-v1"),
    },
    scopes: [{ id: "logon", requested: true, coverage: "complete", reasonCode: null }],
    ...overrides,
  };
}

test("unknown compatibility metadata never selects a baseline", () => {
  const current = snapshot("current", "2026-03-02T00:00:00Z");
  const unknown = snapshot("old", "2026-03-01T00:00:00Z", {
    compatibility: { ...current.compatibility, targetScope: missing },
  });
  assert.equal(areSnapshotsCompatible(current, unknown), false);
  assert.equal(selectComparisonBaseline(current, [unknown]), null);
});

test("selects the latest earlier compatible snapshot, not newer incompatible history", () => {
  const current = snapshot("current", "2026-03-04T00:00:00Z");
  const olderCompatible = snapshot("older", "2026-03-01T00:00:00Z");
  const newerIncompatible = snapshot("newer", "2026-03-03T00:00:00Z", {
    compatibility: { ...current.compatibility, collectionProfile: known("other-profile") },
  });
  const futureCompatible = snapshot("future", "2026-03-05T00:00:00Z");
  const selection = selectComparisonBaseline(current, [
    olderCompatible,
    newerIncompatible,
    futureCompatible,
  ]);
  assert.equal(selection?.snapshot.id, "older");
});

test("requested scope changes allow only the intersection of complete scopes", () => {
  const current = snapshot("current", "2026-03-02T00:00:00Z", {
    scopes: [
      { id: "logon", requested: true, coverage: "complete", reasonCode: null },
      { id: "services", requested: true, coverage: "partial", reasonCode: "reported_incomplete" },
    ],
  });
  const previous = snapshot("previous", "2026-03-01T00:00:00Z", {
    scopes: [
      { id: "logon", requested: true, coverage: "complete", reasonCode: null },
      { id: "scheduled", requested: true, coverage: "complete", reasonCode: null },
    ],
  });
  const selection = selectComparisonBaseline(current, [previous]);
  assert.deepEqual(selection?.comparableScopes, ["logon"]);
});

test("does not fall back to older history for scopes missing from the selected baseline", () => {
  const current = snapshot("current", "2026-03-03T00:00:00Z");
  const olderComplete = snapshot("older", "2026-03-01T00:00:00Z");
  const latestPartial = snapshot("latest", "2026-03-02T00:00:00Z", {
    scopes: [
      { id: "logon", requested: true, coverage: "partial", reasonCode: "reported_incomplete" },
    ],
  });
  const selection = selectComparisonBaseline(current, [olderComplete, latestPartial]);
  assert.equal(selection?.snapshot.id, "latest");
  assert.deepEqual(selection?.comparableScopes, []);
});

test("same-time snapshots use ID ordering and do not look ahead", () => {
  const current = snapshot("b", "2026-03-02T00:00:00Z");
  const earlierId = snapshot("a", "2026-03-02T00:00:00Z");
  const laterId = snapshot("c", "2026-03-02T00:00:00Z");
  const selection = selectComparisonBaseline(current, [laterId, earlierId]);
  assert.equal(selection?.snapshot.id, "a");
});

test("duplicate scope results and invalid ordering metadata are rejected", () => {
  const current = snapshot("current", "2026-03-02T00:00:00Z");
  const duplicateScopes = snapshot("previous", "2026-03-01T00:00:00Z", {
    scopes: [
      { id: "logon", requested: true, coverage: "complete", reasonCode: null },
      { id: "logon", requested: true, coverage: "failed", reasonCode: "access_denied" },
    ],
  });
  assert.throws(
    () => selectComparisonBaseline(current, [duplicateScopes]),
    /SNAPSHOT_SCOPE_DUPLICATE/,
  );
  assert.throws(
    () => selectComparisonBaseline({ ...current, createdAt: "invalid" }, []),
    /SNAPSHOT_ORDERING_METADATA_INVALID/,
  );
});

test("complete but unrequested scopes are not compared", () => {
  const current = snapshot("current", "2026-03-02T00:00:00Z", {
    scopes: [{ id: "logon", requested: false, coverage: "complete", reasonCode: null }],
  });
  const previous = snapshot("previous", "2026-03-01T00:00:00Z");
  const selection = selectComparisonBaseline(current, [previous]);
  assert.deepEqual(selection?.comparableScopes, []);
});
