export interface KernelClearanceResult {
  ok: boolean;
  revision: number;
  feature_id: string;
  second_feature_id: string;
  distance: number;
  intersecting: boolean;
  classification: "clear" | "touching" | "interference";
  point_a: { x: number; y: number; z: number };
  point_b: { x: number; y: number; z: number };
  adapter: string;
  tessellation_segments: number;
}

export function checkClearance(document: unknown, featureId: string, secondFeatureId: string): Promise<KernelClearanceResult>;
