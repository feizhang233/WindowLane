import CoreGraphics

public enum WindowRestorationGeometry {
    /// Returns a temporary origin where the original size fits, without changing
    /// the final requested frame. Both rectangles must use the same coordinates.
    public static func stagingOrigin(for target: CGRect, visibleFrame: CGRect) -> CGPoint? {
        let values = [target.origin.x, target.origin.y, target.width, target.height,
                      visibleFrame.origin.x, visibleFrame.origin.y, visibleFrame.width, visibleFrame.height]
        guard values.allSatisfy({ $0.isFinite }),
              target.width > 0, target.height > 0, visibleFrame.width > 0, visibleFrame.height > 0,
              target.width <= visibleFrame.width, target.height <= visibleFrame.height else { return nil }
        guard target.minX < visibleFrame.minX || target.minY < visibleFrame.minY
                || target.maxX > visibleFrame.maxX || target.maxY > visibleFrame.maxY else { return nil }
        return CGPoint(x: min(max(target.minX, visibleFrame.minX), visibleFrame.maxX - target.width),
                       y: min(max(target.minY, visibleFrame.minY), visibleFrame.maxY - target.height))
    }
}
