import assert from "node:assert/strict";
import { test } from "node:test";
import { compareField, compareObservations, primaryState, summarizeContent } from "./comparison.ts";
import { storeArguments } from "./observation.ts";
import type { Observation, ObservedValue } from "./observation.ts";

const known = (value: string): ObservedValue => ({ state: "known", value });
const missing: ObservedValue = { state: "unavailable", reason: "missing" };

function observation(id: string): Observation {
  return {
    id,
    snapshotId: id,
    identity: { state: "identified", itemId: "item" },
    sourceKind: known("registry"),
    location: known("location"),
    name: known("name"),
    scope: known("scope"),
    fields: {
      imagePath: known("app.exe"),
      signatureStatus: known("verified"),
      signer: known("publisher"),
      hashAlgorithm: known("sha256"),
      hash: known("hash"),
    },
    arguments: storeArguments(true, { state: "collected", value: "" }),
  };
}

test("unknown values never compare equal", () => {
  assert.deepEqual(compareField(missing, missing), {
    state: "not_compared",
    previousReason: "missing",
    currentReason: "missing",
  });
});

test("observations must have the same resolved item before content comparison", () => {
  const first = observation("a");
  const other: Observation = { ...observation("b"), identity: { state: "identified", itemId: "other" } };
  const duplicate: Observation = {
    ...observation("c"),
    identity: { state: "unresolved", reason: "duplicate_identity" },
  };
  assert.throws(() => compareObservations(first, other), /OBSERVATION_IDENTITY_NOT_MATCHED/);
  assert.throws(() => compareObservations(first, duplicate), /OBSERVATION_IDENTITY_NOT_MATCHED/);
});

test("arguments not persisted by policy retain collection state but not value", () => {
  for (const input of [
    { state: "collected", value: "secret" } as const,
    { state: "collection_failed" } as const,
    { state: "not_attempted" } as const,
  ]) {
    const stored = storeArguments(false, input);
    assert.equal(stored.collectionState, input.state);
    assert.equal(stored.persistenceState, "not_persisted_by_policy");
    assert.equal(stored.value, null);
    assert.equal(JSON.stringify(stored).includes("secret"), false);
  }
});

test("persisted empty arguments are distinct from unavailable arguments", () => {
  assert.deepEqual(storeArguments(true, { state: "collected", value: "" }), {
    collectionState: "collected",
    persistenceState: "persisted",
    value: "",
  });
  assert.deepEqual(storeArguments(true, { state: "collection_failed" }), {
    collectionState: "collection_failed",
    persistenceState: "not_persisted_due_to_collection_failure",
    value: null,
  });
  assert.throws(() => storeArguments(true, { state: "not_attempted" }), /ARGUMENT_COLLECTION_INCOMPLETE/);
});

test("identical known fields compare unchanged", () => {
  const result = summarizeContent(compareObservations(observation("a"), observation("b")));
  assert.deepEqual(result, { difference: "no_change_in_compared_fields", coverage: "all" });
  assert.equal(primaryState("unique", "both_present", result), "unchanged");
});

test("changed executable stays changed while arguments remain uncomparable", () => {
  const previous = observation("a");
  const current: Observation = {
    ...observation("b"),
    fields: { ...previous.fields, imagePath: known("different.exe"), hash: known("different hash") },
    arguments: storeArguments(false, { state: "collected", value: "secret" }),
  };
  const fields = compareObservations(previous, current);
  assert.equal(fields.imagePath.state, "different");
  assert.equal(fields.hash.state, "different");
  assert.deepEqual(fields.arguments, {
    state: "not_compared",
    previousReason: null,
    currentReason: "not_persisted_by_policy",
  });
  const summary = summarizeContent(fields);
  assert.deepEqual(summary, { difference: "changed", coverage: "partial" });
  assert.equal(primaryState("unique", "both_present", summary), "changed");
});

test("policy change without a known difference is not unconditionally unchanged", () => {
  const previous = observation("a");
  const current: Observation = {
    ...observation("b"),
    arguments: storeArguments(false, { state: "collection_failed" }),
  };
  const fields = compareObservations(previous, current);
  assert.deepEqual(fields.arguments, {
    state: "not_compared",
    previousReason: null,
    currentReason: "collection_failed",
  });
  const summary = summarizeContent(fields);
  assert.deepEqual(summary, { difference: "no_change_in_compared_fields", coverage: "partial" });
  assert.equal(primaryState("unique", "both_present", summary), "no_change_partial");
});

test("hash values with incompatible or unknown algorithms are not compared", () => {
  const previous = observation("a");
  const current: Observation = {
    ...observation("b"),
    fields: { ...previous.fields, hashAlgorithm: known("sha1") },
  };
  const differentAlgorithm = compareObservations(previous, current);
  assert.equal(differentAlgorithm.hashAlgorithm.state, "different");
  assert.equal(differentAlgorithm.hash.state, "not_compared");
  const unknownAlgorithm = compareObservations(previous, {
    ...current,
    fields: { ...current.fields, hashAlgorithm: missing },
  });
  assert.deepEqual(unknownAlgorithm.hash, {
    state: "not_compared",
    previousReason: null,
    currentReason: "hash_algorithm_unavailable",
  });
});

test("no comparable fields is not comparable", () => {
  const base = observation("a");
  const unavailable: Observation = {
    ...base,
    fields: { imagePath: missing, signatureStatus: missing, signer: missing, hashAlgorithm: missing, hash: missing },
    arguments: storeArguments(false, { state: "not_attempted" }),
  };
  const summary = summarizeContent(compareObservations(unavailable, unavailable));
  assert.deepEqual(summary, { difference: "not_comparable", coverage: "none" });
  assert.equal(primaryState("unique", "both_present", summary), "not_comparable");
});

test("matching and existence determine the main state without inferring coverage", () => {
  assert.equal(primaryState("unmatchable", "first_observation", null), "not_comparable");
  assert.equal(primaryState("unique", "first_observation", null), "first_observation");
  assert.equal(primaryState("unique", "added", null), "added");
  assert.equal(primaryState("unique", "removed", null), "removed");
  assert.equal(primaryState("unique", "indeterminate", null), "not_comparable");
  assert.throws(() => primaryState("unique", "both_present", null), /CONTENT_COMPARISON_REQUIRED/);
});
