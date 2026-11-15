#!/usr/bin/env node
// Tests for ../lib/humanos-updates-labels.js (run: node tests/test-humanos-updates-labels.js)
// (WOR-19: the capsule shows the number of waiting updates, "0" when clean —
// never the word "Updated"; a stale check never falls through to a count.)
//
// The QML library file starts with `.pragma library`, which is not valid
// JavaScript, so the pragma line is stripped before evaluating it here.

const fs = require("fs")
const path = process.argv[2]
  || require("path").join(__dirname, "..", "lib", "humanos-updates-labels.js")

const source = fs.readFileSync(path, "utf8").replace(/^\.pragma library\s*$/m, "")
// eslint-disable-next-line no-eval
eval(source)

let pass = 0
let fail = 0
function eq(name, actual, expected) {
  if (actual === expected) {
    pass++
    console.log("ok   " + name)
  } else {
    fail++
    console.log(`FAIL ${name}: got ${JSON.stringify(actual)}, want ${JSON.stringify(expected)}`)
  }
}

const capsule = capsuleLabel

eq("unknown -> dash", capsule(false, "", 0, "", 0), "\u2014")
eq("clean, nothing waiting -> 0", capsule(true, "clean", 0, "", 0), "0")
eq("clean with extras -> count", capsule(true, "clean", 2, "", 0), "2")
eq("updates with omarchy -> version", capsule(true, "updates", 0, "1.7-2", 0), "1.7-2")
eq("updates with both -> version +N", capsule(true, "updates", 3, "1.7-2", 0), "1.7-2 +3")
eq("stale with nothing waiting -> days, not Updated", capsule(true, "stale", 0, "", 14), "14d")
eq("stale with extras -> count, not days", capsule(true, "stale", 1, "", 14), "1")
eq("stale with unknown age -> Unknown", capsule(true, "stale", 0, "", -1), "Unknown")

console.log(`\n${pass} passed, ${fail} failed`)
process.exit(fail === 0 ? 0 : 1)
