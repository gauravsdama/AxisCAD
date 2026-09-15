import { describe, expect, it } from "vitest";
import { applyPrompt, editFeature, initialDocument } from "../src/domain";
import { validateOperation } from "../src/bridge";

describe("CAD operation model", () => {
  it("creates a new revision and receipt-ready history for manual edits", () => {
    const result = editFeature(initialDocument, "pocket-holes", "diameter", 6, "You");
    expect(result.revision).toBe(19);
    expect(result.features.find((feature) => feature.id === "pocket-holes")?.params.diameter).toBe(6);
    expect(result.operations[0]).toMatchObject({ author: "You", revision: 19 });
  });

  it("routes AI language changes through the same editable parameters", () => {
    const result = applyPrompt(initialDocument, "Make the mounting holes larger");
    expect(result.features.find((feature) => feature.id === "pocket-holes")?.params.diameter).toBe(6);
    expect(result.operations[0].author).toBe("AI");
  });

  it("rejects stale bridge operations", () => {
    const receipt = validateOperation({ name: "set_parameter", expectedRevision: 17, args: {} }, initialDocument);
    expect(receipt).toMatchObject({ ok: false, revision: 18 });
  });
});
