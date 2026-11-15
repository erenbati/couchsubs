// SPDX-License-Identifier: AGPL-3.0-only
import { execFileSync } from "node:child_process";
import { readdirSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { fileURLToPath } from "node:url";

const script = fileURLToPath(new URL("../scripts/build-index.mjs", import.meta.url));
const defaultPacks = fileURLToPath(new URL("../../../core/Sources/CouchSubsCore/Resources/packs/", import.meta.url));

describe("build-index.mjs", () => {
  it("uses the repository pack folder when no directory argument is supplied", () => {
    const expectedCount = readdirSync(defaultPacks).filter(name => name.endsWith(".json.gz")).length;
    expect(expectedCount).toBeGreaterThan(0);

    const output = execFileSync(process.execPath, [script], { encoding: "utf8" });
    const result = JSON.parse(output);

    expect(result.packs).toHaveLength(expectedCount);
  });
});
