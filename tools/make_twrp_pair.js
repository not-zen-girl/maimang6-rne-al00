#!/usr/bin/env node
// Build the two one-half boot images that EMUI 8's LK reads as `kernel` and `ramdisk`,
// carrying TWRP's payloads instead of the EMUI 8 ones.
//
// EMUI 8 splits one Android boot image across two partitions:
//   kernel  partition = boot header with ramdisk_size=0, gzip kernel after page 1
//   ramdisk partition = boot header with kernel_size=0,  gzip ramdisk after page 1
// So only the two size fields change; every address, tags pointer and cmdline stays
// the value the 8.0 LK already accepts.
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

const HOST_KERNEL = "dd_set/kernel.img";
const HOST_RAMDISK = "dd_set/ramdisk.img";
const TWRP = "twrp_rne_emui51.img";
const OUT = "rb379";
const NAME_KERNEL = "twrp_kernel_for_kernel.img";
const NAME_RAMDISK = "twrp_ramdisk_for_ramdisk.img";

function die(msg) {
  console.log(`!! ${msg}`);
  process.exit(1);
}
function ok(msg) {
  console.log(`   ${msg}`);
}
function gz(b, o) {
  return b.length >= o + 2 && b[o] === 0x1f && b[o + 1] === 0x8b;
}
function avb(b, o) {
  return b.length >= o + 4 && b.subarray(o, o + 4).toString("latin1") === "AVB0";
}

// Read a boot header plus the location of its two payloads.
function readBoot(file) {
  const fd = fs.openSync(file, "r");
  const size = fs.fstatSync(fd).size;
  const hdr = Buffer.alloc(4096);
  fs.readSync(fd, hdr, 0, 4096, 0);
  if (hdr.subarray(0, 8).toString("latin1") !== "ANDROID!") die(`${file}: 头不是 ANDROID!`);
  const f = {
    file,
    size,
    fd,
    kernel_size: hdr.readUInt32LE(8),
    kernel_addr: hdr.readUInt32LE(12),
    ramdisk_size: hdr.readUInt32LE(16),
    ramdisk_addr: hdr.readUInt32LE(20),
    tags_addr: hdr.readUInt32LE(32),
    page: hdr.readUInt32LE(36),
    hdrver: hdr.readUInt32LE(40),
  };
  if (f.page !== 2048) die(`${file}: page_size=${f.page}，不是 2048，页对齐算法不能沿用`);
  if (f.hdrver !== 0) die(`${file}: header_version=${f.hdrver}，v0 之外的头我没有依据`);
  f.kernel_at = f.page;
  f.kernel_pages = Math.ceil(f.kernel_size / f.page);
  f.ramdisk_at = f.page + f.kernel_pages * f.page;
  f.ramdisk_pages = Math.ceil(f.ramdisk_size / f.page);
  const probe = (at, n) => {
    if (at + n > size) return Buffer.alloc(0);
    const b = Buffer.alloc(n);
    fs.readSync(fd, b, 0, n, at);
    return b;
  };
  if (f.kernel_size) {
    const p = probe(f.kernel_at, 8);
    if (!gz(p, 0)) die(`${file}: 内核不是 gzip (offset ${f.kernel_at})`);
    f.kernel_tail_avb = avb(probe(f.kernel_at + f.kernel_size, 4));
  }
  if (f.ramdisk_size) {
    const p = probe(f.ramdisk_at, 8);
    if (!gz(p, 0)) die(`${file}: initrd 不是 gzip (offset ${f.ramdisk_at})`);
    f.ramdisk_tail_avb = avb(probe(f.ramdisk_at + f.ramdisk_size, 4));
  }
  return f;
}

function patchHeader(host, kSize, rSize) {
  const hdr = Buffer.alloc(host.page);
  fs.readSync(host.fd, hdr, 0, host.page, 0);
  hdr.writeUInt32LE(kSize, 8);
  hdr.writeUInt32LE(rSize, 16);
  return hdr;
}

