export type UnavailableReason =
  | "not_attempted"
  | "collection_failed"
  | "missing"
  | "unparseable"
  | "hash_algorithm_unavailable"
  | "incompatible_hash_algorithm"
  | "not_persisted_by_policy";

export type ObservedValue =
  | { readonly state: "known"; readonly value: string }
  | { readonly state: "unavailable"; readonly reason: UnavailableReason };

export type ArgumentsCollection =
  | { readonly state: "collected"; readonly value: string }
  | { readonly state: "collection_failed" }
  | { readonly state: "not_attempted" };

export type StoredArguments =
  | {
      readonly collectionState: "collected" | "collection_failed" | "not_attempted";
      readonly persistenceState: "not_persisted_by_policy";
      readonly value: null;
    }
  | {
      readonly collectionState: "collected";
      readonly persistenceState: "persisted";
      readonly value: string;
    }
  | {
      readonly collectionState: "collection_failed";
      readonly persistenceState: "not_persisted_due_to_collection_failure";
      readonly value: null;
    };

export function storeArguments(
  persist: boolean,
  collection: ArgumentsCollection,
): StoredArguments {
  if (!persist) {
    return {
      collectionState: collection.state,
      persistenceState: "not_persisted_by_policy",
      value: null,
    };
  }
  switch (collection.state) {
    case "collected":
      return {
        collectionState: "collected",
        persistenceState: "persisted",
        value: collection.value,
      };
    case "collection_failed":
      return {
        collectionState: "collection_failed",
        persistenceState: "not_persisted_due_to_collection_failure",
        value: null,
      };
    case "not_attempted":
      throw new Error("ARGUMENT_COLLECTION_INCOMPLETE");
  }
}

export function argumentsForComparison(args: StoredArguments): ObservedValue {
  if (args.persistenceState === "persisted") {
    return { state: "known", value: args.value };
  }
  if (args.collectionState === "collection_failed") {
    return { state: "unavailable", reason: "collection_failed" };
  }
  if (args.collectionState === "not_attempted") {
    return { state: "unavailable", reason: "not_attempted" };
  }
  return { state: "unavailable", reason: "not_persisted_by_policy" };
}

export type ComparisonField =
  | "imagePath"
  | "signatureStatus"
  | "signer"
  | "hashAlgorithm"
  | "hash"
  | "arguments";

export interface Observation {
  readonly id: string;
  readonly snapshotId: string;
  readonly identity:
    | { readonly state: "identified"; readonly itemId: string }
    | {
        readonly state: "unresolved";
        readonly reason: "duplicate_identity" | "missing_identity" | "unsupported_identity";
      };
  readonly sourceKind: ObservedValue;
  readonly location: ObservedValue;
  readonly name: ObservedValue;
  readonly scope: ObservedValue;
  readonly fields: Readonly<Record<Exclude<ComparisonField, "arguments">, ObservedValue>>;
  readonly arguments: StoredArguments;
}

export interface Review {
  readonly id: string;
  readonly observationId: string;
  readonly reviewedAt: string;
  readonly note: string | null;
}
