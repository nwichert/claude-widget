import ApplicationServices

/// Small wrappers over the Accessibility API, shared by the Claude reader and the screen observer.
enum AX {
    static func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }

    static func children(_ e: AXUIElement) -> [AXUIElement] {
        (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    static func label(_ e: AXUIElement) -> String {
        for name in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            if let s = attr(e, name) as? String, !s.isEmpty { return s }
        }
        return ""
    }

    /// Depth-first search for the first element matching a test, giving up after `budget` elements.
    static func find(in e: AXUIElement, budget: Int, maxDepth: Int = 40, where test: (AXUIElement) -> Bool) -> AXUIElement? {
        var left = budget
        func search(_ e: AXUIElement, _ depth: Int) -> AXUIElement? {
            left -= 1
            guard left > 0, depth < maxDepth else { return nil }
            if test(e) { return e }
            for child in children(e) {
                if let found = search(child, depth + 1) { return found }
            }
            return nil
        }
        return search(e, 0)
    }
}
