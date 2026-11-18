// Validate a GPT dump the way firmware does: header CRC32 and entry-array CRC32.
// The live dump from this handset is the known-good control - the boot ROM parses it today,
// so any routine that clears it can be trusted to judge the table we are about to flip in.
// usage: node tools/gpt_check.js <dump.img> [...], LBA0-33 dumps
const fs = require("fs");

const T = [];
for (let n = 0; n < 256; n++) {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  T.push(c >>> 0);
}
function crc32(b) {
  let c = 0xffffffff;
  for (let i = 0; i < b.length; i++) c = T[(c ^ b[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

for (const f of process.argv.slice(2)) {
  const all = fs.readFileSync(f);
  const H = all.subarray(0x200, 0x208).toString("latin1") === "EFI PART" ? 0x200 : all.indexOf("EFI PART", 0, "latin1");
  if (H < 0 || H + 92 > all.length) {
    console.log(`\n${f}: 窗口里没有 EFI PART 头 (${all.length} B, dump 起点是窗口第一字节) - 换个窗口重取`);
    continue;
  }
  const h = all.subarray(H, H + 512);
  const hdrSize = h.readUInt32LE(0x0c);
  const storedH = h.readUInt32LE(0x10);
  const copy = Buffer.from(h.subarray(0, hdrSize));
  copy.writeUInt32LE(0, 0x10);
  const calcH = crc32(copy);
  const count = h.readUInt32LE(0x50), esz = h.readUInt32LE(0x54);
  const entryLBA = Number(h.readBigUInt64LE(0x48));
  const arrBytes = count * esz;
  const base = entryLBA * 512 - (H === 0x200 ? 0 : 0);
  const arr = all.subarray(base, base + arrBytes);
  const storedA = h.readUInt32LE(0x58);
  const u64 = (o) => Number(h.readBigUInt64LE(o));
  const guid = Buffer.from(h.subarray(0x38, 0x48)).toString("hex").replace(/^(.{4})(.{2})(.{2})/, "$1-$2-$3");
  const ok = (a, b) => (a === b ? "OK" : `MISMATCH want ${b}`);
  console.log(`\n${f}`);
  console.log(`  sig=${h.subarray(0, 8).toString("latin1")} rev=${h.readUInt32LE(8).toString(16)} hdrSize=${hdrSize}`);
  console.log(`  myLBA=${u64(0x18)}  altLBA=${u64(0x20)}  firstUsable=${u64(0x28)}  lastUsable=${u64(0x30)}`);
  console.log(`  entryLBA=${entryLBA}  count=${count}  esz=${esz}  arrayBytes=${arrBytes} (fits ${arr.length === arrBytes ? "yes" : "NO, dump has " + arr.length})`);
  console.log(`  backup GPT should sit at altLBA=${u64(0x20)}, entries just below it at ${u64(0x20) - Math.ceil(arrBytes / 512) + 1}`);
  console.log(`  diskGUID=${guid}`);
  console.log(`  header CRC32 : ${calcH.toString(16)}  ${ok(calcH, storedH)}`);
  console.log(`  entries CRC32: ${crc32(arr).toString(16)}  ${ok(crc32(arr), storedA)}`);
}