import { describe, expect, it } from "vitest";
import { checkClearance } from "../kernel/vcad-kernel.mjs";

function documentWithGap(centerX: number) {
  return {
    id: "clearance-fixture", name: "Clearance fixture", units: "mm", revision: 1, backend: "native-metal", operations: [],
    features: [
      { id: "body-a", name: "Body A", kind: "box", visible: true, params: { width: 10, height: 10, depth: 10, x: 0, y: 0, z: 0 } },
      { id: "body-b", name: "Body B", kind: "box", visible: true, params: { width: 10, height: 10, depth: 10, x: centerX, y: 1, z: 1 } }
    ]
  };
}

describe("vcad clearance adapter", () => {
  it("classifies separated, touching, and intersecting bodies", async () => {
    const clear = await checkClearance(documentWithGap(15), "body-a", "body-b");
    expect(clear).toMatchObject({ classification: "clear", intersecting: false, distance: 5 });

    const touchingDocument = documentWithGap(10);
    touchingDocument.features[1].params.y = 10;
    touchingDocument.features[1].params.z = 0;
    const touching = await checkClearance(touchingDocument, "body-a", "body-b");
    expect(touching.classification).toBe("touching");
    expect(Math.abs(touching.distance)).toBeLessThan(1e-6);

    const interference = await checkClearance(documentWithGap(8), "body-a", "body-b");
    expect(interference.classification).toBe("interference");
    expect(interference.intersecting).toBe(true);
    expect(interference.distance).toBeLessThan(0);
  });
});
