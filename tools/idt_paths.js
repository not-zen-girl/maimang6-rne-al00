// Dump every backslash-qualified config path (ASCII and UTF-16LE) out of the IDT binaries,
// which reveals the full element/attribute schema its parser walks.
const fs = require("fs");
const BS = String.fromCharCode(92, 92); // two source backslashes = match one literal backslash
const re = new RegExp("[A-Za-z_.]{0,20}(" + BS + "[A-Za-z_][A-Za-z0-9_.]{1,40}){1,8}", "g");

function asciiStrings(b) {
  return (b.toString("latin1").match(/[\x20-\x7e]{3,}/g) || []);
}
function utf16Strings(b) {
  const out = [];
  let cur = "";
  for (let i = 0; i + 1 < b.length; i += 2) {
    const lo = b[i], hi = b[i + 1];
    if (hi === 0 && lo >= 0x20 && lo <= 0x7e) cur += String.fromCharCode(lo);
    else { if (cur.length >= 3) out.push(cur); cur = ""; }
  }
  if (cur.length >= 3) out.push(cur);
  return out;
}

for (const f of process.argv.slice(2)) {
  const b = fs.readFileSync(f);
  const found = new Set();
  for (const s of [...asciiStrings(b), ...utf16Strings(b)]) {
    for (const m of s.match(re) || []) found.add(m);
  }
  const list = [...found].sort();
  console.log("###", f.split(/[\\/]/).pop(), "→", list.length, "条");
  console.log(list.map((s) => JSON.stringify(s)).join("\n"));
}