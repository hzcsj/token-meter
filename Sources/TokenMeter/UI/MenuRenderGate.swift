final class MenuRenderGate {
    private(set) var isTrackingMenu = false
    private var hasDeferredRender = false

    func menuWillOpen() {
        isTrackingMenu = true
    }

    func requestRender() -> Bool {
        guard !isTrackingMenu else {
            hasDeferredRender = true
            return false
        }
        return true
    }

    func menuDidClose() -> Bool {
        isTrackingMenu = false
        guard hasDeferredRender else { return false }
        hasDeferredRender = false
        return true
    }
}
