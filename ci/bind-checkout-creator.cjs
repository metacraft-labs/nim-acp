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
  const directory = fs.mkdtempSync(
    path.join(process.env.RUNNER_TEMP, "nim-acp-checkout-git-"),
  );
  if ((fs.lstatSync(directory, { bigint: true }).mode & 0o777n) !== 0o700n) {
    throw new Error("Private creator binding directory mode differs");
  }
  const destination = path.join(directory, "creator.json");
  const receipt = {
    schema: "nim-acp-checkout-creator.v1",
    statEncoding: "decimal-v1",
    root: physicalRoot,
    creator: image,
    principal: before,
    inheritedExecPath: process.env.GIT_EXEC_PATH ?? null,
    version,
    execPath,
  };
  fs.writeFileSync(destination, JSON.stringify(receipt, null, 2) + "\n", {
    flag: "wx",
    mode: 0o600,
  });
  core.setOutput("binding", destination);
};
