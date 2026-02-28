//
//  UserMessageCardView.swift
//  osaurus
//
//  A right-aligned user message bubble with dark background and thin border.
//  Compact width (fits content), similar to Claude.ai chat bubble style.
//

import AppKit
import SwiftUI

// MARK: - Style Constants

enum UserMessageCardStyle {
    static let cornerRadius: Double = 12
    static let hasGlass: Bool = false
    static let hasShadow: Bool = false
    static let hasEdgeLight: Bool = false
    static let backgroundTokenName: String = "primaryBackground"
}

// MARK: - UserMessageCardView

struct UserMessageCardView: View {
    let text: String
    let images: [Data]
    let turnId: UUID
    let isTurnHovered: Bool
    let width: CGFloat

    // Action callbacks
    var onCopy: ((UUID) -> Void)?
    var onEdit: ((UUID) -> Void)?

    // Inline editing state
    var editingTurnId: UUID?
    var editText: Binding<String>?
    var onConfirmEdit: (() -> Void)?
    var onCancelEdit: (() -> Void)?

    @Environment(\.theme) private var theme

    private var isEditing: Bool {
        editingTurnId == turnId
    }

    // MARK: - Body

    var body: some View {
        if isEditing {
            editingBubble
        } else {
            compactBubble
        }
    }

    /// Compact right-aligned bubble (Claude.ai style) — hugs text content.
    private var compactBubble: some View {
        VStack(alignment: .trailing, spacing: 0) {
            imageSection

            if !text.isEmpty {
                Text(text)
                    .font(theme.font(size: CGFloat(theme.bodySize), weight: .regular))
                    .foregroundColor(theme.primaryText)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: UserMessageCardStyle.cornerRadius, style: .continuous))
        .overlay(cardBorder)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// Expanded editing bubble — full width with header and edit controls.
    private var editingBubble: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.top, 12)
                .padding(.bottom, 2)
                .padding(.horizontal, 16)

            contentSection
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
        }
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: UserMessageCardStyle.cornerRadius, style: .continuous))
        .overlay(cardBorder)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("You")
                .font(theme.font(size: CGFloat(theme.captionSize) + 1, weight: .semibold))
                .foregroundColor(theme.accentColor)

            if isEditing {
                Text("Editing")
                    .font(theme.font(size: CGFloat(theme.captionSize) - 1, weight: .medium))
                    .foregroundColor(theme.accentColor.opacity(0.7))
            }

            Spacer()

            actionButtons
                .opacity(isTurnHovered || isEditing ? 1 : 0)
        }
        .frame(height: 28)
        .contentShape(Rectangle())
        .animation(theme.animationQuick(), value: isTurnHovered)
        .animation(theme.animationQuick(), value: isEditing)
    }

    // MARK: - Action Buttons

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 4) {
            if isEditing, let onCancelEdit {
                cardActionButton(icon: "xmark", help: "Cancel edit") {
                    onCancelEdit()
                }
            } else if let onEdit {
                cardActionButton(icon: "pencil", help: "Edit") {
                    onEdit(turnId)
                }
            }
            if !isEditing, let onCopy {
                cardActionButton(icon: "doc.on.doc", help: "Copy") {
                    onCopy(turnId)
                }
            }
        }
    }

    private func cardActionButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(theme.font(size: CGFloat(theme.captionSize) - 1, weight: .medium))
                .foregroundColor(theme.tertiaryText)
                .padding(6)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Image Section

    @ViewBuilder
    private var imageSection: some View {
        ForEach(Array(images.enumerated()), id: \.offset) { _, imageData in
            userImageThumbnail(imageData: imageData)
                .padding(.top, 6)
                .padding(.bottom, text.isEmpty ? 16 : 6)
        }
    }

    @ViewBuilder
    private func userImageThumbnail(imageData: Data) -> some View {
        if let nsImage = NSImage(data: imageData) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 200, maxHeight: 150)
                .clipShape(RoundedRectangle(cornerRadius: CGFloat(theme.inputCornerRadius), style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CGFloat(theme.inputCornerRadius), style: .continuous)
                        .strokeBorder(
                            theme.primaryBorder.opacity(theme.borderOpacity),
                            lineWidth: CGFloat(theme.defaultBorderWidth)
                        )
                )
        }
    }

    // MARK: - Content Section

    @ViewBuilder
    private var contentSection: some View {
        if isEditing, let editText, let onConfirmEdit, let onCancelEdit {
            UserMessageInlineEditView(
                text: editText,
                onConfirm: onConfirmEdit,
                onCancel: onCancelEdit
            )
        } else if !text.isEmpty {
            MarkdownMessageView(
                text: text,
                baseWidth: width,
                cacheKey: turnId.uuidString,
                isStreaming: false
            )
        }
    }

    // MARK: - Card Background & Border

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: UserMessageCardStyle.cornerRadius, style: .continuous)
            .fill(theme.primaryBackground)
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: UserMessageCardStyle.cornerRadius, style: .continuous)
            .strokeBorder(
                theme.primaryBorder.opacity(theme.borderOpacity + 0.15),
                lineWidth: 0.75
            )
    }
}

// MARK: - Inline Edit View (UserMessage-specific)

/// Inline editor displayed within the user message card when editing.
/// Enter submits, Shift+Enter inserts a newline.
private struct UserMessageInlineEditView: View {
    @Binding var text: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @Environment(\.theme) private var theme
    @State private var isFocused: Bool = true

    private var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            editableArea
            editActionButtons
        }
    }

    // MARK: - Editable Area

    private var editableArea: some View {
        EditableTextView(
            text: $text,
            fontSize: CGFloat(theme.bodySize),
            textColor: theme.primaryText,
            cursorColor: theme.accentColor,
            isFocused: $isFocused,
            maxHeight: 240,
            onCommit: { if !isEmpty { onConfirm() } }
        )
        .frame(minHeight: 40, maxHeight: 240)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: CGFloat(theme.inputCornerRadius), style: .continuous)
                .fill(theme.primaryBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CGFloat(theme.inputCornerRadius), style: .continuous)
                .strokeBorder(
                    theme.accentColor.opacity(theme.borderOpacity + 0.2),
                    lineWidth: CGFloat(theme.defaultBorderWidth)
                )
        )
    }

    // MARK: - Action Buttons

    private var editActionButtons: some View {
        HStack(spacing: 8) {
            Spacer()

            Button(action: onCancel) {
                Text("Cancel")
                    .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(theme.secondaryBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(
                                theme.primaryBorder.opacity(theme.borderOpacity),
                                lineWidth: CGFloat(theme.defaultBorderWidth)
                            )
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)

            Button(action: onConfirm) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(theme.font(size: CGFloat(theme.captionSize) - 1, weight: .semibold))
                    Text("Save & Regenerate")
                        .font(theme.font(size: CGFloat(theme.captionSize), weight: .semibold))
                }
                .foregroundColor(isEmpty ? theme.secondaryText : .white)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isEmpty ? theme.secondaryBackground : theme.accentColor)
                )
            }
            .buttonStyle(.plain)
            .disabled(isEmpty)
        }
    }
}
