import QtQuick
import qs.modules.common

MouseArea {
    id: root
    property int gridSize: 24
    property bool showGrid: false
    readonly property bool isWidgetCanvas: true
    readonly property bool gridVisible: showGrid && Config.options.background.showGrid

    property bool centerXActive: false
    property bool centerYActive: false

    // The item that paints the drag feedback (grid/center/selection/flash
    // lines). WidgetCanvas owns the interaction state; the visual host is
    // elevated above the depth wallpaper container by Background.qml.
    property Item visualHost: null

    property var registeredWidgets: []
    property bool selecting: false
    property point selectionStartPoint: Qt.point(0, 0)
    property rect selectionRect: Qt.rect(0, 0, 0, 0)

    property var groupDragMemberStarts: []
    property real groupDragStartX: 0
    property real groupDragStartY: 0

    function setDragging(active) {
        root.showGrid = active
        if (!active) {
            root.centerXActive = false
            root.centerYActive = false
        }
    }

    function setCenterActive(xActive, yActive) {
        root.centerXActive = xActive
        root.centerYActive = yActive
    }

    function registerWidget(widget) {
        root.registeredWidgets = root.registeredWidgets.concat([widget])
    }

    function unregisterWidget(widget) {
        root.registeredWidgets = root.registeredWidgets.filter(w => w !== widget)
    }

    // Widgets are positioned RELATIVE to the depth wallpaper layers, so the
    // canvas no longer maintains a widget-to-widget stack. Movement is a pure
    // layer-relative operation: forward = one layer toward the front.
    readonly property real depthLayerCount: Math.max(1, (Config.options.background.depthEffect.layers ?? []).length)

    function widgetByConfigName(key) {
        return root.registeredWidgets.find(w => w.configEntryName === key)
    }

    // Resolve the config object for any widget key: custom widgets live in
    // the customWidgets array (keyed by their id), everything else in the
    // keyed widgets object.
    function widgetEntryFromConfig(key) {
        const ids = Config.options.background.widgets.customWidgetIds ?? []
        if (ids.includes(key)) {
            const list = Config.options.background.widgets.customWidgets ?? []
            return list.find(w => w?.id === key) ?? null
        }
        return Config.options.background.widgets[key]
    }

    // list<var> entries are persisted/reactive only after a whole-list
    // reassignment (same pattern the depth-effect settings use for layers).
    function persistCustomWidget(entry) {
        if (!entry?.id) return
        const list = (Config.options.background.widgets.customWidgets ?? [])
            .map(w => (w.id === entry.id ? entry : w))
        Config.options.background.widgets.customWidgets = list
    }

    function isCustomWidgetKey(key) {
        return (Config.options.background.widgets.customWidgetIds ?? []).includes(key)
    }

    // Effective "above layer k-1" position for a widget. Out-of-range or
    // unset (-1) values mean the default = above the highest layer.
    function effectiveDepthPosition(key) {
        const entry = root.widgetEntryFromConfig(key)
        const raw = entry?.depthLayerPosition ?? -1
        return (raw > 0 && raw <= root.depthLayerCount) ? raw : root.depthLayerCount
    }

    function canMoveFront(key) {
        if (root.widgetByConfigName(key)?.pinnedBottom) return false
        const w = root.widgetByConfigName(key)
        return root.effectiveDepthPosition(key) < root.depthLayerCount
    }

    function canMoveBack(key) {
        if (root.widgetByConfigName(key)?.pinnedBottom) return false
        return root.effectiveDepthPosition(key) > 1
    }

    // Move the widget one wallpaper layer toward the front. Stops at the
    // position above the highest wallpaper layer.
    function moveLayerFront(widget) {
        if (widget?.pinnedBottom) return
        const pos = Math.min(root.depthLayerCount, root.effectiveDepthPosition(widget.configEntryName) + 1)
        const entry = root.widgetEntryFromConfig(widget.configEntryName)
        if (!entry) return
        entry.depthLayerPosition = pos
        if (root.isCustomWidgetKey(widget.configEntryName)) root.persistCustomWidget(entry)
    }

    // Move the widget one wallpaper layer toward the back. The first click
    // from the default (above-highest) position drops it right behind the
    // highest layer; it can never go below the background layer.
    function moveLayerBack(widget) {
        if (widget?.pinnedBottom) return
        const pos = Math.max(1, root.effectiveDepthPosition(widget.configEntryName) - 1)
        const entry = root.widgetEntryFromConfig(widget.configEntryName)
        if (!entry) return
        entry.depthLayerPosition = pos
        if (root.isCustomWidgetKey(widget.configEntryName)) root.persistCustomWidget(entry)
    }

    function clearSelection() {
        for (const widget of root.registeredWidgets) widget.selected = false
    }

    function rectsIntersect(a, b) {
        return a.x < b.x + b.width && a.x + a.width > b.x
            && a.y < b.y + b.height && a.y + a.height > b.y
    }

    function selectWithinRect(rect) {
        for (const widget of root.registeredWidgets) {
            const widgetRect = Qt.rect(widget.x, widget.y, widget.width, widget.height)
            widget.selected = root.rectsIntersect(rect, widgetRect)
        }
    }

    function beginGroupDrag(initiator) {
        if (!initiator.selected) {
            root.groupDragMemberStarts = []
            return
        }
        root.groupDragStartX = initiator.x
        root.groupDragStartY = initiator.y
        root.groupDragMemberStarts = root.registeredWidgets
            .filter(w => w.selected && w !== initiator)
            .map(w => ({ widget: w, startX: w.x, startY: w.y }))
        for (const entry of root.groupDragMemberStarts) entry.widget.groupDragActive = true
    }

    function updateGroupDrag(initiator) {
        if (root.groupDragMemberStarts.length === 0) return
        const dx = initiator.x - root.groupDragStartX
        const dy = initiator.y - root.groupDragStartY
        for (const entry of root.groupDragMemberStarts) {
            entry.widget.x = entry.startX + dx
            entry.widget.y = entry.startY + dy
        }
    }

    function endGroupDrag() {
        for (const entry of root.groupDragMemberStarts) {
            entry.widget.groupDragActive = false
            entry.widget.commitPosition()
        }
        root.groupDragMemberStarts = []
    }

    onPressed: (mouse) => {
        if (Config.options.background.widgetsLocked) return
        root.selecting = true
        root.selectionStartPoint = Qt.point(mouse.x, mouse.y)
        root.selectionRect = Qt.rect(mouse.x, mouse.y, 0, 0)
        if (!(mouse.modifiers & Qt.ControlModifier)) root.clearSelection()
    }

    onPositionChanged: (mouse) => {
        if (!root.selecting) return
        const startX = root.selectionStartPoint.x
        const startY = root.selectionStartPoint.y
        const rectX = Math.min(startX, mouse.x)
        const rectY = Math.min(startY, mouse.y)
        const rectW = Math.abs(mouse.x - startX)
        const rectH = Math.abs(mouse.y - startY)
        root.selectionRect = Qt.rect(rectX, rectY, rectW, rectH)
        root.selectWithinRect(root.selectionRect)
    }

    onReleased: {
        root.selecting = false
    }

    function flashLines(verticalPositions, horizontalPositions) {
        if (root.visualHost)
            root.visualHost.flashLines(verticalPositions, horizontalPositions)
    }
}