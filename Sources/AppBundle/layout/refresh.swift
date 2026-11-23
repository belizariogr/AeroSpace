import AppKit
import Common

@MainActor
private var activeRefreshTask: Task<(), any Error>? = nil

@MainActor
func scheduleCancellableCompleteRefreshSession(
    _ event: RefreshSessionEvent,
    optimisticallyPreLayoutWorkspaces: Bool = false,
) {
    activeRefreshTask?.cancel()
    activeRefreshTask = Task.startUnstructured { @MainActor in
        try checkCancellation()
        await runHeavyCompleteRefreshSession(
            event,
            assumeCancellable: true,
            optimisticallyPreLayoutWorkspaces: optimisticallyPreLayoutWorkspaces,
        )
    }
}

@MainActor
func runHeavyCompleteRefreshSession(
    _ event: RefreshSessionEvent,
    assumeCancellable: Bool,
    layoutWorkspaces shouldLayoutWorkspaces: Bool = true,
    optimisticallyPreLayoutWorkspaces: Bool = false,
) async {
    let state = signposter.beginInterval(#function, "event: \(event) axTaskLocalAppThreadToken: \(axTaskLocalAppThreadToken?.idForDebug)")
    defer { signposter.endInterval(#function, state) }
    if !TrayMenuModel.shared.isEnabled { return }
    let res = await Result {
        try await $refreshSessionEvent.withValue(event) {
            try await syncFocusFromMacOs(recheckPopup: true)

            if shouldLayoutWorkspaces && optimisticallyPreLayoutWorkspaces { try await layoutWorkspaces() }

            await refreshModel_nonCancellable()
            try await refresh()
            gcMonitors()

            updateTrayText()
            SecureInputPanel.shared.refresh()
            try await normalizeLayoutReason()
            if shouldLayoutWorkspaces { try await layoutWorkspaces() }
        }
    }
    switch res {
        case .success(()): break
        case .failure(let err as CancellationError): check(assumeCancellable, "Non cancellable refresh session was canceled: \(err) (\(type(of: err)))")
        case .failure(let err): die("Illegal error: \(err)")
    }
}

@MainActor
func runLightSession<T>(
    _ event: RefreshSessionEvent,
    _: RunSessionGuard,
    body: @MainActor () async throws -> T,
) async throws -> T {
    let state = signposter.beginInterval(#function, "event: \(event) axTaskLocalAppThreadToken: \(axTaskLocalAppThreadToken?.idForDebug)")
    defer { signposter.endInterval(#function, state) }
    activeRefreshTask?.cancel() // Give priority to runSession
    activeRefreshTask = nil
    return try await $refreshSessionEvent.withValue(event) {
        try await syncFocusFromMacOs(recheckPopup: event.isCommand)
        let focusBefore = globalFocus.windowOrNil

        await refreshModel_nonCancellable()
        let result = try await body()
        await refreshModel_nonCancellable()

        let focusAfter = globalFocus.windowOrNil

        updateTrayText()
        SecureInputPanel.shared.refresh()
        if !event.isFocusFollowsMouse { try await layoutWorkspaces() }
        if focusBefore != focusAfter {
            focusAfter?.nativeFocus() // syncFocusToMacOs
        }
        if !event.isFocusFollowsMouse { scheduleCancellableCompleteRefreshSession(event) }
        return result
    }
}

@MainActor
private func syncFocusFromMacOs(recheckPopup: Bool) async throws {
    let nativeFocused = try await getNativeFocusedWindow(.cancellable)
    if let nativeFocused { try await debugWindowsIfRecording(nativeFocused, .cancellable) }
    // updateFocusCache ignores popups, but new windows are sometimes mistakenly detected as popups.
    // Re-check, otherwise commands (e.g. move-node-to-workspace) are applied to the previously focused window
    if recheckPopup { try await (nativeFocused as? MacWindow)?.relayoutIfNoLongerPopup() }
    updateFocusCache(nativeFocused)
}

extension RefreshSessionEvent {
    /// Light sessions that run user commands. It's not safe to relayout windows in other light sessions:
    /// focus-follows-mouse sessions don't layout workspaces, and mouse drag sessions shouldn't reclassify the dragged window
    fileprivate var isCommand: Bool {
        switch self {
            case .hotkeyBinding, .socketServer, .menuBarButton: true
            default: false
        }
    }
}

enum RunSessionGuard: Sendable {
    case forceRun

    @MainActor
    static var isServerEnabled: Self? { TrayMenuModel.shared.isEnabled ? forceRun : nil }
    @MainActor
    static func isServerEnabled(orIsEnableCommand command: (any Command)?) -> Self? {
        command is EnableCommand ? .forceRun : .isServerEnabled
    }
    @MainActor
    static func checkServerIsEnabledOrDie(fileId: MyFileId = #myFileId) -> Self {
        .isServerEnabled ?? dieT("server is disabled", fileId: fileId)
    }
}

@MainActor
func refreshModel_nonCancellable() async {
    if refreshSessionEvent?.isFocusFollowsMouse == true {
        await checkOnFocusChangedCallbacks_nonCancellable()
    } else {
        Workspace.garbageCollectUnusedWorkspaces()
        Workspace.forceAssignWorkspaces()
        await checkOnFocusChangedCallbacks_nonCancellable()
        normalizeContainers()
    }
}

@MainActor
private func refresh() async throws {
    // Garbage collect terminated apps and windows before working with all windows
    let mapping = try await MacApp
        .refreshAllAndGetAliveWindowIds(frontmostAppBundleId: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    let aliveWindowIds = mapping.values.flatMap(\.keys).toSet()

    for window in MacWindow.allWindows {
        if !aliveWindowIds.contains(window.windowId) {
            window.lifeStatus = .dead
            window.garbageCollect(skipClosedWindowsCache: false)
        }
    }
    for (app, windows) in mapping {
        for (windowId, lifeStatus) in windows {
            try await MacWindow.getOrRegister(windowId: windowId, macApp: app).lifeStatus = lifeStatus
        }
    }

    // Garbage collect workspaces after apps, because workspaces contain apps.
    Workspace.garbageCollectUnusedWorkspaces()
}

func refreshObs(_: AXObserver, _: AXUIElement, notif: CFString, _: UnsafeMutableRawPointer?) {
    let notif = notif as String
    Task.startUnstructured { @MainActor in
        if !TrayMenuModel.shared.isEnabled { return }
        scheduleCancellableCompleteRefreshSession(.ax(notif))
    }
}

/// Window ids of on screen windows mapped to their position in the z-order (0 is the frontmost window)
@concurrent private func getOnScreenWindowsFrontToBackOrder() async -> [UInt32: Int] {
    let options = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
    // The windows are returned in the z-order, from front to back
    guard let cfArray = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [CFDictionary] else { return [:] }
    var result: [UInt32: Int] = [:]
    for (index, elem) in cfArray.enumerated() {
        guard let windowId = ((elem as NSDictionary)[kCGWindowNumber] as? NSNumber)?.uint32Value else { continue }
        result[windowId] = index
    }
    return result
}

/// For how long apps are given to redraw a window after it's resized (a few frames).
/// Apps apply the new size right away, but they redraw the window contents asynchronously
private let appRedrawAfterResizeDelay: Duration = .milliseconds(50)
/// See ``MacWindow/restoreSizeInCorner(_:isBackground:)``
let maxBackgroundSizeRestoreAttempts = 2

enum OptimalHideCorner {
    case bottomLeftCorner, bottomRightCorner
}

@MainActor
private func layoutWorkspaces() async throws {
    if !TrayMenuModel.shared.isEnabled {
        await syncDockAutoHide(hideInvisibleWorkspaces: {})
        for workspace in Workspace.all {
            workspace.allLeafWindowsRecursive.forEach { ($0 as! MacWindow).unhideFromCorner() } // todo as!
            try await workspace.layoutWorkspace() // Unhide tiling windows from corner
        }
        return
    }
    let monitors = globalUnsortedMonitorInfos
    var monitorToOptimalHideCorner: [Point: OptimalHideCorner] = [:]
    for monitor in monitors {
        let xOff = monitor.width * 0.1
        let yOff = monitor.height * 0.1
        // brc = bottomRightCorner
        let brc1 = monitor.rect.bottomRightCorner + Point(x: 2, y: -yOff)
        let brc2 = monitor.rect.bottomRightCorner + Point(x: -xOff, y: 2)
        let brc3 = monitor.rect.bottomRightCorner + Point(x: 2, y: 2)

        // blc = bottomLeftCorner
        let blc1 = monitor.rect.bottomLeftCorner + Point(x: -2, y: -yOff)
        let blc2 = monitor.rect.bottomLeftCorner + Point(x: xOff, y: 2)
        let blc3 = monitor.rect.bottomLeftCorner + Point(x: -2, y: 2)

        func contains(_ monitor: MonitorInfo, _ point: Point) -> Int { monitor.rect.contains(point) ? 1 : 0 }
        let important = 10

        // A monitor next to the side of the corner, at any height (e.g. a shorter laptop screen aligned to the top of
        // an external monitor). Windows hidden in the corner don't necessarily stay there: apps move them vertically,
        // e.g. when the Dock is shown, apps shrink their windows to the new visible frame and move them up.
        // Such a window would slide up onto that monitor
        func isNextTo(_ other: MonitorInfo, x: CGFloat) -> Int {
            other.rect.minX <= x && x < other.rect.maxX && other.rect.minY < monitor.rect.maxY && monitor.rect.minY < other.rect.maxY ? 1 : 0
        }
        let leftSide = monitors.sumOfInt { isNextTo($0, x: monitor.rect.minX - 2) }
        let rightSide = monitors.sumOfInt { isNextTo($0, x: monitor.rect.maxX + 2) }

        let corner: OptimalHideCorner =
            monitors.sumOfInt { contains($0, blc1) + contains($0, blc2) + important * contains($0, blc3) } + leftSide <
            monitors.sumOfInt { contains($0, brc1) + contains($0, brc2) + important * contains($0, brc3) } + rightSide
            ? .bottomLeftCorner
            : .bottomRightCorner
        monitorToOptimalHideCorner[monitor.rect.topLeftCorner] = corner
    }

    func hideInvisibleWorkspaces() async throws {
        var windowsToHide: [(window: MacWindow, corner: OptimalHideCorner)] = []
        for workspace in Workspace.all where !workspace.isVisible {
            guard let monitor = workspace.nodeMonitorInfo else { continue }
            let corner = monitorToOptimalHideCorner[monitor.rect.topLeftCorner] ?? .bottomRightCorner
            for window in workspace.allLeafWindowsRecursive {
                windowsToHide.append((window as! MacWindow, corner)) // todo as!
            }
        }
        if windowsToHide.isEmpty { return }
        // Hiding windows one by one (every window needs AX requests) is slow. Windows behind the already hidden ones
        // would show up for a moment. So first, the AX requests are made concurrently,
        // and then all windows are hidden at once
        async let frontToBackOrder = getOnScreenWindowsFrontToBackOrder()
        let rects = try await windowsToHide.mapConcurrently { (window, corner) in
            window.isAxRectNeededToHideInCorner(corner) ? try await window.getAxRect(.cancellable) : nil
        }
        let order = await frontToBackOrder
        // Hide the windows from back to front, so that the windows behind don't show up when the front ones are hidden
        let backToFront = zip(windowsToHide, rects).sorted { lhs, rhs in
            let lhsOrder = lhs.0.window.nativeWindowId.flatMap { order[$0] } ?? Int.max
            let rhsOrder = rhs.0.window.nativeWindowId.flatMap { order[$0] } ?? Int.max
            return lhsOrder > rhsOrder
        }
        for ((window, corner), rect) in backToFront {
            // Concurrent refresh sessions might have changed the tree while the AX requests were in progress
            guard let workspace = window.nodeWorkspace, !workspace.isVisible else { continue }
            window.hideInCorner(corner, currentRect: rect)
        }
    }

    await syncDockAutoHide(hideInvisibleWorkspaces: { try? await hideInvisibleWorkspaces() })
    // Windows of the workspaces that have just become visible might have been resized while they were hidden in the corner
    // (e.g. when the Dock was shown). Resize them back while they are still in the corner, and let apps redraw them
    // in the new size before they are moved onto the screen
    var isAnyWindowResizedInCorner = false
    for monitor in monitors {
        let corner = monitorToOptimalHideCorner[monitor.rect.topLeftCorner] ?? .bottomRightCorner
        for window in monitor.visibleWorkspace.allLeafWindowsRecursive {
            if try await (window as! MacWindow).restoreSizeInCorner(corner) { // todo as!
                isAnyWindowResizedInCorner = true
            }
        }
    }
    if isAnyWindowResizedInCorner { try await Task.sleep(for: appRedrawAfterResizeDelay) }
    // to reduce flicker, first unhide visible workspaces, then hide invisible ones
    for monitor in monitors {
        let workspace = monitor.visibleWorkspace
        workspace.allLeafWindowsRecursive.forEach { ($0 as! MacWindow).unhideFromCorner() } // todo as!
        try await workspace.layoutWorkspace()
    }
    try await hideInvisibleWorkspaces()

    // Apps resize hidden windows, e.g. when the Dock is shown, apps shrink their windows to the new visible frame.
    // Restore the size while the windows are still hidden (a refresh session is scheduled for that a moment after
    // the Dock is shown), so that the windows come back already in the right size
    if isDockSettledForHiddenWindowsResize {
        for workspace in Workspace.all where !workspace.isVisible {
            guard let monitor = workspace.nodeMonitorInfo else { continue }
            let corner = monitorToOptimalHideCorner[monitor.rect.topLeftCorner] ?? .bottomRightCorner
            for window in workspace.allLeafWindowsRecursive {
                _ = try await (window as! MacWindow).restoreSizeInCorner(corner, isBackground: true) // todo as!
            }
        }
    }
}

@MainActor
private func normalizeContainers() {
    // Can't do it only for visible workspace because most of the commands support --window-id and --workspace flags
    for workspace in Workspace.all {
        workspace.normalizeContainers()
    }
}
