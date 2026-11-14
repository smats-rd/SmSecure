import assert from "node:assert/strict";
import { test } from "node:test";
import { AutorunscCsvError, parseAutorunscCsv } from "./autorunscCsv.ts";

const header =
  "Entry Location,Entry,Profile,Category,Image Path,Launch String,Description";

test("parses BOM-prefixed CRLF CSV and keeps empty fields", () => {
  const rows = parseAutorunscCsv(
    `\uFEFF${header}\r\nHKCU\\Run,App,Current,Logon,C:\\app.exe,"C:\\app.exe",\r\n`,
  );
  assert.equal(rows.length, 1);
  assert.equal(rows[0]?.Entry, "App");
  assert.equal(rows[0]?.Description, "");
});

test("parses escaped quotes, commas, embedded newlines, and non-ASCII text", () => {
  const rows = parseAutorunscCsv(
    `${header}\nHKCU\\Run,App,Current,Logon,C:\\app.exe,"""C:\\app.exe"" /arg ""two, 日本語""\nnext line",説明\n`,
  );
  assert.equal(rows.length, 1);
  assert.equal(rows[0]?.["Launch String"], '"C:\\app.exe" /arg "two, 日本語"\nnext line');
  assert.equal(rows[0]?.Description, "説明");
});

test("skips blank records without treating empty-valued rows as blank", () => {
  const rows = parseAutorunscCsv(`${header}\n\n,,,,,,\n`);
  assert.equal(rows.length, 1);
  assert.equal(rows[0]?.Entry, "");
});

test("rejects missing or duplicate headers without including input in the error", () => {
  assert.throws(
    () => parseAutorunscCsv("secret,header\nsecret,value"),
    (error: unknown) =>
      error instanceof AutorunscCsvError &&
      error.code === "CSV_HEADER_UNSUPPORTED" &&
      !error.message.includes("secret"),
  );
  assert.throws(
    () => parseAutorunscCsv(`${header},Entry\n`),
    (error: unknown) =>
      error instanceof AutorunscCsvError && error.code === "CSV_DUPLICATE_HEADER",
  );
});

test("rejects malformed quoting and rows with a different number of columns", () => {
  assert.throws(
    () => parseAutorunscCsv(`${header}\nApp,Current,"unterminated`),
    (error: unknown) => error instanceof AutorunscCsvError && error.code === "CSV_MALFORMED",
  );
  assert.throws(
    () => parseAutorunscCsv(`${header}\nonly,two`),
    (error: unknown) =>
      error instanceof AutorunscCsvError && error.code === "CSV_ROW_WIDTH_MISMATCH",
  );
});

test("rejects an empty CSV", () => {
  assert.throws(
    () => parseAutorunscCsv("\uFEFF\r\n"),
    (error: unknown) => error instanceof AutorunscCsvError && error.code === "CSV_EMPTY",
  );
});
