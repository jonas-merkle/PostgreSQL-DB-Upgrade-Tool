// SPDX-License-Identifier: LGPL-3.0-only
const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const { quote, makeCommand } = require("../docs/generator.js");
const defaults = {
  mode: "upgrade",
  source: "/srv/docker/data/db",
  sourceMajor: "18",
  targetMajor: "19",
  role: "pgadmin",
  database: "appdb",
  passwordFile: "",
  workDir: "",
  identity: "",
  recipientFile: "",
  timeout: "300",
  encrypt: false,
  requireEncrypted: false,
};
const tricky = "/srv/path with spaces/it's $(echo unsafe);";
assert.equal(
  execFileSync("bash", ["-c", `printf '%s' ${quote(tricky)}`], { encoding: "utf8" }),
  tricky,
);
assert.match(makeCommand(defaults), /--target-major '19'/);
assert.match(makeCommand({ ...defaults, mode: "backup", targetMajor: "" }), /--backup-only/);
assert.doesNotMatch(makeCommand({ ...defaults, mode: "backup" }), /--target-major/);
assert.throws(() => makeCommand({ ...defaults, targetMajor: "18" }));
assert.throws(() => makeCommand({ ...defaults, encrypt: true }));
assert.match(
  makeCommand({ ...defaults, mode: "backup", encrypt: true, recipientFile: "/keys/recipients" }),
  /--encryption-key-file/,
);
assert.match(
  makeCommand({ ...defaults, encrypt: true, identity: "/keys/private" }),
  /--identity-file/,
);
assert.doesNotMatch(makeCommand({ ...defaults, identity: "/keys/private" }), /identity/);
assert.doesNotMatch(makeCommand(defaults), /--allow-parent-mounts/);
assert.match(makeCommand({ ...defaults, allowParentMounts: true }), /--allow-parent-mounts/);
assert.match(
  makeCommand({ ...defaults, mode: "backup", allowParentMounts: true }),
  /--allow-parent-mounts/,
);
const cmd = makeCommand({ ...defaults, source: tricky });
// Substitute an argument-printing function for the actual script; no Docker work.
const shell = cmd.replace(/^\.\/migrate\.sh/, "capture");
const args = JSON.parse(
  execFileSync(
    "bash",
    [
      "-c",
      `capture() { node -e 'console.log(JSON.stringify(process.argv.slice(1)))' -- "$@"; };\n${shell}`,
    ],
    { encoding: "utf8" },
  ),
);
assert.equal(args[1], tricky);
console.log("Command generator tests passed");