// Layout is exactly the host's: [header page][kernel pages][ramdisk pages], each side
// zero-padded to the page, so every offset the LK used before still points at a payload.
function emit(host, kSize, kSrc, kAt, rSize, rSrc, rAt, dest, label) {
  const pages = (n) => (n === 0 ? 0 : Math.ceil(n / host.page));
  const buf = Buffer.alloc((1 + pages(kSize) + pages(rSize)) * host.page);
  patchHeader(host, kSize, rSize).copy(buf, 0);
  const kAt2 = host.page;
  const rAt2 = host.page + pages(kSize) * host.page;
  for (let d = 0; d < kSize; ) d += fs.readSync(kSrc, buf, kAt2 + d, Math.min(1 << 20, kSize - d), kAt + d);
  for (let d = 0; d < rSize; ) d += fs.readSync(rSrc, buf, rAt2 + d, Math.min(1 << 20, rSize - d), rAt + d);
  fs.writeFileSync(dest, buf);
  const sha256 = crypto.createHash("sha256").update(buf).digest("hex");

  const got = readBoot(dest);
  if (got.kernel_size !== kSize || got.ramdisk_size !== rSize) die(`${label}: 回读头对不上`);
  if (kSize && !gz(probeAt(dest, got.kernel_at), 0)) die(`${label}: 内核位置没有 gzip 头`);
  if (rSize && !gz(probeAt(dest, got.ramdisk_at), 0)) die(`${label}: initrd 位置没有 gzip 头`);
  if (got.size !== buf.length) die(`${label}: 落盘长度和内存不一致`);
  ok(`${label} -> ${dest} bytes=${buf.length} sha256=${sha256}`);
  const { fd, ...rest } = got;
  fs.closeSync(fd);
  return { name: path.basename(dest), dest, label, bytes: buf.length, sha256, layout: rest };
}

function probeAt(file, at) {
  const f = fs.openSync(file, "r");
  const b = Buffer.alloc(8);
  fs.readSync(f, b, 0, 8, at);
  fs.closeSync(f);
  return b;
}

console.log(`== 读三个头 ==`);
const hk = readBoot(HOST_KERNEL);
const hr = readBoot(HOST_RAMDISK);
const tw = readBoot(TWRP);
if (hk.kernel_size === 0 || hk.ramdisk_size !== 0) die(`${HOST_KERNEL}: 不是"只装内核"的半边头`);
if (hr.ramdisk_size === 0 || hr.kernel_size !== 0) die(`${HOST_RAMDISK}: 不是"只装 initrd"的半边头`);
if (tw.kernel_size === 0 || tw.ramdisk_size === 0) die(`${TWRP}: 不是完整的 kernel+ramdisk 头`);
ok(`${HOST_KERNEL}: kernel=${hk.kernel_size} tags=0x${hk.tags_addr.toString(16)} ramdisk_size=0 AVB=${hk.kernel_tail_avb}`);
ok(`${HOST_RAMDISK}: ramdisk=${hr.ramdisk_size} AVB=${hr.ramdisk_tail_avb}`);
ok(`${TWRP}: kernel=${tw.kernel_size}@${tw.kernel_at} ramdisk=${tw.ramdisk_size}@${tw.ramdisk_at} AVB=${tw.ramdisk_tail_avb}`);
if (hk.kernel_tail_avb || hr.ramdisk_tail_avb) die("这两个分区带 AVB 尾，换了载荷哈希就对不上，得先想清楚");

fs.mkdirSync(OUT, { recursive: true });
console.log(`== 生成 ==`);
const a = emit(hk, tw.kernel_size, tw.fd, tw.kernel_at, 0, null, 0, path.join(OUT, NAME_KERNEL), "kernel 分区");
const b = emit(hr, 0, null, 0, tw.ramdisk_size, tw.fd, tw.ramdisk_at, path.join(OUT, NAME_RAMDISK), "ramdisk 分区");
fs.writeFileSync(
  path.join(OUT, "twrp_pair.json"),
  JSON.stringify({ source: { host_kernel: HOST_KERNEL, host_ramdisk: HOST_RAMDISK, twrp: TWRP, twrp_sha256: sha(TWRP) }, entries: [a, b] }, null, 2)
);
function sha(f) {
  const h = crypto.createHash("sha256");
  h.update(fs.readFileSync(f));
  return h.digest("hex");
}
console.log("ok 两个文件已生成，还没往手机写任何东西");