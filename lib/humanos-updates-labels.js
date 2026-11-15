// Pure label logic for the humanos-updates badge.
//
// Kept out of the QML file so it can be tested with node (WOR-19). The capsule
// is a number at a glance — the count of waiting updates, "0" when everything
// is current (no more "Updated"; the dot colour carries clean/updates/stale).
// A new Omarchy release is the exception: then the capsule shows its version
// ("1.7-2", or "1.7-2 +3" when other packages wait too), because the version is
// what the capsule is for. A stale check with nothing queued shows "Nd" so it
// can never be mistaken for a fresh "all clear".

.pragma library

function capsuleLabel(known, checkState, extrasCount, omarchyTarget, daysSinceUpgrade) {
  if (!known) return "\u2014"
  var target = omarchyTarget ? String(omarchyTarget) : ""
  var extras = Number(extrasCount)
  if (!isFinite(extras) || extras < 0) extras = 0
  if (target.length > 0) return extras > 0 ? target + " +" + extras : target
  if (extras > 0) return String(extras)
  if (checkState === "clean") return "0"
  // stale, or anything else with nothing queued: say how old the last full
  // upgrade is rather than claiming the system is current.
  var days = Number(daysSinceUpgrade)
  if (!isFinite(days) || days < 0) return "Unknown"
  return String(days) + "d"
}
