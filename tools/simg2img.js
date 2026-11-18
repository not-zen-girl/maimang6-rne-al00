// Un-sparse an Android sparse image (magic 0xED26FF3A) into a raw image.
// Huawei ships sparse 1.0 here, where 0xCAC1 carries data and 0xCAC3 is a hole - the opposite of
// modern AOSP (RAW=0xCAC3, DONT_CARE=0xCAC4). Chunk kinds are therefore recognised by their size
// arithmetic, and the result is checked against both invariants instead of trusting type constants.
// node tools/simg2img.js <in.img> <out.img>
const fs = require("fs");

const SPARSE_MAGIC = 0xed26ff3a;

function isSparse(fd) {
  const b = Buffer.alloc(4);
  fs.readSync(fd, b, 0, 4, 0);
  return b.readUInt32LE(0) === SPARSE_MAGIC;
}

function unsparse(src, dst) {
  const fd = fs.openSync(src, "r");
  const fileSize = fs.fstatSync(fd).size;
  if (!isSparse(fd)) {
    fs.closeSync(fd);
    fs.copyFileSync(src, dst);
    return { sparse: false, out: fs.statSync(dst).size };
  }
  const h = Buffer.alloc(28);
  fs.readSync(fd, h, 0, 28, 0);
  const fileHdr = h.readUInt16LE(8);
  const chunkHdr = h.readUInt16LE(10);
  const blk = h.readUInt32LE(12);
  const totalBlocks = h.readUInt32LE(16);
  const rawSize = Number(totalBlocks) * Number(blk);
  if (!fileHdr || !chunkHdr || !blk || !totalBlocks)
    throw new Error(`${src}: sparse header fields look wrong (fileHdr=${fileHdr} chunkHdr=${chunkHdr} blk=${blk} blocks=${totalBlocks})`);

  const out = fs.openSync(dst, "w");
  fs.ftruncateSync(out, rawSize); // trailing holes must still exist
  let pos = fileHdr, outPos = 0, sumBlocks = 0, sumPayload = 0, n = 0, data = 0, holes = 0, fills = 0;
  while (pos + chunkHdr <= fileSize) {
    const c = Buffer.alloc(chunkHdr);
    fs.readSync(fd, c, 0, chunkHdr, pos);
    const type = c.readUInt32LE(0);
    const blocks = c.readUInt32LE(4);
    const dataSize = c.readUInt32LE(8); // includes the chunk header
    const body = dataSize - chunkHdr;
    const span = Number(blocks) * Number(blk);
    if (dataSize < chunkHdr || pos + dataSize > fileSize)
      throw new Error(`${src}: chunk ${n} at ${pos} claims size ${dataSize} (file ${fileSize})`);
    if (body === span) {
      // data present: payload fills exactly the blocks it declares
      const buf = Buffer.alloc(body);
      fs.readSync(fd, buf, 0, body, pos + chunkHdr);
      fs.writeSync(out, buf, 0, body, outPos);
      outPos += span;
      data++;
    } else if (dataSize === chunkHdr) {
      outPos += span; // hole: keep the pre-zeroed bytes from ftruncate
      holes++;
    } else if (body > 0 && body <= 8 && blocks > 0 && body === 4) {
      const pat = Buffer.alloc(4);
      fs.readSync(fd, pat, 0, 4, pos + chunkHdr);
      for (let o = 0; o < span; o += 4) fs.writeSync(out, pat, 0, 4, outPos + o);
      outPos += span;
      fills++;
    } else if (body > 0 && body <= 8) {
      // crc / metadata trailer, no image content
    } else {
      fs.closeSync(fd); fs.closeSync(out);
      throw new Error(`${src}: chunk ${n} type 0x${type.toString(16)} has an unrecognised shape (blocks=${blocks} body=${body} span=${span})`);
    }
    sumBlocks += blocks;
    sumPayload += body;
    pos += dataSize;
    n++;
  }
  fs.closeSync(fd);
  fs.closeSync(out);

  const errs = [];
  if (sumBlocks !== totalBlocks) errs.push(`block count ${sumBlocks} != header ${totalBlocks}`);
  if (sumPayload !== fileSize - fileHdr - n * chunkHdr)
    errs.push(`payload sum ${sumPayload} != file bytes ${fileSize - fileHdr - n * chunkHdr}`);
  if (outPos !== rawSize) errs.push(`unsparsed length ${outPos} != ${rawSize}`);
  if (errs.length) throw new Error(`${src}: sparse walk failed its own invariants - ${errs.join("; ")}`);
  return { sparse: true, rawSize, chunks: n, data, holes, fills, blk, fileSize };
}

const [src, dst] = process.argv.slice(2);
if (!src || !dst) {
  console.error("usage: node tools/simg2img.js <in.img> <out.img>");
  process.exit(2);
}
const r = unsparse(src, dst);
if (!r.sparse) {
  console.log(`${src} -> not sparse, copied ${r.out} B`);
} else {
  console.log(
    `${src} -> sparse v1 invariants OK (${r.chunks} chunks: ${r.data} data, ${r.holes} holes, ${r.fills} fill) ` +
    `${(r.fileSize / 1048576).toFixed(0)} MB on disk -> ${(r.rawSize / 1048576).toFixed(0)} MB raw`,
  );
}