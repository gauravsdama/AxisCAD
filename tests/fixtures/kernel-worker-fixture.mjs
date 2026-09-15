let body = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => { body += chunk; });
process.stdin.on("end", () => {
  const request = JSON.parse(body);
  if (request.action === "hang") { setInterval(() => {}, 1_000); return; }
  if (request.action === "crash") { process.stderr.write("fixture crash\n"); process.exit(7); }
  process.stdout.write(`${JSON.stringify({ ok: true, echoed: request })}\n`);
});
