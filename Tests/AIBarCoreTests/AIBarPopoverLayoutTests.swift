import CoreGraphics
import Testing
@testable import AIBarCore

@Test func popoverKeepsNormalSize() {
    #expect(AIBarPopoverLayout.contentSize(
        in: CGRect(x: 0, y: 40, width: 1440, height: 835),
        chrome: CGSize(width: 0, height: 24)
    ) == CGSize(width: 620, height: 450))
}

@Test func popoverFitsSmallScreenIncludingChrome() {
    let screen = CGRect(x: -500, y: -300, width: 500, height: 400)
    let chrome = CGSize(width: 4, height: 24)
    let content = AIBarPopoverLayout.contentSize(in: screen, chrome: chrome)
    #expect(content == CGSize(width: 472, height: 352))
    let proposed = CGRect(x: -100, y: -500, width: content.width + chrome.width, height: content.height + chrome.height)
    let origin = AIBarPopoverLayout.origin(for: proposed, in: screen)
    #expect(screen.insetBy(dx: 12, dy: 12).contains(CGRect(origin: origin, size: proposed.size)))
}

@Test func popoverCorrectsBothHorizontalEdges() {
    let screen = CGRect(x: 0, y: 40, width: 1440, height: 835)
    let left = CGRect(x: -300, y: 350, width: 620, height: 474)
    let right = CGRect(x: 1200, y: 350, width: 620, height: 474)
    #expect(AIBarPopoverLayout.origin(for: left, in: screen) == CGPoint(x: 12, y: 350))
    #expect(AIBarPopoverLayout.origin(for: right, in: screen) == CGPoint(x: 808, y: 350))
}

@Test func popoverUsesTheSelectedDisplaysOriginAndUsableArea() {
    let screen = CGRect(x: -1920, y: 80, width: 1920, height: 980)
    let proposed = CGRect(x: -200, y: 950, width: 620, height: 474)
    #expect(AIBarPopoverLayout.origin(for: proposed, in: screen) == CGPoint(x: -632, y: 574))
    let alreadyVisible = CGRect(x: -1500, y: 300, width: 620, height: 474)
    #expect(AIBarPopoverLayout.origin(for: alreadyVisible, in: screen) == alreadyVisible.origin)
}
