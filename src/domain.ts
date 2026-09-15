export type FeatureKind = "sketch" | "pad" | "pocket" | "fillet" | "pattern";

export type Feature = {
  id: string;
  name: string;
  kind: FeatureKind;
  visible: boolean;
  params: Record<string, number>;
};

export type Operation = {
  id: string;
  title: string;
  detail: string;
  author: "AI" | "You";
  revision: number;
  timestamp: string;
};

export type DocumentState = {
  id: string;
  revision: number;
  features: Feature[];
  operations: Operation[];
};

export const initialDocument: DocumentState = {
  id: "wall-bracket",
  revision: 18,
  features: [
    { id: "sketch-base", name: "Base profile", kind: "sketch", visible: true, params: { width: 86, height: 54 } },
    { id: "pad-base", name: "Base extrusion", kind: "pad", visible: true, params: { length: 6 } },
    { id: "pocket-holes", name: "Mounting holes", kind: "pocket", visible: true, params: { diameter: 5, offset: 12 } },
    { id: "fillet-edges", name: "Edge rounds", kind: "fillet", visible: true, params: { radius: 3 } },
  ],
  operations: [
    { id: "op-18", title: "Validated wall clearance", detail: "2.0 mm minimum clearance · no interference", author: "AI", revision: 18, timestamp: "Now" },
    { id: "op-17", title: "Rounded outer edges", detail: "Applied R3 fillets to 4 edges", author: "AI", revision: 17, timestamp: "2 min" },
    { id: "op-16", title: "Changed base thickness", detail: "Length: 4 mm → 6 mm", author: "You", revision: 16, timestamp: "5 min" },
  ],
};

export function editFeature(document: DocumentState, featureId: string, key: string, value: number, author: Operation["author"]): DocumentState {
  const feature = document.features.find((item) => item.id === featureId);
  if (!feature) return document;
  const revision = document.revision + 1;
  const before = feature.params[key];
  return {
    ...document,
    revision,
    features: document.features.map((item) => item.id === featureId ? { ...item, params: { ...item.params, [key]: value } } : item),
    operations: [{
      id: `op-${revision}`,
      title: `Updated ${feature.name}`,
      detail: `${key}: ${before ?? "—"} mm → ${value} mm`,
      author,
      revision,
      timestamp: "Now",
    }, ...document.operations],
  };
}

export function applyPrompt(document: DocumentState, prompt: string): DocumentState {
  const normalized = prompt.toLowerCase();
  if (normalized.includes("hole") || normalized.includes("mount")) {
    return editFeature(document, "pocket-holes", "diameter", 6, "AI");
  }
  if (normalized.includes("thick") || normalized.includes("strong")) {
    return editFeature(document, "pad-base", "length", 8, "AI");
  }
  return editFeature(document, "fillet-edges", "radius", 4, "AI");
}
