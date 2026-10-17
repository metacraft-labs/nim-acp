"use strict";

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { execFileSync } = require("child_process");

function identity(info) {
  return ["dev", "ino", "mode", "uid", "gid", "size", "mtimeNs", "ctimeNs"]
    .map((key) => info[key].toString())
    .join(":");
}

function principal(image) {
  if (!Number.isInteger(fs.constants.O_NOFOLLOW)) {
    throw new Error("No no-follow image authority");
  }
  const lexical = fs.lstatSync(image, { bigint: true });
  if (!lexical.isFile()) throw new Error("Nonregular creator image");
  const fd = fs.openSync(
    image,
    fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW,
  );
  try {
    const before = fs.fstatSync(fd, { bigint: true });
    if (identity(before) !== identity(lexical)) {
      throw new Error("Creator image replaced before open");
    }
    const sha = crypto
      .createHash("sha256")
      .update(fs.readFileSync(fd))
      .digest("hex");
    const after = fs.fstatSync(fd, { bigint: true });
    if (
      identity(before) !== identity(after) ||
      identity(fs.lstatSync(image, { bigint: true })) !== identity(lexical)
    ) {
      throw new Error("Creator image changed while hashing");
    }
    return {
      sha,
      mode: Number(before.mode & 0o7777n),
      dev: before.dev.toString(),
      ino: before.ino.toString(),
    };
  } finally {
    fs.closeSync(fd);
  }
}

module.exports = async function bindCreator({ core, io, root }) {
  const physicalRoot = fs.realpathSync(root);
  const image = fs.realpathSync(await io.which("git", true));
  const before = principal(image);
  const run = (args) =>
    execFileSync(image, args, {
      cwd: physicalRoot,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    }).trim();
  const version = run(["--version"]);
  const execPath = run(["--exec-path"]);
  if (
    !version ||
    !execPath ||
    JSON.stringify(principal(image)) !== JSON.stringify(before)
  ) {
    throw new Error("Creator image changed during binding");
  }
  // Authenticate creation modes before setup actions can change the process mask.
  // The factory uses the bound creator and exact current mask; no observed hook
  // mode is promoted into an admission rule.
  const creationUmask = process.umask();
  const hooks = path.join(physicalRoot, ".git", "hooks");
  const inventory = (directory) => {
    if (!fs.lstatSync(directory).isDirectory())
      throw new Error("Non-directory hooks");
    const rows = {};
    for (const name of fs.readdirSync(directory).sort()) {
      if (!name.endsWith(".sample")) throw new Error("Non-sample initial hook");
      rows[name] = principal(path.join(directory, name));
    }
    if (!Object.keys(rows).length)
      throw new Error("Empty initial hook inventory");
    return rows;
  };
  const original = inventory(hooks);
  const factory = fs.mkdtempSync(path.join(physicalRoot, ".creator-factory-"));
  try {
    execFileSync(image, ["init", factory], {
      cwd: physicalRoot,
      stdio: ["ignore", "pipe", "pipe"],
    });
    const generated = inventory(path.join(factory, ".git", "hooks"));
    if (
      JSON.stringify(Object.keys(original)) !==
      JSON.stringify(Object.keys(generated))
    ) {
      throw new Error("Checkout-time creator factory inventory differs");
    }
    for (const name of Object.keys(original)) {
      if (
        original[name].sha !== generated[name].sha ||
        original[name].mode !== generated[name].mode
      ) {
        throw new Error("Checkout-time creator factory body or mode differs");
      }
    }
    if (
      JSON.stringify(inventory(hooks)) !== JSON.stringify(original) ||
      process.umask() !== creationUmask
    ) {
      throw new Error("Checkout-time hooks or creation mask changed");
    }
  } finally {
    fs.rmSync(factory, { recursive: true });
  }
  const directory = fs.mkdtempSync(
    path.join(process.env.RUNNER_TEMP, "nim-acp-checkout-git-"),
  );
  if ((fs.lstatSync(directory, { bigint: true }).mode & 0o777n) !== 0o700n) {
    throw new Error("Private creator binding directory mode differs");
  }
  const destination = path.join(directory, "creator.json");
  const receipt = {
    schema: "nim-acp-checkout-creator.v2",
    statEncoding: "decimal-v1",
    root: physicalRoot,
    creator: image,
    principal: before,
    inheritedExecPath: process.env.GIT_EXEC_PATH ?? null,
    creationUmask,
    version,
    execPath,
  };
  fs.writeFileSync(destination, JSON.stringify(receipt, null, 2) + "\n", {
    flag: "wx",
    mode: 0o600,
  });
  core.setOutput("binding", destination);
};
