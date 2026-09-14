import CoreGraphics

/// Geometry is in AppKit screen points, including displays with negative origins.
public enum AIBarPopoverLayout {
    public static let preferredSize = CGSize(width: 620, height: 450)
    public static let margin: CGFloat = 12

    public static func contentSize(in visibleFrame: CGRect, chrome: CGSize) -> CGSize {
        CGSize(
            width: max(1, min(preferredSize.width, visibleFrame.width - 2 * margin - chrome.width)),
            height: max(1, min(preferredSize.height, visibleFrame.height - 2 * margin - chrome.height))
        )
    }

    public static func origin(for frame: CGRect, in visibleFrame: CGRect) -> CGPoint {
        let bounds = visibleFrame.insetBy(dx: margin, dy: margin)
        return CGPoint(
            x: max(bounds.minX, min(frame.minX, bounds.maxX - frame.width)),
            y: max(bounds.minY, min(frame.minY, bounds.maxY - frame.height))
        )
    }
}
