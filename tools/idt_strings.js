// Recover the XML attribute names used by IDT's download config, by mining the string
// tables adjacent to the known node names inside DownloadBoot.dll / DownloadFastboot.dll.
const fs = require("fs");
const WORD = /[A-Za-z_][A-Za-z0-9_.\\-]{1,28}/g;
const ANCHORS = ["configuration", "bootloaderimage", "xloader", "usbloader", "ptable", "update_solution", "TiXml"];
const PREFIX = /^(name|path|file|addr|attr|sec|size|len|flag|type|offset|start|end|erase|verify|crc|update|image|part|dl|boot|fast|modem|usb|xload|ptab|sol|ver|id|value|version|count|num|index|dest|target|src|write|skip|down|slot|chip|com|port|baud|mode|solution|his)/i;
const API = /^(Get|Set|Create|Open|Close|Read|Write|Delete|Query|Enum|Load|Free|Init|Destroy|Send|Copy|Add|Remove|Find|Lock|Unlock|Msg|Win|Reg|End|Is|Enter|Leave|Heap|Size|Compare|Notify|Draw|Show|Update|Insert|Move|Bind|Calc|Begin|Encode|Decode|TiXml|CDld|CCsv|CStd|CMem|CFile|CWin|CString|CMap|CPtr|CDao|CHandle|CSimple)/;

for (const f of process.argv.slice(2)) {
  const b = fs.readFileSync(f);
  const s = b.toString("latin1");
  const hits = new Set();
  for (const a of ANCHORS) {
    let i = 0;
    while ((i = s.indexOf(a, i)) >= 0) {
      const base = Math.max(0, i - 3000);
      const blk = s.slice(base, Math.min(b.length, i + 3000));
      for (const t of blk.match(WORD) || []) if (!API.test(t) && PREFIX.test(t)) hits.add(t);
      i += a.length;
    }
  }
  console.log("###", f, "候选", hits.size);
  console.log([...hits].sort().join(" "));
  console.log();
}