const fs = require("fs");
const zlib = require("zlib");
const u32 = (b, o) => b.readUInt32LE(o);
const al = (n, p) => Math.ceil(n / p) * p;

const b = fs.readFileSync("stock_b186/recovery.img");
const base = 0x1000, page = u32(b, base + 36) || 2048, ksz = u32(b, base + 8), rsz = u32(b, base + 16);
const roff = base + page + al(ksz, page), rraw = b.subarray(roff, roff + al(rsz, page));
const r = (rraw[0] === 0x1f && rraw[1] === 0x8b) ? zlib.gunzipSync(rraw, { finishFlush: 4 }) : rraw;
const t = r.toString("latin1");

const uniq = (re, n = 30) => {
  const m = t.match(re);
  return m ? "     " + [...new Set(m)].slice(0, n).join("\n     ") : "     (none)";
};

console.log("=== 分区/目录路径 ===\n" + uniq(/\/(?:cache|data|sdcard|mnt|dload|persist|version|oem)\/[A-Za-z0-9_.\/%:-]{3,46}/g, 45));
console.log("=== 文件名(zip/tar/dat) ===\n" + uniq(/[A-Za-z0-9_.-]{3,32}\.(?:zip|dat|tar|app|img)\b/g, 30));
console.log("=== 主机/URL ===\n" + uniq(/(?:https?:\/\/|hicloud|dbankcdn|hiservice|hwcloud|fota|drcn|hiram)[A-Za-z0-9_.\/:%-]{0,44}/gi, 30));
console.log("=== 下载/升级动作词 ===\n" + uniq(/\b(?:download_[a-z_]+|Download[A-Za-z]{2,14}|upgrade_[a-z_]+|Update[A-Za-z]{2,14}|sdupgrade|sdcard_update|online_update|erecovery[a-z_]*|verify_[a-z_]+)\b/g, 40));