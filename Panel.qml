import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar widget for the desktop-wide duotone shader. Clicking the bar icon drops
// a list of hues straight down — one click to open, one to apply — with an
// "Off" row at the bottom that returns to full colour.
//
// The palette table lives in `bin/omarchy-monochrome`, not here: its `json`
// subcommand reports every palette (name, label, and its shadow/mid/highlight
// colours) plus which one is active. Adding a hue to that script's PALETTES
// array is enough to make it appear here, swatch and all.
Panel {
  id: root
  moduleName: "nzkritik.desktop-hue"
  ipcTarget: "nzkritik.desktop-hue"

  // Straight from `omarchy-monochrome json`.
  property var palettes: []
  // Active palette name; "" means the shader is off.
  property string activeName: ""

  // Panel cursor for keyboard navigation, mirroring the first-party panels:
  // it stays dormant until the first arrow/hover so Enter can't fire blind.
  property int cursor: 0
  property bool cursorActive: false

  readonly property string offRow: "__off__"

  // The shader script ships in this repo, so a fresh `omarchy plugin add`
  // works with nothing else installed. Qt hands us a file:// URL; Process
  // needs a plain path.
  readonly property string pluginDir: {
    var u = String(Qt.resolvedUrl("."))
    return u.indexOf("file://") === 0 ? u.substring(7) : u
  }
  readonly property string bundledBin: pluginDir + "bin/omarchy-monochrome"

  // Prefer the bundled copy; fall back to one on PATH so anyone who already
  // runs omarchy-monochrome (e.g. from a keybinding) keeps a single install.
  function monochrome(args) {
    return ["bash", "-c",
            'if [ -x "$0" ]; then exec "$0" "$@"; else exec omarchy-monochrome "$@"; fi',
            bundledBin].concat(args)
  }

  // The hue rows plus a trailing "Off" pseudo-row, so the list and the
  // keyboard cursor can share one index space.
  readonly property var rows: {
    var out = []
    for (var i = 0; i < palettes.length; i++) out.push(palettes[i])
    out.push({ name: offRow, label: "Off (full colour)", shadow: "", mid: "", highlight: "" })
    return out
  }

  // Row index for a palette name; "" is the trailing Off row. Kept as a plain
  // function so callers can resolve an index from data they just parsed,
  // without depending on when QML re-evaluates the activeIndex binding.
  function indexOfName(name) {
    if (name === "") return palettes.length
    for (var i = 0; i < palettes.length; i++)
      if (String(palettes[i].name) === name) return i
    return -1
  }

  readonly property int activeIndex: {
    // Touch both dependencies so the binding tracks them through the call.
    palettes.length
    return indexOfName(activeName)
  }

  function refresh() {
    if (!listProc.running) listProc.running = true
  }

  function ingest(text) {
    try {
      var data = JSON.parse(String(text))
      palettes = data.palettes || []
      activeName = String(data.active || "")
      // refresh() is async, so onOpenedChanged seeded the cursor from whatever
      // was in hand then — an empty list on first open, or a stale active row.
      // Re-seed from the data just parsed, unless the user has already moved.
      if (opened && !cursorActive) {
        var idx = indexOfName(activeName)
        cursor = idx >= 0 ? idx : 0
      }
    } catch (e) {
      // A broken/absent shader script leaves an empty list rather than a
      // half-populated one; the panel then shows only the Off row.
      palettes = []
      activeName = ""
    }
  }

  function applyRow(index) {
    if (index < 0 || index >= rows.length || actionProc.running) return
    var name = String(rows[index].name)
    actionProc.command = root.monochrome(name === offRow ? ["off"] : ["set", name])
    actionProc.running = true
  }

  function moveCursor(delta) {
    // Ignore keys until the palette list is in. Waking the cursor against the
    // placeholder single-row list would pin it to 0 and suppress the re-seed
    // below, so the first Enter would apply the wrong hue.
    if (palettes.length === 0) return
    // First keypress only wakes the cursor, so it lands on the active row
    // instead of jumping one past it.
    if (!cursorActive) { cursorActive = true; return }
    var n = rows.length
    if (n <= 0) return
    cursor = ((cursor + delta) % n + n) % n
  }

  // Keep the resting cursor on the active row however the data arrives —
  // first open after a reload, or the active hue changing under us — right up
  // until the user takes manual control.
  onActiveIndexChanged: if (opened && !cursorActive && activeIndex >= 0) cursor = activeIndex

  onOpenedChanged: {
    if (!opened) return
    cursorActive = false
    var idx = indexOfName(activeName)
    cursor = idx >= 0 ? idx : 0
    // Kick the reload last: its result re-seeds the cursor when it lands.
    refresh()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Process {
    id: listProc
    command: root.monochrome(["json"])
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.ingest(text) }
  }

  // Re-read after every apply so the active marker reflects what the shader
  // actually ended up on, not what we asked for.
  Process {
    id: actionProc
    onExited: root.refresh()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰸌"
    tooltipText: "Desktop hue"
    onPressed: function(b) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(300))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) { root.moveCursor(dy !== 0 ? dy : dx) }
      onActivateRequested: if (root.cursorActive) root.applyRow(root.cursor)
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(10)

        PanelSectionHeader {
          text: "DESKTOP HUE"
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
        }

        Column {
          width: parent.width
          spacing: Style.spacing.labelGap

          Repeater {
            model: root.rows

            Rectangle {
              id: row
              required property var modelData
              required property int index

              readonly property bool isOff: String(modelData.name) === root.offRow
              readonly property bool isActive: index === root.activeIndex
              readonly property bool hot: root.cursorActive && root.cursor === index

              width: parent.width
              height: Style.spacing.popupRowHeight
              radius: Style.cornerRadius
              color: isActive
                ? Style.selectedFillFor(root.bar.foreground, Color.accent)
                : (hot ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent")

              // Swatch: the palette's highlight colour ringed by its midtone,
              // which is what the tint actually looks like on screen. The Off
              // row gets a hollow ring instead.
              Rectangle {
                id: swatch
                anchors.left: parent.left
                anchors.leftMargin: Style.spacing.controlPaddingX
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(13)
                height: width
                radius: width / 2
                color: row.isOff ? "transparent" : String(row.modelData.highlight)
                border.width: Math.max(1, Style.space(1))
                border.color: row.isOff
                  ? Qt.darker(root.bar.foreground, 1.6)
                  : String(row.modelData.mid || row.modelData.highlight)
              }

              Text {
                anchors.left: swatch.right
                anchors.leftMargin: Style.spacing.controlGap
                anchors.right: parent.right
                anchors.rightMargin: Style.spacing.controlPaddingX
                anchors.verticalCenter: parent.verticalCenter
                text: String(row.modelData.label)
                color: row.isActive || row.hot
                  ? Style.hoverStateColor(root.bar.foreground, Color.accent)
                  : root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onPositionChanged: {
                  root.cursorActive = true
                  root.cursor = row.index
                }
                onClicked: root.applyRow(row.index)
              }
            }
          }
        }
      }
    }
  }
}
