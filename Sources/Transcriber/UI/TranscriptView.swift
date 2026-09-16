import AppKit
import SwiftUI

/// 单源字幕流:final 固化(正常色)+ partial 灰色可变,自动滚动到底。
/// 文本区用 NSTextView:整个转写是一段连续文本,可任意跨句拖选复制
/// (SwiftUI 多个 Text 的选区各自独立,无法跨句选择)。
struct TranscriptView: View {
    let title: String
    let finals: [TranscriptLine]
    let partial: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    copyAll()
                } label: {
                    Label("复制全部", systemImage: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(finals.isEmpty && partial.isEmpty)
            }

            SelectableTranscriptText(finals: finals, partial: partial)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func copyAll() {
        var text = finals.map(\.text).joined(separator: "\n")
        if !partial.isEmpty {
            text += (text.isEmpty ? "" : "\n") + partial
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// NSTextView 包装:增量追加 final、原地替换尾部 partial,
/// 用户停在底部时自动跟随滚动,往上翻阅时不打扰。
struct SelectableTranscriptText: NSViewRepresentable {
    let finals: [TranscriptLine]
    let partial: String

    final class Coordinator {
        var finalCount = 0
        var partialLength = 0
        var lastPartial = ""
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 10)
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView,
            let storage = textView.textStorage
        else { return }
        let c = context.coordinator

        // 无变化时直接返回(电平等无关状态刷新会频繁触发 update)
        if finals.count == c.finalCount, partial == c.lastPartial { return }

        let wasAtBottom = isNearBottom(scroll)

        // 新会话(final 数变小)→ 整体重建
        if finals.count < c.finalCount {
            storage.setAttributedString(NSAttributedString(string: ""))
            c.finalCount = 0
            c.partialLength = 0
        }

        // 删除旧 partial(始终位于文本末尾)
        if c.partialLength > 0 {
            storage.deleteCharacters(
                in: NSRange(location: storage.length - c.partialLength, length: c.partialLength))
            c.partialLength = 0
        }

        // 增量追加新 final
        while c.finalCount < finals.count {
            storage.append(Self.attributed(finals[c.finalCount].text + "\n", partial: false))
            c.finalCount += 1
        }

        // 追加当前 partial
        if !partial.isEmpty {
            let attr = Self.attributed(partial, partial: true)
            storage.append(attr)
            c.partialLength = attr.length
        }
        c.lastPartial = partial

        if wasAtBottom {
            textView.scrollToEndOfDocument(nil)
        }
    }

    private func isNearBottom(_ scroll: NSScrollView) -> Bool {
        guard let doc = scroll.documentView else { return true }
        return scroll.contentView.bounds.maxY >= doc.frame.height - 60
    }

    private static func attributed(_ text: String, partial: Bool) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 8
        return NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: partial
                    ? NSColor.secondaryLabelColor : NSColor.labelColor,
                .paragraphStyle: paragraph,
            ])
    }
}
