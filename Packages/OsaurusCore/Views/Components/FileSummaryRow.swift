//
//  FileSummaryRow.swift
//  osaurus
//
//  A compact chip row summarizing file mutations in a completed turn.
//

import AppKit
import SwiftUI

struct FileSummaryRow: View {
    let files: [FileSummaryItem]

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(headerLabel)
                .font(theme.font(size: 12, weight: .medium))
                .foregroundColor(theme.tertiaryText)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(files, id: \.path) { file in
                        FileChip(file: file)
                    }
                }
            }
        }
    }

    private var headerLabel: String {
        let created = files.filter { $0.operation == .created }.count
        let modified = files.filter { $0.operation == .modified }.count
        let deleted = files.filter { $0.operation == .deleted }.count
        var parts: [String] = []
        if created > 0 { parts.append("\(created) created") }
        if modified > 0 { parts.append("\(modified) modified") }
        if deleted > 0 { parts.append("\(deleted) deleted") }
        return parts.joined(separator: " · ")
    }
}

private struct FileChip: View {
    let file: FileSummaryItem

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    private var icon: String {
        switch file.operation {
        case .created: return "doc.badge.plus"
        case .modified: return "pencil.line"
        case .deleted: return "trash"
        }
    }

    private var filename: String {
        URL(fileURLWithPath: file.path).lastPathComponent
    }

    var body: some View {
        Button(action: openInFinder) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
                Text(filename)
                    .font(theme.font(size: 12, weight: .medium).monospaced())
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isHovered ? theme.secondaryBackground : theme.secondaryBackground.opacity(0.6))
            )
            .scaleEffect(isHovered ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { h in
            isHovered = h
            if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .help(file.path)
    }

    private func openInFinder() {
        NSWorkspace.shared.selectFile(file.path, inFileViewerRootedAtPath: "")
    }
}
