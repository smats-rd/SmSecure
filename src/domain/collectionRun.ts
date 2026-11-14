import type { ObservedValue } from "./observation.ts";

export type CollectionRunId = string;

export type CollectionRunFailureCode =
  | "process_start_failed"
  | "process_exit_nonzero"
  | "process_timeout"
  | "csv_parse_failed"
  | "collection_cancelled"
  | "database_write_failed"
  | "unexpected_failure";

export interface CollectionRunConditions {
  readonly collectionProfile: ObservedValue;
  readonly targetScope: ObservedValue;
  readonly executionConditions: ObservedValue;
}

interface CollectionRunBase {
  readonly id: CollectionRunId;
  readonly startedAt: string;
  readonly conditions: CollectionRunConditions;
}

export type CollectionRun =
  | (CollectionRunBase & {
      readonly state: "running";
      readonly finishedAt: null;
      readonly failureCode: null;
    })
  | (CollectionRunBase & {
      readonly state: "succeeded";
      readonly finishedAt: string;
      readonly failureCode: null;
    })
  | (CollectionRunBase & {
      readonly state: "failed";
      readonly finishedAt: string;
      readonly failureCode: Exclude<
        CollectionRunFailureCode,
        "process_timeout" | "csv_parse_failed" | "collection_cancelled"
      >;
    })
  | (CollectionRunBase & {
      readonly state: "timed_out";
      readonly finishedAt: string;
      readonly failureCode: "process_timeout";
    })
  | (CollectionRunBase & {
      readonly state: "parse_failed";
      readonly finishedAt: string;
      readonly failureCode: "csv_parse_failed";
    })
  | (CollectionRunBase & {
      readonly state: "interrupted";
      readonly finishedAt: string;
      readonly failureCode: "collection_cancelled";
    });
