import { readFile } from "node:fs/promises";

const [checkedInPath, sourceBuildPath] = process.argv.slice(2);

if (!checkedInPath || !sourceBuildPath) {
  console.error("Usage: node scripts/compare-wasm-interface.mjs <checked-in.wasm> <source-build.wasm>");
  process.exit(2);
}

function describe(module) {
  const compare = (left, right) => JSON.stringify(left).localeCompare(JSON.stringify(right));
  return {
    imports: WebAssembly.Module.imports(module).sort(compare),
    exports: WebAssembly.Module.exports(module).sort(compare),
  };
}

const checkedIn = describe(new WebAssembly.Module(await readFile(checkedInPath)));
const sourceBuild = describe(new WebAssembly.Module(await readFile(sourceBuildPath)));

if (JSON.stringify(checkedIn) !== JSON.stringify(sourceBuild)) {
  console.error("The source-built kernel does not expose the checked-in WebAssembly interface.");
  process.exit(1);
}

console.log("Source-built and checked-in kernels expose the same WebAssembly interface.");
