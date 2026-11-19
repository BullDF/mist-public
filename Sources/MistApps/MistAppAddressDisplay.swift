import AppKit

struct MistAppAddressDisplay: Equatable {
    let icon: MistAppIcon
    let name: String
    let title: String?

    @MainActor static func resolve(_ tab: Tab?) -> Self? {
        guard let tab, let address = tab.appAddress else { return nil }
        if let app = MistApps.app(address.app) {
            return Self(icon: app.addressIcon(address.instance), name: app.id.name, title: app.addressTitle(address.instance))
        }
        return nil
    }

    func attributedString(primary: NSColor, separator: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        if let image = NSImage(named: icon.asset)?.copy() as? NSImage {
            if icon.isTemplate {
                image.lockFocus()
                primary.setFill()
                NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
                image.unlockFocus()
                image.isTemplate = false
            }
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = NSRect(x: 0, y: -2, width: 14 * image.size.width / max(1, image.size.height), height: 14)
            result.append(NSAttributedString(attachment: attachment))
        }
        result.append(NSAttributedString(string: " " + name, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: primary,
        ]))
        if let title {
            result.append(NSAttributedString(string: " "))
            let divider = NSTextAttachment()
            divider.image = NSImage(size: NSSize(width: 1, height: 14), flipped: false) { rect in
                separator.setFill()
                rect.fill()
                return true
            }
            divider.bounds = NSRect(x: 0, y: -2, width: 1, height: 14)
            result.append(NSAttributedString(attachment: divider))
            result.append(NSAttributedString(string: " " + title, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: primary]))
        }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        result.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: result.length))
        return result
    }
}
