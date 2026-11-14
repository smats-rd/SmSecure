import { argumentsForComparison } from "./observation.ts";
import type { ComparisonField, Observation, ObservedValue, UnavailableReason } from "./observation.ts";

export type FieldComparison =
  | { readonly state: "equal" | "different" }
  | {
      readonly state: "not_compared";
      readonly previousReason: UnavailableReason | null;
      readonly currentReason: UnavailableReason | null;
    };

export function compareField(previous: ObservedValue, current: ObservedValue): FieldComparison {
  if (previous.state === "known" && current.state === "known") {
    return { state: previous.value === current.value ? "equal" : "different" };
  }
  return {
    state: "not_compared",
    previousReason: previous.state === "unavailable" ? previous.reason : null,
    currentReason: current.state === "unavailable" ? current.reason : null,
  };
}

const fields = [
  "imagePath",
  "signatureStatus",
  "signer",
  "hashAlgorithm",
  "hash",
] as const satisfies readonly Exclude<ComparisonField, "arguments">[];

export type FieldComparisons = Readonly<Record<ComparisonField, FieldComparison>>;

export function compareObservations(previous: Observation, current: Observation): FieldComparisons {
  if (
    previous.identity.state !== "identified" ||
    current.identity.state !== "identified" ||
    previous.identity.itemId !== current.identity.itemId
  ) {
    throw new Error("OBSERVATION_IDENTITY_NOT_MATCHED");
  }
  const previousAlgorithm = previous.fields.hashAlgorithm;
  const currentAlgorithm = current.fields.hashAlgorithm;
  let hash: FieldComparison;
  if (previousAlgorithm.state !== "known" || currentAlgorithm.state !== "known") {
    hash = {
      state: "not_compared",
      previousReason: previousAlgorithm.state === "known" ? null : "hash_algorithm_unavailable",
      currentReason: currentAlgorithm.state === "known" ? null : "hash_algorithm_unavailable",
    };
  } else if (previousAlgorithm.value !== currentAlgorithm.value) {
    hash = {
      state: "not_compared",
      previousReason: "incompatible_hash_algorithm",
      currentReason: "incompatible_hash_algorithm",
    };
  } else {
    hash = compareField(previous.fields.hash, current.fields.hash);
  }
  const result = {
    imagePath: compareField(previous.fields.imagePath, current.fields.imagePath),
    signatureStatus: compareField(previous.fields.signatureStatus, current.fields.signatureStatus),
    signer: compareField(previous.fields.signer, current.fields.signer),
    hashAlgorithm: compareField(previous.fields.hashAlgorithm, current.fields.hashAlgorithm),
    hash,
    arguments: compareField(argumentsForComparison(previous.arguments), argumentsForComparison(current.arguments)),
  } satisfies Record<ComparisonField, FieldComparison>;
  return result;
}

export type Existence = "first_observation" | "both_present" | "added" | "removed" | "indeterminate";
export type Coverage = "all" | "partial" | "none";
export type ContentDifference = "changed" | "no_change_in_compared_fields" | "not_comparable";
export type PrimaryState =
  | "first_observation"
  | "added"
  | "removed"
  | "changed"
  | "no_change_partial"
  | "unchanged"
  | "not_comparable";

export type ContentSummary =
  | { readonly difference: "changed"; readonly coverage: "all" | "partial" }
  | { readonly difference: "no_change_in_compared_fields"; readonly coverage: "all" | "partial" }
  | { readonly difference: "not_comparable"; readonly coverage: "none" };

export function summarizeContent(comparisons: FieldComparisons): ContentSummary {
  const results = [...fields.map((field) => comparisons[field]), comparisons.arguments];
  const compared = results.filter((result) => result.state !== "not_compared").length;
  const changed = results.some((result) => result.state === "different");
  if (compared === 0) return { difference: "not_comparable", coverage: "none" };
  return {
    difference: changed ? "changed" : "no_change_in_compared_fields",
    coverage: compared === results.length ? "all" : "partial",
  };
}

export function primaryState(
  matching: "unique" | "unmatchable",
  existence: Existence,
  content: ContentSummary | null,
): PrimaryState {
  if (matching === "unmatchable") return "not_comparable";
  switch (existence) {
    case "first_observation":
    case "added":
    case "removed":
      return existence;
    case "indeterminate":
      return "not_comparable";
    case "both_present":
      if (content === null) throw new Error("CONTENT_COMPARISON_REQUIRED");
      if (content.difference === "changed") return "changed";
      if (content.difference === "not_comparable") return "not_comparable";
      return content.coverage === "all" ? "unchanged" : "no_change_partial";
  }
}
