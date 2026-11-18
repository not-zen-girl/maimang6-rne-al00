// Build rb186/ - the EMUI 5.1 C00B186 payloads with the 4 KB package header removed where the
// evidence says a header exists, so each output file starts exactly like the phone's own partition.
//
// Evidence per partition, in priority order:
//   1. heads_live/<name>.bin - dumped off this phone while it still ran B186. If the source matches
//      at 4096 and not at 0, the source is wrapped, and the output is checked against the same dump.
//   2. format magics at 0 / 4096: android sparse must stay at 0 (a stripped sparse file is broken).
//   3. the package header signature (see wrappedHeader), then a same-format sibling in the package.
// Anything left over is reported and blocks the run; it must not be flashed until explained.
//
// Large images are streamed, so the output hash is computed while writing.
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { pipeline } = require('stream/promises');

const SRC = ['rollback_b186', 'stock_b186'];
const OUT = 'rb186';
const HEADS = 'heads_live';
const BLOCK = 4096;

function readPrefix(file, len) {
  const fd = fs.openSync(file, 'r');
  try {
    const want = Math.min(len, fs.fstatSync(fd).size);
    const buf = Buffer.alloc(want);
    fs.readSync(fd, buf, 0, want, 0);
    return buf;
  } finally {
    fs.closeSync(fd);
  }
}

function magicAt(buf, off) {
  const s = buf.subarray(off);
  if (s.length > 4 && s.readUInt32LE(0) === 0xed26ff3a) return 'sparse';
  if (s.length > 8 && s.subarray(0, 8).toString('latin1') === 'ANDROID!') return 'androidboot';
  if (s.length > 1026 && s.readUInt16BE(1024) === 0xef53) return 'ext4';
  if (s.length > 520 && s.subarray(512, 520).toString('latin1') === 'EFI PART') return 'gpt';
  return null;
}

// Files from these packages that carry a header start with 8 zero bytes then two u32 == 1; the rest
// of the 4 KB block may hold header metadata (non-zero from 128). Proven wrapped against this phone's
// own bytes: boot/dts/fastboot/teeos/trustfirmware/sensorhub/fw_hifi/fw_lpm3/modem_fw/recovery2.
// xloader is wrapped too - its payload at 4096 is Thumb-2 code (70 b5 00 f0 ...) behind the zeros.
// modemnvm_update is not wrapped: it opens with its own "nv" table, so it stays byte-for-byte.
function wrappedHeader(buf) {
  if (buf.length < BLOCK) return false;
  for (let i = 0; i < 8; i++) if (buf[i] !== 0) return false;
  return buf.readUInt32LE(8) === 1 && buf.readUInt32LE(12) === 1;
}

function readHeads() {
  const map = new Map();
  if (!fs.existsSync(HEADS)) return map;
  for (const f of fs.readdirSync(HEADS)) {
    if (f.endsWith('.bin')) map.set(f.replace(/\.bin$/, ''), path.join(HEADS, f));
  }
  return map;
}

function matchAt(ref, off, head) {
  const n = Math.min(head.length, ref.length - off);
  if (n <= 0) return { ok: 0, n: 0 };
  let ok = 0;
  for (let i = 0; i < n; i++) if (ref[off + i] === head[i]) ok++;
  return { ok, n };
}

function findSource(name) {
  for (const dir of SRC) {
    for (const cand of [`${name}.img`, `${name}_pure.img`]) {
      const p = path.join(dir, cand);
      if (fs.existsSync(p)) return p;
    }
  }
  return null;
}

async function copyAndHash(src, off, dest) {
  const hash = crypto.createHash('sha256');
  const size = fs.statSync(src).size - off;
  const out = fs.createWriteStream(dest);
  const count = () => {
    hash.update(Buffer.alloc(0));
  };
  await pipeline(
    fs.createReadStream(src, { start: off }),
    (source) => source.on('data', (c) => hash.update(c)),
    out,
  );
  count();
  return { size, sha256: hash.digest('hex') };
}

