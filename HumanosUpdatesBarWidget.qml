import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "lib" as Lib
import "lib/humanos-updates-labels.js" as Labels

// Update badge for the bar (Omarchy plugin "humanos-updates"): a capsule that
// names the new Omarchy version
// and how many other packages are waiting, plus a dropdown listing what is
// waiting — Omarchy, repository packages, AUR, Flatpak and plugins.
//
// This is a standalone Omarchy bar-widget plugin (plugins/ilyamaximusaws.
// humanos-updates), so the bar picks it up from the plugin directory. It
// follows the same contract every shipped widget follows, or clicks never
// reach it:
//
//   * root is a `BarWidget`, which is what makes the bar/moduleName/settings
//     injection meaningful and gives broadcast()/setting().
//   * the clickable thing is a `WidgetButton`. The bar routes presses through
//     its slot MouseArea plus a registry of click targets
//     (`registerClickTarget`), and only WidgetButton/BarIconButton register
//     themselves. A bare Item with a private TapHandler never sees the
//     press — the slot swallows it. That was the whole bug.
//   * the root exposes open()/close()/toggle()/opened so hotkey routing
//     (`omarchy-shell shell toggle humanos-updates`) and
//     switchPanelFrom work
//     like they do for omarchy.clock & friends.
//
// The dropdown is the stock KeyboardPanel, so outside-click dismissal,
// single-popout coordination with the other bar panels and the open-panel
// underline all come for free.
BarWidget {
  id: root

  moduleName: "humanos-updates"

  // Last known result, read synchronously as the shell starts (FileView with
  // blockLoading), so a fresh session or a bar reload shows the previous answer
  // instead of a placeholder for the whole length of the check. The script
  // writes this file before printing, so it is never behind the live result.
  FileView {
    id: cacheFile

    path: (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache"))
      + "/omarchy/humanos-update-cache.json"
    blockLoading: true
    watchChanges: true
    printErrors: false
    onLoaded: {
      // Only fills the gap; a result already in this session is newer, and
      // applyResult refuses anything without a state anyway.
      if (root.checkState === "") root.applyResult(text())
    }
    onFileChanged: {
      if (root.checkState === "") reload()
    }
  }

  // "clean" | "updates" | "stale", seeded from the cache and replaced by each
  // fresh check. "" only if there has never been a successful run.
  property string checkState: ""
  property var result: ({})

  // ---------------------------------------------------------------- lifecycle
  readonly property bool opened: popoutOpen

  property bool popoutOpen: false
  property bool popoutSwitchClosing: false

  function open() {
    if (!root.bar) return
    root.bar.hideTooltip(button)
    popoutOpen = true
  }

  function close() { popoutOpen = false }

  function toggle() { popoutOpen ? close() : open() }

  // Bar.requestPopout prefers this over close() when swapping popouts.
  function closeForPopoutSwitch() {
    popoutSwitchClosing = true
    close()
    Qt.callLater(function() { popoutSwitchClosing = false })
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root, direction)
    return false
  }

  // -------------------------------------------------------------- IPC / hotkey
  // A bar surface exists per monitor, so route through broadcast() and keep
  // the target off the "omarchy." namespace.
  IpcHandler {
    target: "humanos.updates"

    function toggle(): void { root.broadcast("toggle") }
    function open(): void { root.broadcast("open") }
    function close(): void { root.broadcast("close") }
    function refresh(): void { root.broadcast("refresh") }
  }

  // qs.Commons singletons are the same ones every other panel colours itself
  // from, so the dropdown matches the notification centre without copying.
  readonly property var theme: Color
  readonly property var info: result || ({})
  readonly property var counts: info.counts || ({})
  readonly property var packages: info.packages || ({})
  readonly property var omarchyInfo: info.omarchy || ({})
  // Which sources answered. Absent on a cache written before this existed.
  readonly property var sources: info.sources || ({})
  readonly property string checkedAt: String(info.checkedAt || "")

  readonly property bool known: checkState !== ""
  readonly property bool omarchyAvailable: omarchyInfo.available === true
  readonly property int extrasCount: Number(counts.extras || 0)
  readonly property int staleAfterDays: Number(info.staleAfterDays || 7)
  readonly property int daysSinceUpgrade: Number(info.daysSinceUpgrade)
  // The check takes ~11s (four network sources), so the badge must be on the
  // bar — and clickable — from the first frame. It collapses to zero width the
  // moment it claims no content, which is what a fresh shell would look like
  // for the first eleven seconds of every session.
  readonly property bool hasBadge: true

  // A run that could not reach a source is not an answer. Until one lands the
  // badge holds its last state and the first check is retried, because the
  // shell often starts before the network is up.
  property var retryDelays: [20000, 60000, 180000]
  property int retryIndex: 0
  property bool waitingForNetwork: false

  function scheduleRetry() {
    if (retryTimer.running) return
    waitingForNetwork = true
    if (retryIndex >= retryDelays.length) return
    retryTimer.interval = retryDelays[retryIndex]
    retryIndex++
    retryTimer.running = true
  }

  // "18:20" out of the ISO timestamp, for the tooltip and the panel footer.
  readonly property string checkedAtLabel: checkedAt.length >= 16 ? checkedAt.slice(11, 16) : ""

  // Green when there is nothing to do, red when the last full upgrade is too
  // old to trust, amber while updates are waiting, dim while unknown.
  readonly property color dotColor: !known ? Qt.alpha(theme.popups.text, 0.45)
    : checkState === "clean" ? "#3ddc84"
    : checkState === "stale" ? "#ff5f56"
    : "#f5c542"

  // The new version, and how many packages beyond Omarchy itself. The label
  // lives in humanos-updates-labels.js so it can be tested: the capsule shows
  // the number of waiting updates ("0" when clean), never the word "Updated".
  readonly property string omarchyTarget: omarchyAvailable ? String(omarchyInfo.to || "") : ""
  readonly property string capsuleLabel: Labels.capsuleLabel(
    known, checkState, extrasCount, omarchyTarget, daysSinceUpgrade)

  readonly property string omarchySummary: omarchyAvailable
    ? String(omarchyInfo.from || "") + " \u2192 " + String(omarchyInfo.to || "")
    : ""

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // ------------------------------------------------------------------ check

  function applyResult(raw) {
    var data
    try {
      data = JSON.parse(String(raw || ""))
    } catch (e) {
      return false
    }
    if (!data || typeof data.state !== "string" || data.state === "")
      return false
    // A degraded run is not an answer: hold the badge and try again. The
    // script already echoes the last known state here, which is why it must be
    // rejected rather than applied.
    if (data.degraded === true) {
      root.scheduleRetry()
      return false
    }
    result = data
    checkState = data.state
    retryIndex = 0
    waitingForNetwork = false
    if (retryTimer.running) retryTimer.running = false
    return true
  }

  function refresh() {
    if (!checkProcess.running) checkProcess.running = true
  }

  Process {
    id: checkProcess
    command: [Lib.Paths.script("humanos-update-check")]
    stdout: StdioCollector {
      id: collector
      waitForEnd: true
    }
    onExited: function(exitCode) {
      // An unreadable result means "unknown", never a green light; the badge
      // keeps its previous colour and the retry timer tries again.
      if (!root.applyResult(collector.text)) root.scheduleRetry()
    }
  }

  // Retrying the first check: the shell starts before the network is up, and a
  // failed source used to look like "everything is fine" for the whole
  // session. Three quick retries, then the six-hour timer takes over.
  Timer {
    id: retryTimer
    repeat: false
    running: false
    onTriggered: root.refresh()
  }

  Timer {
    // Six hours: all four sources hit the network, and a list minutes old is
    // as useful as a fresh one.
    interval: 6 * 60 * 60 * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Re-check on open so the list is never the one from this morning, and on
  // close so the badge reflects what the user just installed.
  onOpenedChanged: root.refresh()

  // ------------------------------------------------------------------ badge
  // The button owns width, tooltip, hover and — critically — the click
  // registration the bar delivers presses through. The capsule is decoration
  // inside it and must stay non-interactive: an anchor-filling child would
  // otherwise sit above the button's own MouseArea and eat the press.
  WidgetButton {
    id: button

    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    // The capsule is the content, so it drives width: WidgetButton sizes from
    // its own Text label, and an empty one would collapse the slot to its 12px
    // floor no matter what is painted inside.
    fixedWidth: Math.max(12, row.implicitWidth + Style.spaceReal(20))
    hasVisualContent: root.hasBadge
    tooltipText: root.tooltipText()

    onPressed: function(mouseButton) {
      if (mouseButton === Qt.RightButton) {
        if (root.bar)
          root.bar.run("omarchy-launch-floating-terminal-with-presentation omarchy-update")
        return
      }
      root.toggle()
    }

    Rectangle {
      id: capsule
      anchors.centerIn: parent
      width: row.implicitWidth + Style.space(20)
      height: parent.height - Style.space(8)
      radius: height / 2
      // Subtle chip instead of the hard white pill (#f2f2f2) that stood out
      // against the bar: a light wash of the theme's own text colour, so it
      // follows every theme and stays quiet on a dark bar.
      color: Qt.alpha(root.theme.popups.text, 0.12)

      Row {
        id: row
        anchors.centerIn: parent
        spacing: Style.space(6)

        // The dot: green when current, amber when something waits, red when
        // the last full upgrade is too old.
        Rectangle {
          width: Style.space(6)
          height: Style.space(6)
          radius: width / 2
          color: root.dotColor
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          textFormat: Text.PlainText
          text: root.capsuleLabel
          color: root.theme.popups.text
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          font.weight: Font.Medium
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          // Font Awesome arrows-rotate; present in Maple Mono NF.
          text: "\uf2f1"
          color: root.theme.popups.text
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
          anchors.verticalCenter: parent.verticalCenter
        }
      }
    }
  }

  function tooltipText() {
    if (!known) return "Update check has not run yet\u2026"
    var parts = []
    if (waitingForNetwork) parts.push("last check failed \u2014 retrying")
    if (omarchyAvailable) parts.push("Omarchy " + omarchySummary)
    if (extrasCount > 0) parts.push(extrasCount + " other updates")
    if (checkState === "clean" && extrasCount === 0) parts.push("Up to date")
    if (checkState === "stale" && extrasCount === 0)
      parts.push("No full upgrade in " + daysSinceUpgrade + "d (limit " + staleAfterDays + "d)")
    var status = sourceStatusText()
    if (status !== "") parts.push(status)
    if (checkedAtLabel !== "") parts.push("checked " + checkedAtLabel)
    return parts.join("  \u00b7  ")
  }

  // Which sources did not answer, so "nothing waiting" is never shown next to a
  // source that was never asked.
  function sourceStatusText() {
    var names = { repo: "repo", aur: "AUR", flatpak: "Flatpak", plugins: "plugins" }
    var failed = []
    var skipped = []
    for (var key in names) {
      var value = String(sources[key] || "")
      if (value === "fail") failed.push(names[key])
      else if (value === "skip") skipped.push(names[key])
    }
    var parts = []
    if (failed.length > 0) parts.push("unverified: " + failed.join(", "))
    if (skipped.length > 0) parts.push("not installed: " + skipped.join(", "))
    return parts.join("; ")
  }

  // --------------------------------------------------------------- dropdown
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    // The PluginBarApi facade carries exactly the members KeyboardPanel
    // reaches for: position, barSize, activePopout, requestPopout,
    // releasePopout, clickTargets, targetBelongsToWindow.
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    padding: Style.spacing.popupPadding
    borderSpec: Border.flat(Qt.alpha(Color.popups.text, 0.15), 1)
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
    }

    Column {
      id: content
      width: parent.width
      spacing: Style.space(10)

      // ------------------------------------------------------------- header
      Item {
        width: parent.width
        height: Style.space(46)

        Column {
          anchors.left: parent.left
          anchors.leftMargin: Style.space(2)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          Text {
            textFormat: Text.PlainText
            text: "Updates"
            color: root.theme.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.title
            font.bold: true
          }

          Text {
            textFormat: Text.PlainText
            width: content.width - Style.space(4)
            elide: Text.ElideRight
            text: root.headerSubtitle()
            color: Qt.alpha(root.theme.popups.text, 0.6)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        Rectangle {
          anchors.bottom: parent.bottom
          width: parent.width
          height: 1
          color: Qt.alpha(root.theme.popups.text, 0.08)
        }
      }

      // ------------------------------------------------------------ Omarchy
      SectionHeader {
        visible: root.omarchyAvailable
        text: "OMARCHY"
      }

      Item {
        visible: root.omarchyAvailable
        width: parent.width
        height: omarchyVersion.implicitHeight + Style.space(2)

        Text {
          textFormat: Text.PlainText
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: Math.max(0, parent.width - omarchyVersion.implicitWidth - Style.space(8))
          elide: Text.ElideRight
          text: "omarchy"
          color: root.theme.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          id: omarchyVersion
          textFormat: Text.PlainText
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: root.omarchySummary
          color: Qt.alpha(root.theme.popups.text, 0.55)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }

      // -------------------------------------------------------------- sources
      SectionHeader {
        text: "PACKAGE UPDATES"
        visible: root.extrasCount > 0
      }

      PackageGroup {
        label: "Repository"
        items: root.packages.repo
      }

      PackageGroup {
        label: "AUR"
        items: root.packages.aur
      }

      PackageGroup {
        label: "Flatpak"
        items: root.packages.flatpak
      }

      PackageGroup {
        label: "Plugins"
        items: root.packages.plugins
      }

      // ------------------------------------------------------------ all clear
      Text {
        visible: !root.omarchyAvailable && root.extrasCount === 0
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        textFormat: Text.PlainText
        text: root.checkState === "stale"
          ? "No updates \u2014 last full upgrade " + root.daysSinceUpgrade + "d ago"
          : "Everything is up to date"
        color: Qt.alpha(root.theme.popups.text, 0.7)
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        topPadding: Style.space(4)
        bottomPadding: Style.space(4)
      }

      // --------------------------------------------------------------- footer
      PanelSeparator { }

      Item {
        width: parent.width
        height: lastUpgradeText.implicitHeight

        Text {
          id: lastUpgradeText
          textFormat: Text.PlainText
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: Math.max(0, parent.width - Style.space(140))
          elide: Text.ElideRight
          text: root.footerLabel()
          color: Qt.alpha(root.theme.popups.text, 0.6)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        Text {
          textFormat: Text.PlainText
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: "Open updater"
          color: root.theme.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.underline: updateHover.hovered

          HoverHandler { id: updateHover; cursorShape: Qt.PointingHandCursor }
          TapHandler {
            onTapped: {
              root.close()
              if (root.bar)
                root.bar.run("omarchy-launch-floating-terminal-with-presentation omarchy-update")
            }
          }
        }
      }
    }
  }

  function headerSubtitle() {
    if (!known) return "No data yet"
    if (!omarchyAvailable && extrasCount === 0)
      return checkState === "stale" ? "System needs an update" : "Nothing waiting"
    var parts = []
    if (omarchyAvailable) parts.push("Omarchy " + omarchySummary)
    if (extrasCount > 0) parts.push(extrasCount + " updates")
    return parts.join("  \u00b7  ")
  }

  function lastUpgradeLabel() {
    if (daysSinceUpgrade < 0) return "unknown"
    if (daysSinceUpgrade === 0) return "today"
    return daysSinceUpgrade + "d ago"
  }

  function footerLabel() {
    var text = "Last full upgrade: " + root.lastUpgradeLabel()
    if (checkedAtLabel !== "") text += "  \u00b7  checked " + checkedAtLabel
    var status = sourceStatusText()
    if (status !== "") text += "  \u00b7  " + status
    return text
  }

  // Small-caps section label, as the other panels use.
  component SectionHeader: Text {
    textFormat: Text.PlainText
    color: Qt.darker(root.theme.popups.text, 1.4)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    font.bold: true
    topPadding: Math.ceil(Style.font.caption * 0.15)
  }

  // One source's rows: a dimmed label and one line per package, the version
  // move right-aligned so names of every length stay in a column.
  component PackageGroup: Column {
    id: group

    property string label: ""
    property var items: []
    readonly property int count: Array.isArray(items) ? items.length : 0

    visible: count > 0
    width: parent.width
    spacing: Style.space(3)

    Text {
      textFormat: Text.PlainText
      text: group.label
      color: Qt.alpha(root.theme.popups.text, 0.55)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    Repeater {
      model: group.items

      delegate: Item {
        required property var modelData
        width: group.width
        height: nameText.implicitHeight + Style.space(2)

        Text {
          id: nameText
          textFormat: Text.PlainText
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: Math.max(0, parent.width - versionText.implicitWidth - Style.space(8))
          elide: Text.ElideRight
          text: String(modelData.name || "")
          color: root.theme.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          id: versionText
          textFormat: Text.PlainText
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: {
            var d = modelData
            if (d.to && d.from) return d.from + " \u2192 " + d.to
            if (typeof d.behind === "number") return "+" + d.behind
            return ""
          }
          color: Qt.alpha(root.theme.popups.text, 0.55)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
