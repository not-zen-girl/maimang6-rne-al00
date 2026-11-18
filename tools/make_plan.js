// Turn dd_set/manifest.json into the flat plan that the recovery shell script executes.
// Picks the largest dd block size dividing both the target byte offset and the payload length, so
// seek/count are exact for the write and for the read-back hash of the very same span.
const fs = require("fs");
const SP = 512;
const BS = [1048576, 262144, 65536, 32768, 16384, 8192, 4096, 2048, 1024, 512];
const pick = (off, size) => BS.find((b) => off % b === 0 && size % b === 0) || 512;

const man = JSON.parse(fs.readFileSync("dd_set/manifest.json", "utf8"));
const lines = ["# phase|name|src|bs|seek units|count units|expected sha256 of exactly that span"];
for (const e of man) {
  const off = e.first * SP;
  const bs = pick(off, e.size);
  if (off % bs || e.size % bs) throw new Error(`${e.name}: no block size divides ${off} / ${e.size}`);
  lines.push([e.phase, e.name, e.zero ? "ZERO" : `imgs/${e.name}.img`, bs, off / bs, e.size / bs, e.sha256 || "-"].join("|"));
}
fs.writeFileSync("dd_set/plan.txt", lines.join("\n") + "\n");
const byPhase = {};
for (const e of man) byPhase[e.phase] = (byPhase[e.phase] || 0) + (e.zero ? 0 : 1);
console.log(`${man.length} rows -> dd_set/plan.txt`);
console.log(`phase1 ${byPhase[1] || 0} writes, phase3 ${man.filter((e) => e.phase === 3).length} zeroing, phase4 ${byPhase[4] || 0} write (the GPT flip)`);
console.log(lines.slice(1, 4).join("\n"));