async function main() {
  const heads = readHeads();
  const names = process.argv.slice(2).filter((a) => !a.startsWith('-'));
  if (!names.length) {
    console.error('usage: node tools/prepare_b186_set.js <partition> [...partitions]');
    process.exit(2);
  }
  fs.mkdirSync(OUT, { recursive: true });

  const rows = [];
  for (const name of names) {
    const src = findSource(name);
    if (!src) {
      rows.push({ name, verdict: 'MISSING', note: 'no local source' });
      continue;
    }
    const headFile = heads.get(name) || null;
    const head = headFile ? fs.readFileSync(headFile) : null;
    const ref = readPrefix(src, BLOCK + (head ? head.length : 2048));
    const totalSize = fs.statSync(src).size;

    let off = null;
    let verdict = 'assumed';
    let note = '';

    if (head) {
      const a = matchAt(ref, 0, head);
      const b = matchAt(ref, BLOCK, head);
      const full = (r) => r.n > 0 && r.ok === r.n;
      if (full(b) && !full(a)) {
        off = BLOCK;
        verdict = 'PROVEN-strip';
        note = `${b.n}/${b.n} match this phone at 4096, ${a.ok}/${a.n} at 0`;
      } else if (full(a) && !full(b)) {
        off = 0;
        verdict = 'PROVEN-asis';
        note = `${a.n}/${a.n} match this phone at 0`;
      } else {
        verdict = 'CONFLICT';
        note = `0:${a.ok}/${a.n} 4096:${b.ok}/${b.n}`;
      }
    } else {
      const m0 = magicAt(ref, 0);
      const m1 = magicAt(ref, BLOCK);
      if (m0 === 'sparse') {
        off = 0;
        verdict = 'sparse-asis';
        note = 'android sparse at 0 - stripping would break it';
      } else if (name === 'recovery' && heads.has('recovery2')) {
        off = BLOCK;
        verdict = 'by-twin';
        note = 'same package format as recovery2 (proven wrapped)';
      } else if (m1 && !m0) {
        off = BLOCK;
        verdict = 'by-magic';
        note = `${m1} superblock found only at 4096`;
      } else if (m0 && !m1) {
        off = 0;
        verdict = 'by-magic';
        note = `${m0} superblock found only at 0`;
      } else if (wrappedHeader(ref)) {
        off = BLOCK;
        verdict = 'by-header';
        note = 'package header signature, zeros to 4096';
      } else {
        note = `no phone head, magic0=${m0 || 'none'} magic4096=${m1 || 'none'} wrapped=${wrappedHeader(ref)}`;
      }
    }

    if (off === null) {
      rows.push({ name, verdict, note, src, size: totalSize });
      continue;
    }

    const dest = path.join(OUT, `${name}.img`);
    const r = await copyAndHash(src, off, dest);

    let recheck = '';
    if (head) {
      const c = matchAt(readPrefix(dest, head.length), 0, head);
      recheck = c.ok === c.n ? `${c.n}/${c.n} OK` : `${c.ok}/${c.n} MISMATCH`;
      if (c.ok !== c.n) verdict = 'BAD-OUTPUT';
    }
    rows.push({ name, verdict, off, note, src, size: r.size, sha256: r.sha256, recheck });
    console.log(`${String(name).padEnd(16)} ${String(verdict).padEnd(13)} off=${String(off).padEnd(5)} ${String(r.size).padStart(11)}  ${r.sha256.slice(0, 16)}…  ${recheck || ''}`);
  }

  const allowed = ['PROVEN-strip', 'PROVEN-asis', 'sparse-asis', 'by-magic', 'by-twin', 'by-header'];
  const bad = rows.filter((r) => !allowed.includes(r.verdict));
  console.log(`\nprepared ${rows.filter((r) => r.sha256).length} / ${rows.length} -> ${OUT}/`);
  for (const r of bad) console.log(`  BLOCKED ${r.name}: ${r.verdict} ${r.note}`);
  if (bad.length) process.exit(1);

  const list = path.join(OUT, 'plan.json');
  fs.writeFileSync(list, JSON.stringify(rows.map((r) => ({ name: r.name, file: `rb186/${r.name}.img`, size: r.size, sha256: r.sha256, evidence: r.verdict })), null, 1));
  console.log(`manifest -> ${list}`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});