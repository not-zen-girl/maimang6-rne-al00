// adb UI driver: dump uiautomator hierarchy, tap by visible text/desc/id
// node tools/utap.js list [filter]        list visible nodes
// node tools/utap.js tap "<query>" [idx]  tap node whose text/desc/id contains query
// node tools/utap.js wait "<query>" [sec] poll until node appears
// node tools/utap.js key <KEYCODE>        send keyevent
// node tools/utap.js xy <x> <y>           raw tap
// node tools/utap.js shot <out.png>       screenshot
const { spawnSync } = require("child_process");
const fs = require("fs");

const ADB = "C:/Users/64563/Desktop/maimang6/platform-tools/adb.exe";
const SER = "68U5T18328012368";

function adb(args, bin) {
  const r = spawnSync(ADB, ["-s", SER, ...args], {
    encoding: bin ? "buffer" : "utf8",
    maxBuffer: 1 << 28,
  });
  if (r.error) throw r.error;
  if (bin) return r.stdout;
  return String(r.stdout || "").replace(/\r/g, "");
}

function nodes() {
  adb(["shell", "uiautomator", "dump", "/data/local/tmp/ui.xml"]);
  const xml = adb(["exec-out", "cat", "/data/local/tmp/ui.xml"], true)
    .toString("utf8")
    .replace(/\r/g, "");
  const out = [];
  for (const raw of xml.match(/<node[^>]*?\/>/g) || []) {
    const attr = (n) => {
      const m = raw.match(new RegExp(n + '="([^"]*)"'));
      return m ? m[1] : "";
    };
    const b = raw.match(/bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"/);
    if (!b) continue;
    const [, x1, y1, x2, y2] = b.map(Number);
    out.push({
      text: attr("text").replace(/&#10;/g, " "),
      desc: attr("content-desc").replace(/&#10;/g, " "),
      id: attr("resource-id"),
      cls: attr("class"),
      clickable: attr("clickable") === "true",
      x: (x1 + x2) >> 1,
      y: (y1 + y2) >> 1,
      w: x2 - x1,
      h: y2 - y1,
    });
  }
  return out;
}

function hits(q) {
  return nodes().filter(
    (n) =>
      n.text.toLowerCase().includes(q.toLowerCase()) ||
      n.desc.toLowerCase().includes(q.toLowerCase()) ||
      n.id.toLowerCase().includes(q.toLowerCase()),
  );
}

const act = (x, y) => {
  adb(["shell", "input", "tap", String(x), String(y)]);
  return `点击 (${x},${y})`;
};

const [, , cmd, arg, arg2] = process.argv;
if (cmd === "list") {
  const f = (arg || "").toLowerCase();
  for (const n of nodes()) {
    if (!n.text && !n.desc && !n.id) continue;
    if (f && !(n.text + n.desc + n.id).toLowerCase().includes(f)) continue;
    console.log(
      `${n.clickable ? "*" : " "}[${n.x},${n.y}] ${n.cls.replace(/.+\./, "")} | ${n.text || n.desc || n.id}`,
    );
  }
} else if (cmd === "tap") {
  const list = hits(arg);
  if (!list.length) {
    console.log("未找到匹配节点: " + arg);
    process.exitCode = 1;
  } else {
    const i = arg2 === undefined ? 0 : Number(arg2);
    const cand = list.filter((n) => n.clickable);
    const n = (cand.length ? cand : list)[i] || list[0];
    console.log(`匹配 ${list.length} 个 → ${n.text || n.desc || n.id} @(${n.x},${n.y})`);
    console.log(act(n.x, n.y));
  }
} else if (cmd === "wait") {
  const until = Date.now() + (Number(arg2 || 20) * 1000);
  for (;;) {
    const list = hits(arg);
    if (list.length) {
      console.log(`出现: ${list[0].text || list[0].desc || list[0].id}`);
      return;
    }
    if (Date.now() > until) {
      console.log("超时未出现: " + arg);
      process.exitCode = 1;
      return;
    }
    spawnSync(process.execPath, ["-e", 'require("timers").setTimeout(()=>{},300)']);
  }
} else if (cmd === "key") {
  adb(["shell", "input", "keyevent", String(arg)]);
  console.log("已发送按键 " + arg);
} else if (cmd === "xy") {
  console.log(act(Number(arg), Number(arg2)));
} else if (cmd === "shot") {
  const buf = adb(["exec-out", "screencap", "-p"], true);
  fs.writeFileSync(arg, buf);
  console.log("截图: " + arg + " " + buf.length + " B");
} else {
  console.log("用法: list|tap|wait|key|xy|shot");
}