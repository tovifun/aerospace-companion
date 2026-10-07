import AppKit

enum SwitcherFeedbackTone {
    case neutral, progress, success, warning

    var color: NSColor {
        switch self {
        case .neutral: return .secondaryLabelColor
        case .progress: return .controlAccentColor
        case .success: return .systemGreen
        case .warning: return .systemOrange
        }
    }

    var symbol: String {
        switch self {
        case .neutral: return "keyboard"
        case .progress: return "hourglass"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.circle"
        }
    }
}

struct SwitcherActionFeedback {
    let message: String
    let tone: SwitcherFeedbackTone
}

final class SwitcherActionFeedbackView: NSView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        let separator = NSBox()
        separator.boxType = .separator
        for view in [separator, icon, label] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        label.font = NSFont.systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 2),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            label.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ feedback: SwitcherActionFeedback) {
        icon.image = NSImage(systemSymbolName: feedback.tone.symbol, accessibilityDescription: nil)
        icon.contentTintColor = feedback.tone.color
        label.stringValue = feedback.message
        label.textColor = .secondaryLabelColor
        toolTip = feedback.message
        setAccessibilityLabel(feedback.message)
    }
}
