import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The shortcut that shows or hides the window from anywhere, in each of the
/// forms the code needs it. Keep them in step.
///
/// Why Control-Command: macOS 15 refuses system-wide shortcuts whose only
/// modifiers are Option or Option-Shift, and Control-Option is VoiceOver's own
/// modifier, with VO-M its "go to the menu bar".
///
/// The key is a position, not a letter: on layouts that move M, French AZERTY
/// for one, it is whichever key sits where M does on a US keyboard.
enum ToggleShortcut {
    /// Carbon's terms, for registering it.
    static let keyCode = kVK_ANSI_M
    static let carbonModifiers = controlKey | cmdKey
    /// AppKit's, for showing it against the paw's menu item.
    static let keyEquivalent = "m"
    static let modifierFlags: NSEvent.ModifierFlags = [.control, .command]
    /// SwiftUI's, for showing it against the window's menu item.
    static let swiftUIKey: KeyEquivalent = "m"
    static let swiftUIModifiers: SwiftUI.EventModifiers = [.control, .command]
    /// How tooltips spell it.
    static let display = "⌃⌘M"
}

/// A system-wide keyboard shortcut.
///
/// This goes through the Carbon hot key API rather than an NSEvent monitor
/// because it is the one route to a global shortcut that needs no
/// Accessibility permission, and the system swallows the keystroke, so the
/// app you are typing into never sees it.
final class HotKey {

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    /// Fails only if the system refuses the registration, so success does not
    /// promise the keystroke. While this is registered, other apps' own
    /// shortcuts on the same keys stop working. Another app's hot key on them
    /// fires alongside this one, unless that app registered it as exclusive:
    /// then only that app hears it, and nothing here can tell.
    init?(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        self.action = action

        var pressed = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        // The handler is a C function pointer and cannot capture anything, so
        // it finds this object through the user-data pointer. Unretained is
        // safe: deinit removes the handler before the object goes away.
        let installed = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData = userData else { return OSStatus(eventNotHandledErr) }
                Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue().action()
                return noErr
            },
            1, &pressed,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef)
        guard installed == noErr else { return nil }

        let id = EventHotKeyID(signature: OSType(0x4D4B_5254), id: 1)  // 'MKRT'
        let registered = RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers), id,
            GetApplicationEventTarget(), 0, &hotKeyRef)
        guard registered == noErr else {
            // Tidy up here rather than trusting deinit to run for an init
            // that failed.
            if let handlerRef = handlerRef { RemoveEventHandler(handlerRef) }
            handlerRef = nil
            return nil
        }
    }

    deinit {
        if let hotKeyRef = hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef = handlerRef { RemoveEventHandler(handlerRef) }
    }
}
