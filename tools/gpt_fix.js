// Complete a Huawei ptable template for this disk the same way the device's own working GPT does it:
// copy AlternateLBA / LastUsableLBA from a reference table, extend the last partition to the disk end,
// then recompute both CRC32s.  Nothing is written to any device by this script.
// node tools/gpt_fix.js <template.efi> <reference.gpt.img> <out.efi> [--no-extend]
const fs = require('fs');
const z = require('zlib');

const [tplPath, refPath, outPath, ...flags] = process.argv.slice(2);
if (!tplPath || !refPath || !outPath) {
  console.error('usage: node gpt_fix.js <template> <reference> <out> [--no-extend]');
  process.exit(2);
}
const H = 0x200;
const rd = (p) => {
  const b = fs.readFileSync(p);
  const off = b.subarray(H, H + 8).toString('latin1') === 'EFI PART' ? H : b.indexOf('EFI PART', 0, 'latin1');
  if (off !== H) throw new Error(`${p}: EFI PART not at 0x200`);
  return b;
};
const tpl = rd(tplPath);
const ref = rd(refPath);
const num = tpl.readUInt32LE(H + 0x50);
const esz = tpl.readUInt32LE(H + 0x54);
const eBase = Number(tpl.readBigUInt64LE(H + 0x48)) * 512;

const alt = ref.readBigUInt64LE(H + 0x20);
const lastUsable = ref.readBigUInt64LE(H + 0x30);
tpl.writeBigUInt64LE(alt, H + 0x20);
tpl.writeBigUInt64LE(lastUsable, H + 0x30);
console.log('AlternateLBA  ', ref.readBigUInt64LE(H + 0x18), '->', alt, ' (disk sectors-1)');
console.log('LastUsableLBA 34 ->', lastUsable);

// the template truncates the last partition (userdata); extend it like the reference table does
let last = -1;
for (let i = 0; i < num; i++) if (tpl.readBigUInt64LE(eBase + i * esz + 0x20) !== 0n) last = i;
const lastName = Buffer.from(tpl.subarray(eBase + last * esz + 0x38, eBase + last * esz + 0x38 + 72))
  .toString('utf16le').replace(/\0+$/, '');
const before = tpl.readBigUInt64LE(eBase + last * esz + 0x28);
const refLast = (() => {
  const n = ref.readUInt32LE(H + 0x50), e = ref.readUInt32LE(H + 0x54), eb = Number(ref.readBigUInt64LE(H + 0x48)) * 512;
  for (let i = ref.readUInt32LE(H + 0x50) - 1; i >= 0; i--) if (ref.readBigUInt64LE(eb + i * e + 0x20) !== 0n) return ref.readBigUInt64LE(eb + i * e + 0x28);
  return 0n;
})();
if (flags.includes('--no-extend')) {
  console.log(`extend ${lastName}: skipped`);
} else {
  tpl.writeBigUInt64LE(refLast, eBase + last * esz + 0x28);
  console.log(`extend ${lastName}: LBA ${before} -> ${refLast}  (${(((Number(refLast) - Number(before) + 1) * 512) / 1024 ** 2).toFixed(0)} MB)`);
}

const hsz = tpl.readUInt32LE(H + 0x0c);
const crcE = z.crc32(tpl.subarray(eBase, eBase + num * esz)) >>> 0;
const oldH = tpl.readUInt32LE(H + 0x10).toString(16), oldE = tpl.readUInt32LE(H + 0x58).toString(16);
tpl.writeUInt32LE(crcE, H + 0x58); // must land in the header before the header CRC is taken over it
const scratch = Buffer.from(tpl);
scratch.writeUInt32LE(0, H + 0x10);
tpl.writeUInt32LE(z.crc32(scratch.subarray(H, H + hsz)) >>> 0, H + 0x10);
fs.writeFileSync(outPath, tpl);
console.log('HeaderCRC32  ', oldH, '->', (tpl.readUInt32LE(H + 0x10) >>> 0).toString(16));
console.log('EntriesCRC32 ', oldE, '->', (crcE >>> 0).toString(16), oldE === (crcE >>> 0).toString(16) ? '(entries array unchanged)' : '(entries array changed by the extend)');
console.log('wrote', outPath, tpl.length.toLocaleString(), 'bytes');