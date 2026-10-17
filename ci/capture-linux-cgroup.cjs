"use strict";
// Read-only kernel observations. Counter changes alone do not identify a killed actor.
const fs = require("fs"),
  path = require("path"),
  crypto = require("crypto");
const hash = (data) => crypto.createHash("sha256").update(data).digest("hex");
const flags =
  fs.constants.O_RDONLY | fs.constants.O_DIRECTORY | fs.constants.O_NOFOLLOW;
const principal = (st) => ({
  dev: st.dev.toString(),
  ino: st.ino.toString(),
  uid: st.uid.toString(),
  gid: st.gid.toString(),
  mode: st.mode.toString(),
});
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
function directory(p, owned) {
  if (!path.isAbsolute(p) || path.resolve(p) !== p)
    throw new Error("Noncanonical directory");
  for (let a = p; ; a = path.dirname(a)) {
    const st = fs.lstatSync(a, { bigint: true });
    if (!st.isDirectory() || st.isSymbolicLink())
      throw new Error("Directory ancestry alias");
    if (a === path.dirname(a)) break;
  }
  const st = fs.lstatSync(p, { bigint: true });
  if (owned && st.uid !== BigInt(process.geteuid()))
    throw new Error("Foreign evidence directory");
  return principal(st);
}
function readBounded(p, limit = 8192) {
  let fd;
  try {
    fd = fs.openSync(p, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
    const b = Buffer.alloc(limit + 1);
    let used = 0;
    while (used < b.length) {
      const n = fs.readSync(fd, b, used, b.length - used, null);
      if (!n) break;
      used += n;
    }
    return {
      text: b.subarray(0, Math.min(used, limit)).toString("utf8"),
      truncated: used > limit,
    };
  } catch (e) {
    return { error: e.code || String(e) };
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
  }
}
const decodeMount = (s) =>
  s.replace(/\\([0-7]{3})/g, (_, n) => String.fromCharCode(parseInt(n, 8)));
function observe() {
  const result = {
    utc: new Date().toISOString(),
    monotonicNs: process.hrtime.bigint().toString(),
    collectorPID: process.pid,
    collectorRSSBytes: String(process.memoryUsage().rss),
    sourceSHA256: hash(fs.readFileSync(__filename)),
    cgroupStart: readBounded("/proc/self/cgroup"),
    mountinfo: readBounded("/proc/self/mountinfo", 65536),
    limits: readBounded("/proc/self/limits"),
    meminfo: readBounded("/proc/meminfo"),
    pressure: {},
    groups: [],
    errors: [],
    attribution:
      "Kernel snapshots only; no OOM attribution or proof of exclusive job cgroup.",
  };
  for (const kind of ["memory", "cpu", "io"])
    result.pressure[kind] = readBounded("/proc/pressure/" + kind);
  try {
    if (
      !result.cgroupStart.text ||
      result.cgroupStart.truncated ||
      !result.mountinfo.text ||
      result.mountinfo.truncated
    )
      throw new Error("Incomplete kernel mapping");
    const unified = result.cgroupStart.text
      .trim()
      .split("\n")
      .filter((s) => s.startsWith("0::"));
    const mounts = result.mountinfo.text
      .trim()
      .split("\n")
      .map((line) => line.split(" - "))
      .filter((x) => x.length === 2 && x[1].split(" ")[0] === "cgroup2")
      .map((x) => x[0].split(" "))
      .filter((x) => decodeMount(x[4]) === "/sys/fs/cgroup");
    if (unified.length !== 1 || mounts.length !== 1)
      throw new Error("Unsupported unified cgroup mapping");
    const cg = unified[0].slice(3),
      mountRoot = decodeMount(mounts[0][3]),
      mountPoint = decodeMount(mounts[0][4]);
    if (!path.isAbsolute(cg) || path.resolve(cg) !== cg)
      throw new Error("Noncanonical kernel cgroup path");
    let relative;
    if (mountRoot === "/") relative = cg.slice(1);
    else if (cg === mountRoot) relative = "";
    else if (cg.startsWith(mountRoot + "/"))
      relative = cg.slice(mountRoot.length + 1);
    else
      throw new Error(
        "Namespace mapping unresolved; raw kernel fields retained",
      );
    let current = path.join(mountPoint, relative);
    result.mapping = {
      kernelPath: cg,
      mountRoot,
      mountPoint,
      observedLeaf: current,
    };
    const files = [
      "memory.events",
      "memory.events.local",
      "memory.max",
      "memory.high",
      "memory.current",
      "memory.peak",
      "memory.swap.max",
      "memory.swap.current",
      "memory.pressure",
      "cpu.max",
      "cpu.stat",
      "cpu.pressure",
      "pids.max",
      "pids.current",
      "pids.events",
      "cgroup.procs",
      "cgroup.events",
    ];
    for (let level = 0; level < 12; level++) {
      let fd;
      try {
        directory(current, false);
        fd = fs.openSync(current, flags);
        const st = fs.fstatSync(fd, { bigint: true });
        const group = { path: current, principal: principal(st), files: {} };
        for (const name of files)
          group.files[name] = readBounded("/proc/self/fd/" + fd + "/" + name);
        if (!same(group.principal, directory(current, false)))
          group.identityChanged = true;
        result.groups.push(group);
      } catch (e) {
        result.errors.push({ path: current, error: String(e) });
      } finally {
        if (fd !== undefined) fs.closeSync(fd);
      }
      if (current === mountPoint) break;
      const parent = path.dirname(current);
      if (parent === current || !parent.startsWith(mountPoint))
        throw new Error("Cgroup ancestor escape");
      current = parent;
    }
    if (
      result.groups.length &&
      result.groups[result.groups.length - 1].path !== mountPoint
    )
      result.errors.push({ error: "Ancestor limit12 reached" });
    const procs = result.groups[0]?.files["cgroup.procs"];
    result.collectorMembershipObserved = Boolean(
      procs?.text &&
        !procs.truncated &&
        procs.text.trim().split(/\s+/).includes(String(process.pid)),
    );
  } catch (e) {
    result.errors.push({ error: String(e) });
  }
  result.cgroupEnd = readBounded("/proc/self/cgroup");
  result.mappingStable =
    JSON.stringify(result.cgroupStart) === JSON.stringify(result.cgroupEnd);
  return result;
}
function deltas(before, after) {
  if (
    !before.mappingStable ||
    !after.mappingStable ||
    !before.collectorMembershipObserved ||
    !after.collectorMembershipObserved
  )
    return { comparable: false, reason: "Unproven stable own-group mapping" };
  const rows = [];
  for (const current of after.groups) {
    const prior = before.groups.find(
      (g) => g.path === current.path && same(g.principal, current.principal),
    );
    if (!prior || prior.identityChanged || current.identityChanged) {
      rows.push({ path: current.path, comparable: false });
      continue;
    }
    const raw = [prior.files["memory.events"], current.files["memory.events"]];
    if (raw.some((x) => !x.text || x.truncated || x.error)) {
      rows.push({ path: current.path, comparable: false });
      continue;
    }
    const parse = (s) =>
      Object.fromEntries(
        s
          .trim()
          .split("\n")
          .map((line) => {
            const x = line.trim().split(/\s+/);
            if (x.length !== 2 || !/^\d+$/.test(x[1]))
              throw new Error("Invalid event counter");
            return x;
          }),
      );
    try {
      const a = parse(raw[0].text),
        b = parse(raw[1].text),
        difference = {};
      for (const key of Object.keys(a)) {
        if (!(key in b) || BigInt(b[key]) < BigInt(a[key]))
          throw new Error("Counter reset");
        difference[key] = (BigInt(b[key]) - BigInt(a[key])).toString();
      }
      rows.push({
        path: current.path,
        comparable: true,
        memoryEventCounterDifferences: difference,
      });
    } catch (e) {
      rows.push({ path: current.path, comparable: false, error: String(e) });
    }
  }
  return {
    comparable: true,
    scope:
      "Same observed directory principals; not continuous held identity or signal attribution.",
    rows,
  };
}
module.exports = async ({
  core,
  phase,
  temporary,
  receipt,
  directoryIdentity,
  beforeSHA,
  priorJobStatus,
}) => {
  if (process.platform !== "linux" || !["before", "after"].includes(phase))
    throw new Error("Linux before/after only");
  const descriptors = [];
  let tempFD, dirFD, real, primary;
  try {
    const tempIdentity = directory(temporary, true);
    tempFD = fs.openSync(temporary, flags);
    descriptors.push(tempFD);
    if (!same(tempIdentity, principal(fs.fstatSync(tempFD, { bigint: true }))))
      throw new Error("Temporary authority drift");
    if (phase === "before") {
      const allocated = fs.mkdtempSync(
        "/proc/self/fd/" + tempFD + "/acp-linux-cgroup-",
      );
      real = path.join(temporary, path.basename(allocated));
    } else {
      if (
        path.dirname(receipt) !== temporary ||
        !path.basename(receipt).startsWith("acp-linux-cgroup-")
      )
        throw new Error("Foreign receipt path");
      real = receipt;
    }
    dirFD = fs.openSync(
      "/proc/self/fd/" + tempFD + "/" + path.basename(real),
      flags,
    );
    descriptors.push(dirFD);
    const identity = principal(fs.fstatSync(dirFD, { bigint: true }));
    if (
      identity.uid !== String(process.geteuid()) ||
      (BigInt(identity.mode) & 0o077n) !== 0n
    )
      throw new Error("Nonprivate receipt");
    if (phase === "after" && !same(identity, JSON.parse(directoryIdentity)))
      throw new Error("Receipt directory replacement");
    const observation = observe();
    observation.priorJobStatus = priorJobStatus;
    if (phase === "after") {
      const prior = readBounded(
        "/proc/self/fd/" + dirFD + "/before.json",
        4 * 1024 ** 2,
      );
      if (prior.error || prior.truncated)
        throw new Error("Before receipt unreadable");
      const raw = Buffer.from(prior.text);
      if (hash(raw) !== beforeSHA) throw new Error("Before receipt changed");
      const before = JSON.parse(raw);
      observation.counterComparison = deltas(before, observation);
    }
    const data = Buffer.from(JSON.stringify(observation, null, 2) + "\n");
    if (data.length > 4 * 1024 ** 2) throw new Error("Receipt4MiB bound");
    const out = fs.openSync(
      "/proc/self/fd/" + dirFD + "/" + phase + ".json",
      fs.constants.O_WRONLY |
        fs.constants.O_CREAT |
        fs.constants.O_EXCL |
        fs.constants.O_NOFOLLOW,
      0o600,
    );
    descriptors.push(out);
    let offset = 0;
    while (offset < data.length) {
      const n = fs.writeSync(out, data, offset, data.length - offset);
      if (n <= 0) throw new Error("Short evidence write");
      offset += n;
    }
    fs.fsyncSync(out);
    fs.fsyncSync(dirFD);
    if (
      !same(identity, directory(real, true)) ||
      !same(tempIdentity, directory(temporary, true))
    )
      throw new Error("Evidence lexical authority drift");
    core.setOutput("receipt_path", real);
    core.setOutput("directory_identity", JSON.stringify(identity));
    core.setOutput("snapshot_sha256", hash(data));
    core.info(
      "Captured bounded read-only Linux cgroup observations; no signal-cause verdict.",
    );
  } catch (e) {
    primary = e;
    throw e;
  } finally {
    let first;
    for (const fd of descriptors.reverse()) {
      try {
        fs.closeSync(fd);
      } catch (e) {
        if (!first) first = e;
      }
    }
    if (first && !primary) throw first;
  }
};
