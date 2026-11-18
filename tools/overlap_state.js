// Report, per EMUI 5.1 partition, how much of its block range the EMUI 8 writes covered.
// Sources: rb186/efi.img = the 5.1 table this phone shipped with (dumped live, sha e3741c8a);
// dd_set/manifest.json = the ranges the EMUI 8 set wrote (each was read back and sha256-checked).
const fs = require("fs");

// Reuse tools/gpt_parse.js, which is the parser these tables were checked with, instead of
// hand-rolling a second GPT reader here.
function table(file) {
  const out = require("child_process").execSync(`node tools/gpt_parse.js ${file}`, { encoding: "utf8" });
  return [...out.matchAll(/^p *\d+ +(\S+) +[\d.]+ MB +LBA (\d+)\.\.(\d+)$/gm)].map((m) => ({
    name: m[1],
    first: BigInt(m[2]),
    last: BigInt(m[3]),
  }));
}

const b186 = table("rb186/efi.img");
const man = JSON.parse(fs.readFileSync("dd_set/manifest.json", "utf8"));
const W = man
  .filter((e) => e.first !== undefined && e.sectors)
  .map((e) => ({ a: BigInt(e.first), b: BigInt(e.first) + BigInt(e.sectors) - 1n, nm: e.name }));
W.push({ a: 0n, b: 33n, nm: "efi(GPT)" });

const total = W.reduce((s, w) => s + Number(w.b - w.a + 1n), 0);
console.log(`EMUI 8 写过的块数 ${W.length}，合计 LBA ${total.toLocaleString()}（另有 xloader，写在 HW 引导区，不在 GPT 内，位置与结果均不可证）\n`);

console.log("5.1 各分区在当前盘上的处境：\n");
let intact = 0;
for (const p of b186) {
  let hits = [], covered = 0n;
  for (const w of W) {
    const lo = p.first > w.a ? p.first : w.a;
    const hi = p.last < w.b ? p.last : w.b;
    if (lo <= hi) { covered += hi - lo + 1n; hits.push(w.nm); }
  }
  const pct = Number(covered * 100n / BigInt(p.last - p.first + 1n));
  if (pct === 0) { intact++; continue; }
  const verdict = pct >= 99 ? "已被完全覆盖" : `部分覆盖 ${pct}%`;
  console.log(`  ${p.name.padEnd(16)} ${verdict.padEnd(18)} ${hits.slice(0, 5).join(",")}`);
}
console.log(`\n其余 ${intact} 个 5.1 分区当前 0% 被覆盖（含 vrl/nvme/oeminfo/modemnvm_*/secure_storage/persist/recovery2 等）`);