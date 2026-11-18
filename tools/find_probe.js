// Reconstruct the order of: which LK was RAM-loaded, and when the "partition length get error" probe happened.
const fs = require("fs");
const t = fs.readFileSync(process.argv[2], "utf8");
const marks = [
  ["LOAD_B", /deepflash\.ps1 -Port COM3 -Plan \\"0x00020000=[^"]*?hisi65x_b_fastboot\.img/g],
  ["LOAD_A", /deepflash\.ps1 -Port COM3 -Plan \\"0x00020000=[^"]*?hisi65x_a_fastboot\.img/g],
  ["PLAN_ANY", /deepflash\.ps1 -Port [^\\"]{0,10} -Plan/g],
  ["PLGE", /partition length get error/g],
  ["FLASH_KERNEL", /flash \\?"?kernel/g],
  ["ERASE_BOOT", /erase \\?"?boot\\?["']?( |\\n|;)/g],
  ["FLASH_PTABLE", /flash \\?"?ptable/g],
  ["RESTORE", /restore_b186\.sh/g],
];
const hits = [];
for (const [tag, re] of marks) {
  for (const m of t.matchAll(re)) hits.push({ at: m.index, tag });
}
hits.sort((a, b) => a.at - b.at);
let out = "";
let prev = -1;
for (const h of hits) {
  if (h.at - prev < 4000 && h.tag[0] !== "L") continue; // collapse repeats within the same message
  prev = h.at;
  out += `${h.at}\t${h.tag}\n`;
}
console.log(out.trim().split("\n").slice(-70).join("\n"));