import type { DocumentState } from "./domain";

/**
 * The UI only talks in semantic operations. A production implementation sends
 * these messages to a local FreeCAD MCP process, never to GUI automation.
 */
export type CadOperation = {
  name: "inspect_document" | "set_parameter" | "validate_model" | "export_model";
  expectedRevision: number;
  args: Record<string, string | number>;
};

export type OperationReceipt = {
  ok: boolean;
  revision: number;
  affectedFeatureIds: string[];
  warnings: string[];
};

export function validateOperation(operation: CadOperation, document: DocumentState): OperationReceipt {
  if (operation.expectedRevision !== document.revision) {
    return { ok: false, revision: document.revision, affectedFeatureIds: [], warnings: ["Revision conflict — refresh the model before applying this change."] };
  }
  return { ok: true, revision: document.revision, affectedFeatureIds: [], warnings: [] };
}
