import AppKit

final class PromptController: NSObject, NSApplicationDelegate {
    private var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let panel = NSPanel(
            contentRect: screenFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.58)
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        window = panel

        let container = NSView(
            frame: NSRect(origin: .zero, size: screenFrame.size)
        )
        panel.contentView = container

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        let title = NSTextField(labelWithString: "Move app windows to workspace")
        title.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        title.textColor = .white
        title.alignment = .center
        stack.addArrangedSubview(title)

        let hint = NSTextField(labelWithString: "Press 1-9 to move, Esc to cancel")
        hint.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        hint.textColor = NSColor.white.withAlphaComponent(0.68)
        hint.alignment = .center
        stack.addArrangedSubview(hint)

        let keys = NSTextField(labelWithString: "1  2  3  4  5  6  7  8  9")
        keys.font = NSFont.monospacedDigitSystemFont(ofSize: 28, weight: .medium)
        keys.textColor = .white
        keys.alignment = .center
        stack.addArrangedSubview(keys)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: -40),
        ])

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.cancel()
                return nil
            }
            if let chars = event.charactersIgnoringModifiers,
               let target = chars.first,
               "123456789".contains(target) {
                self?.submit(String(target))
                return nil
            }
            return event
        }
    }

    private func submit(_ value: String) {
        print(value)
        fflush(stdout)
        NSApp.terminate(nil)
    }

    private func cancel() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = PromptController()
app.delegate = delegate
app.run()
