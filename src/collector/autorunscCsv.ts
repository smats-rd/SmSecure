export type AutorunscCsvErrorCode =
  | "CSV_EMPTY"
  | "CSV_MALFORMED"
  | "CSV_DUPLICATE_HEADER"
  | "CSV_HEADER_UNSUPPORTED"
  | "CSV_ROW_WIDTH_MISMATCH";

export class AutorunscCsvError extends Error {
  readonly code: AutorunscCsvErrorCode;

  constructor(code: AutorunscCsvErrorCode) {
    super(code);
    this.name = "AutorunscCsvError";
    this.code = code;
  }
}

export interface AutorunscRow {
  readonly [column: string]: string;
}

const requiredHeaders = [
  "Entry Location",
  "Entry",
  "Profile",
  "Category",
  "Image Path",
  "Launch String",
] as const;

function isLineBreak(character: string): boolean {
  return character === "\r" || character === "\n";
}

function consumeLineBreak(input: string, index: number): number {
  return input[index] === "\r" && input[index + 1] === "\n" ? index + 2 : index + 1;
}

function parseRecords(input: string): string[][] {
  const records: string[][] = [];
  let record: string[] = [];
  let field = "";
  let state: "field_start" | "unquoted" | "quoted" | "after_quote" = "field_start";
  let recordTouched = false;

  const finishField = (): void => {
    record.push(field);
    field = "";
    state = "field_start";
  };

  const finishRecord = (): void => {
    if (recordTouched || record.length > 0) {
      finishField();
      records.push(record);
    }
    record = [];
    field = "";
    state = "field_start";
    recordTouched = false;
  };

  for (let index = 0; index < input.length; ) {
    const character = input[index]!;
    switch (state) {
      case "field_start":
        if (character === '"') {
          state = "quoted";
          recordTouched = true;
          index += 1;
        } else if (character === ",") {
          finishField();
          recordTouched = true;
          index += 1;
        } else if (isLineBreak(character)) {
          finishRecord();
          index = consumeLineBreak(input, index);
        } else {
          field += character;
          state = "unquoted";
          recordTouched = true;
          index += 1;
        }
        break;
      case "unquoted":
        if (character === ",") {
          finishField();
          recordTouched = true;
          index += 1;
        } else if (isLineBreak(character)) {
          finishRecord();
          index = consumeLineBreak(input, index);
        } else if (character === '"') {
          throw new AutorunscCsvError("CSV_MALFORMED");
        } else {
          field += character;
          index += 1;
        }
        break;
      case "quoted":
        if (character === '"') {
          if (input[index + 1] === '"') {
            field += '"';
            index += 2;
          } else {
            state = "after_quote";
            index += 1;
          }
        } else {
          field += character;
          index += 1;
        }
        break;
      case "after_quote":
        if (character === ",") {
          finishField();
          recordTouched = true;
          index += 1;
        } else if (isLineBreak(character)) {
          finishRecord();
          index = consumeLineBreak(input, index);
        } else {
          throw new AutorunscCsvError("CSV_MALFORMED");
        }
        break;
    }
  }

  if (state === "quoted") {
    throw new AutorunscCsvError("CSV_MALFORMED");
  }
  if (recordTouched || record.length > 0) {
    finishRecord();
  }
  return records;
}

export function parseAutorunscCsv(input: string): readonly AutorunscRow[] {
  const records = parseRecords(input.replace(/^\uFEFF/, ""));
  const headers = records[0];
  if (headers === undefined || headers.length === 0) {
    throw new AutorunscCsvError("CSV_EMPTY");
  }
  if (headers.some((header) => header.length === 0)) {
    throw new AutorunscCsvError("CSV_HEADER_UNSUPPORTED");
  }
  if (new Set(headers).size !== headers.length) {
    throw new AutorunscCsvError("CSV_DUPLICATE_HEADER");
  }
  if (!requiredHeaders.every((required) => headers.includes(required))) {
    throw new AutorunscCsvError("CSV_HEADER_UNSUPPORTED");
  }

  return records.slice(1).map((record) => {
    if (record.length !== headers.length) {
      throw new AutorunscCsvError("CSV_ROW_WIDTH_MISMATCH");
    }
    const row: Record<string, string> = {};
    for (let index = 0; index < headers.length; index += 1) {
      row[headers[index]!] = record[index]!;
    }
    return row;
  });
}
