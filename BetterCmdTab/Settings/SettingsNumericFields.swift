import AppKit
import BetterSettings

/// Shared building blocks for the "slider + editable value" rows used by the
/// Behavior and Appearance panes, so field styling and input parsing stay in
/// one place.
extension SettingsTabViewController {

    /// Small right-aligned integer field that commits on Return and on
    /// end-editing.
    func configureIntegerField(_ field: NSTextField,
                               action: Selector,
                               accessibilityLabel: String) {
        field.controlSize = .small
        field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        field.alignment = .right
        field.target = self
        field.action = action
        field.cell?.sendsActionOnEndEditing = true
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentHuggingPriority(.required, for: .horizontal)
        field.setAccessibilityLabel(accessibilityLabel)
        field.widthAnchor.constraint(equalToConstant: 52).isActive = true
    }

    /// The field with a trailing unit label ("ms", "%").
    func unitInput(for field: NSTextField, unit: String) -> NSStackView {
        let unitLabel = NSTextField(labelWithString: unit)
        unitLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        unitLabel.textColor = .secondaryLabelColor
        unitLabel.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [field, unitLabel])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        return stack
    }

    /// Parses the committed field text as an integer, tolerating surrounding
    /// whitespace and localized digits/grouping ("1 000", "٨٠"). Beeps and
    /// returns nil when the text isn't a number, so callers revert the field
    /// to the stored value.
    func committedInteger(from sender: NSTextField) -> Int? {
        let trimmed = sender.stringValue.trimmingCharacters(in: .whitespaces)
        if let value = Int(trimmed) { return value }
        if let number = Self.localizedIntegerFormatter.number(from: trimmed) {
            return number.intValue
        }
        NSSound.beep()
        return nil
    }

    private static let localizedIntegerFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.isLenient = true
        return formatter
    }()
}
