/* SPDX-License-Identifier: LGPL-3.0-only */
"use strict";
// Build a shell command, never execute it. Single-quote every user value and
// escape embedded quotes so spaces, metacharacters and paths remain arguments.
function quote(value) {
  return "'" + String(value).replace(/'/g, "'\\''") + "'";
}
function makeCommand(o) {
  const backup = o.mode === "backup";
  const major = (v) => /^[1-9][0-9]{1,2}$/.test(v) && Number(v) >= 18;
  const path = (v) => v.startsWith("/") && !/[\r\n\0]/.test(v);
  if (!path(o.source) || o.source === "/")
    throw Error("Use an absolute database root path, not /.");
  if (!major(o.sourceMajor))
    throw Error("Source must be a PostgreSQL major version of 18 or newer.");
  if (!backup && (!major(o.targetMajor) || Number(o.targetMajor) <= Number(o.sourceMajor)))
    throw Error("Target must be greater than source.");
  if (!o.role || o.role.startsWith("-") || /[\r\n\0]/.test(o.role))
    throw Error("Enter a valid superuser name.");
  if (!/^[A-Za-z_][A-Za-z0-9_.-]*$/.test(o.database)) throw Error("Use a simple database name.");
  if (!/^[1-9][0-9]{0,4}$/.test(o.timeout)) throw Error("Timeout must be 1–99999 seconds.");
  for (const key of [
    "passwordFile",
    "workDir",
    ...(o.encrypt ? ["identity", "recipientFile"] : []),
  ]) {
    if (o[key] && !path(o[key]))
      throw Error("Optional file and directory inputs must be absolute paths.");
  }
  if (o.encrypt && !o.identity && (!backup || !o.recipientFile))
    throw Error(
      "Encrypted migration requires an identity file; backup-only may use a public recipient file.",
    );
  const args = [`--source ${quote(o.source)}`, `--source-major ${quote(o.sourceMajor)}`];
  if (backup) args.push("--backup-only");
  else args.push(`--target-major ${quote(o.targetMajor)}`);
  args.push(`--user ${quote(o.role)}`, `--database ${quote(o.database)}`);
  if (o.passwordFile) args.push(`--password-file ${quote(o.passwordFile)}`);
  if (o.workDir) args.push(`--work-dir ${quote(o.workDir)}`);
  if (o.requireEncrypted) args.push("--require-encrypted-storage");
  if (o.encrypt) {
    args.push("--encrypt-backup");
    if (o.identity) args.push(`--identity-file ${quote(o.identity)}`);
    if (o.recipientFile) args.push(`--encryption-key-file ${quote(o.recipientFile)}`);
  }
  args.push(`--timeout ${quote(o.timeout)}`);
  return ["./migrate.sh", ...args.map((a) => "  " + a)].join(" \\\n");
}
// Export pure functions for Node tests; the browser path needs no dependencies.
if (typeof module !== "undefined") module.exports = { quote, makeCommand };
if (typeof document !== "undefined") {
  const el = (id) => document.getElementById(id);
  const form = el("generator"),
    status = el("status"),
    output = el("output"),
    copy = el("copy");
  function update() {
    el("targetMajor").disabled = el("mode").value === "backup";
    el("ageOptions").hidden = !el("encrypt").checked;
    // Clear obsolete results when inputs change; never copy a stale command.
    output.value = "";
    copy.disabled = true;
    status.textContent = "";
  }
  form.addEventListener("input", update);
  form.addEventListener("change", update);
  form.addEventListener("submit", (event) => {
    event.preventDefault();
    try {
      const keys = [
        "mode",
        "source",
        "sourceMajor",
        "targetMajor",
        "role",
        "database",
        "passwordFile",
        "workDir",
        "identity",
        "recipientFile",
        "timeout",
      ];
      const o = Object.fromEntries(keys.map((key) => [key, el(key).value]));
      o.encrypt = el("encrypt").checked;
      o.requireEncrypted = el("requireEncrypted").checked;
      output.value = makeCommand(o);
      copy.disabled = false;
      status.textContent = "Review this command before running it on the Docker host.";
    } catch (error) {
      output.value = "";
      copy.disabled = true;
      status.textContent = error.message;
    }
  });
  copy.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(output.value);
      status.textContent = "Copied.";
    } catch {
      output.select();
      status.textContent = "Clipboard unavailable. Copy the selected command manually.";
    }
  });
  update();
}
