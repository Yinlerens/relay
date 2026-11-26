import path from "node:path";
import fs from "node:fs";
import vm from "node:vm";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const esbuild = require("C:/Users/19195/Desktop/cc/oo/node_modules/esbuild");

const scriptDir = path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, "$1"));
const entryFile = path.join(scriptDir, "waveshelf_bridge_entry.ts");
const outDir = path.resolve(scriptDir, "../Relay/Resources");
const outFile = path.join(outDir, "waveshelf-engine.js");

fs.mkdirSync(outDir, { recursive: true });

await esbuild.build({
  entryPoints: [entryFile],
  bundle: true,
  format: "iife",
  target: "es2020",
  platform: "neutral",
  mainFields: ["module", "main"],
  minify: true,
  outfile: outFile,
  charset: "utf8",
  logLevel: "info",
});

const bundleCode = fs.readFileSync(outFile, "utf8");
const context = vm.createContext({
  console,
  Math,
  JSON,
  Object,
  Array,
  Number,
  String,
  Boolean,
  Date,
  RegExp,
  Error,
  Map,
  Set,
  WeakMap,
  Float64Array,
});
vm.runInContext(bundleCode, context);

const engine = context.WaveShelfEngine;
if (!engine) {
  throw new Error("WaveShelfEngine global not initialized");
}

const presets = JSON.parse(engine.listTeamPresetsJSON());
const plan = JSON.parse(
  engine.calculateGachaPlanJSON(
    JSON.stringify({
      charPity: 54,
      charGuaranteed: true,
      targetCharCopies: 1,
      weaponPity: 22,
      targetWeaponCopies: 1,
      astrite: 14800,
      radiantTide: 18,
      forgingTide: 0,
      coralPulls: 0,
      coralDirectChains: 0,
    }),
  ),
);
const weapons = JSON.parse(engine.listCompatibleWeaponsJSON(2));
const weights = JSON.parse(engine.getEchoScoreWeightTableJSON(1210, "热熔"));

console.log(
  JSON.stringify(
    {
      bytes: Buffer.byteLength(bundleCode, "utf8"),
      version: engine.version(),
      presetsCount: presets.length,
      firstPreset: presets[0]?.id,
      gachaProbPct: Math.round(plan.successProbability * 1000) / 10,
      swordWeaponsCount: weapons.length,
      weightRowsCount: weights.rows?.length,
    },
    null,
    2,
  ),
);
