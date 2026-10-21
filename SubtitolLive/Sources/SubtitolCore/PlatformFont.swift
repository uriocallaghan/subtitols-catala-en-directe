#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

/// The font class of the platform: measurement and drawing both go through it.
public typealias PlatformFont = NSFont
#else
import UIKit

/// The font class of the platform: measurement and drawing both go through it.
public typealias PlatformFont = UIFont
#endif
