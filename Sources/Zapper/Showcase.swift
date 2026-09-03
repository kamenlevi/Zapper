import Foundation

enum Showcase {
    /// True only while rendering a screenshot offscreen. AppKit-backed
    /// controls (Slider, Menu) come out as placeholder blocks under
    /// ImageRenderer, so static stand-ins are drawn in their place.
    static var isRendering = false
}
