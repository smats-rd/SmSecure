import type { ObservedValue } from "./observation.ts";

export interface SnapshotCompatibility {
  readonly collectionProfile: ObservedValue;
  readonly targetScope: ObservedValue;
  readonly executionConditions: ObservedValue;
  readonly autorunscVersion: ObservedValue;
  readonly analysisVersion: ObservedValue;
  readonly identityRuleVersion: ObservedValue;
}

export type ScopeCoverage = "complete" | "partial" | "failed" | "unknown";

export interface SnapshotScope {
  readonly id: string;
  readonly coverage: ScopeCoverage;
}

export interface SnapshotDescriptor {
  readonly id: string;
  readonly createdAt: string;
  readonly compatibility: SnapshotCompatibility;
  readonly requestedScopes: readonly string[];
  readonly scopes: readonly SnapshotScope[];
}

export interface BaselineSelection {
  readonly snapshot: SnapshotDescriptor;
  readonly comparableScopes: readonly string[];
}

const compatibilityFields = [
  "collectionProfile",
  "targetScope",
  "executionConditions",
  "autorunscVersion",
  "analysisVersion",
  "identityRuleVersion",
] as const satisfies readonly (keyof SnapshotCompatibility)[];

export function areSnapshotsCompatible(
  left: SnapshotDescriptor,
  right: SnapshotDescriptor,
): boolean {
  return compatibilityFields.every((field) => {
    const leftValue = left.compatibility[field];
    const rightValue = right.compatibility[field];
    return (
      leftValue.state === "known" &&
      rightValue.state === "known" &&
      leftValue.value === rightValue.value
    );
  });
}

function snapshotOrder(snapshot: SnapshotDescriptor): { readonly timestamp: number; readonly id: string } {
  const timestamp = Date.parse(snapshot.createdAt);
  if (!Number.isFinite(timestamp) || snapshot.id.length === 0) {
    throw new Error("SNAPSHOT_ORDERING_METADATA_INVALID");
  }
  return { timestamp, id: snapshot.id };
}

function compareOrder(
  left: { readonly timestamp: number; readonly id: string },
  right: { readonly timestamp: number; readonly id: string },
): number {
  if (left.timestamp !== right.timestamp) return left.timestamp - right.timestamp;
  if (left.id < right.id) return -1;
  if (left.id > right.id) return 1;
  return 0;
}

function completeRequestedScopes(snapshot: SnapshotDescriptor): Set<string> {
  const requested = new Set(snapshot.requestedScopes);
  const completed = new Set<string>();
  const seen = new Set<string>();
  for (const scope of snapshot.scopes) {
    if (seen.has(scope.id)) throw new Error("SNAPSHOT_SCOPE_DUPLICATE");
    seen.add(scope.id);
    if (requested.has(scope.id) && scope.coverage === "complete") {
      completed.add(scope.id);
    }
  }
  return completed;
}

export function selectComparisonBaseline(
  current: SnapshotDescriptor,
  candidates: readonly SnapshotDescriptor[],
): BaselineSelection | null {
  const currentOrder = snapshotOrder(current);
  const previous = candidates
    .filter((candidate) => areSnapshotsCompatible(current, candidate))
    .map((snapshot) => ({ snapshot, order: snapshotOrder(snapshot) }))
    .filter(({ order }) => compareOrder(order, currentOrder) < 0)
    .sort((left, right) => compareOrder(right.order, left.order));
  const baseline = previous[0];
  if (baseline === undefined) return null;

  const currentComplete = completeRequestedScopes(current);
  const baselineComplete = completeRequestedScopes(baseline.snapshot);
  const comparableScopes = [...currentComplete]
    .filter((scopeId) => baselineComplete.has(scopeId))
    .sort();
  return { snapshot: baseline.snapshot, comparableScopes };
}
