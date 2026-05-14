// SwiftUI view for the Hanja candidate panel.
//     Copyright (C) 2026 Seungjin Lee.

import SwiftUI

struct HanjaCandidatePanelView: View {
    private enum Layout {
        static let panelCornerRadius: CGFloat = 15
        static let rowHeight: CGFloat = 30
        static let footerHorizontalPadding: CGFloat = 9
    }

    private enum Palette {
        static let selectedCandidateBackground = Color(nsColor: .selectedContentBackgroundColor)
        static let selectedCandidateForeground = Color(nsColor: .alternateSelectedControlTextColor)
    }

    let content: ManualHanjaPanelContent
    let onSelect: ((HanjaCandidatePanelSelection) -> Void)?

    var body: some View {
        GlassEffectContainer {
            panelContent
                .padding(.horizontal, 7)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color.clear)
                .glassEffect(.regular, in: panelShape)
                .clipShape(panelShape)
                .overlay {
                    panelShape
                        .stroke(Color(nsColor: .separatorColor).opacity(0.28), lineWidth: 1)
                }
        }
    }

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Layout.panelCornerRadius, style: .continuous)
    }

    @ViewBuilder
    private var panelContent: some View {
        Group {
            switch content {
            case .candidates(let state):
                candidateContent(state)
            case .notice(let notice):
                noticeContent(notice)
            }
        }
    }

    @ViewBuilder
    private func candidateContent(_ state: HanjaCandidatePanelState) -> some View {
        if state.candidates.isEmpty {
            VStack(spacing: 4) {
                Text("후보 없음")
                    .font(.system(size: 12, weight: .medium))
                if let emptyDetail = emptyDetail(for: state), !emptyDetail.isEmpty {
                    Text(emptyDetail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 10)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(state.visibleCandidateRange, id: \.self) { index in
                        let candidate = state.candidates[index]
                        Button(action: { onSelect?(.candidate(candidate)) }) {
                            candidateRow(
                                candidate,
                                label: candidateShortcutLabel(forAbsoluteIndex: index, state: state),
                                isHighlighted: !state.highlightedIsHangul && index == state.highlightedIndex
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    if let hangulText = hangulRowText(for: state) {
                        Button(action: { onSelect?(.hangul) }) {
                            hangulRow(
                                text: hangulText,
                                label: hangulShortcutLabel(for: state),
                                isHighlighted: state.highlightedIsHangul
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(state.page + 1) / \(state.pageCount)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)

                    Text(footerText(for: state))
                        .font(.system(size: 9, weight: .regular))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, Layout.footerHorizontalPadding)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func hangulRowText(for state: HanjaCandidatePanelState) -> String? {
        let text = state.mode.manualSourceText ?? state.mode.realtimeSegmentSurface
        guard let text, !text.isEmpty else {
            return nil
        }

        return text
    }

    private func noticeContent(_ notice: ManualHanjaNoticeState) -> some View {
        VStack(spacing: 4) {
            Text(notice.message)
                .font(.system(size: 12, weight: .semibold))
                .multilineTextAlignment(.center)

            if let detail = notice.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func emptyDetail(for state: HanjaCandidatePanelState) -> String? {
        state.mode.manualSourceText ?? state.mode.realtimeSegmentSurface
    }

    private func footerText(for state: HanjaCandidatePanelState) -> String {
        if state.mode.allowsNumberedSelection {
            return "후보 선택 1-9, 0 한글. 다음 페이지 ⇥"
        }

        return "후보 이동 ↑↓, 선택 ↩. 다음 페이지 ⇥"
    }

    private func candidateShortcutLabel(forAbsoluteIndex index: Int, state: HanjaCandidatePanelState) -> String {
        guard state.mode.allowsNumberedSelection else {
            return ""
        }

        return state.pageNumberLabel(forAbsoluteIndex: index)
    }

    private func hangulShortcutLabel(for state: HanjaCandidatePanelState) -> String {
        state.mode.allowsNumberedSelection ? "0" : ""
    }

    private func hangulRow(text: String, label: String, isHighlighted: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .regular, design: .default))
                .foregroundStyle(isHighlighted ? Palette.selectedCandidateForeground : Color.secondary)
                .frame(width: 18, alignment: .trailing)

            Text(text)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(isHighlighted ? Palette.selectedCandidateForeground : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .layoutPriority(1)

            Spacer(minLength: 4)

            Text("한글")
                .font(.system(size: 11, weight: .regular, design: .default))
                .foregroundStyle(isHighlighted ? Palette.selectedCandidateForeground : Color.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Layout.rowHeight)
        .background {
            if isHighlighted {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Palette.selectedCandidateBackground)
            }
        }
        .contentShape(Rectangle())
    }

    private func candidateRow(
        _ candidate: HanjaCandidate,
        label: String,
        isHighlighted: Bool
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .regular, design: .default))
                .foregroundStyle(isHighlighted ? Palette.selectedCandidateForeground : Color.secondary)
                .frame(width: 18, alignment: .trailing)

            Text(candidate.value)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(isHighlighted ? Palette.selectedCandidateForeground : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .layoutPriority(1)

            if candidate.source == .userDefined {
                Text("★")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isHighlighted ? Palette.selectedCandidateForeground : Color.accentColor)
            }

            Spacer(minLength: 4)

            Text(candidate.comment)
                .font(.system(size: 11, weight: .regular, design: .default))
                .foregroundStyle(isHighlighted ? Palette.selectedCandidateForeground : Color.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Layout.rowHeight)
        .background {
            if isHighlighted {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Palette.selectedCandidateBackground)
            }
        }
        .contentShape(Rectangle())
    }
}

#if DEBUG
private let hanjaCandidatePanelPreviewSize = CGSize(width: 176, height: 369)

private struct HanjaCandidatePanelPreviewContainer: View {
    let content: ManualHanjaPanelContent
    let size: CGSize

    var body: some View {
        HanjaCandidatePanelView(content: content, onSelect: nil)
            .frame(width: size.width, height: size.height)
            .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
            .padding(28)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

private extension ManualHanjaTarget {
    static let preview = ManualHanjaTarget(
        sourceText: "대한민국",
        replacementRange: NSRange(location: 0, length: 4),
        anchorRange: NSRange(location: 4, length: 0)
    )

    static let emptyPreview = ManualHanjaTarget(
        sourceText: "없는말",
        replacementRange: NSRange(location: 0, length: 3),
        anchorRange: NSRange(location: 3, length: 0)
    )
}

private extension HanjaCandidatePanelState {
    static let preview = HanjaCandidatePanelState(
        mode: .manual(
            sourceText: ManualHanjaTarget.preview.sourceText,
            replacementRange: ManualHanjaTarget.preview.replacementRange
        ),
        anchorRange: ManualHanjaTarget.preview.anchorRange,
        candidates: HanjaCandidate.previewSamples
    )

    static let longPreview = HanjaCandidatePanelState(
        mode: .manual(
            sourceText: ManualHanjaTarget.preview.sourceText,
            replacementRange: ManualHanjaTarget.preview.replacementRange
        ),
        anchorRange: ManualHanjaTarget.preview.anchorRange,
        candidates: HanjaCandidate.previewSamples + HanjaCandidate.morePreviewSamples
    )

    static let emptyPreview = HanjaCandidatePanelState(
        mode: .manual(
            sourceText: ManualHanjaTarget.emptyPreview.sourceText,
            replacementRange: ManualHanjaTarget.emptyPreview.replacementRange
        ),
        anchorRange: ManualHanjaTarget.emptyPreview.anchorRange,
        candidates: []
    )
}

private extension ManualHanjaNoticeState {
    static let preview = ManualHanjaNoticeState(
        message: "한자 사전 준비중",
        detail: "잠시 후 다시 시도해 주세요.",
        anchorRange: NSRange(location: 0, length: 0)
    )
}

private extension HanjaCandidate {
    static let previewSamples: [HanjaCandidate] = [
        preview(reading: "대한민국", value: "大韓民國", comment: "나라 이름", usageCount: 21, baseRank: 0),
        preview(reading: "대한", value: "大韓", comment: "대한", usageCount: 8, baseRank: 1),
        preview(reading: "민국", value: "民國", comment: "민국", usageCount: 3, baseRank: 2),
        preview(reading: "한국", value: "韓國", comment: "한국", usageCount: 1, baseRank: 3),
        preview(reading: "한", value: "韓", comment: "성씨/나라", usageCount: 0, baseRank: 4),
        preview(reading: "대", value: "大", comment: "클 대", usageCount: 0, baseRank: 5),
        preview(reading: "민", value: "民", comment: "백성 민", usageCount: 0, baseRank: 6),
        preview(reading: "국", value: "國", comment: "나라 국", usageCount: 0, baseRank: 7),
    ]

    static let morePreviewSamples: [HanjaCandidate] = [
        preview(reading: "대한민국", value: "對韓民國", comment: "", usageCount: 0, baseRank: 8),
        preview(reading: "대한민국", value: "臺韓民國", comment: "", usageCount: 0, baseRank: 9),
        preview(reading: "대한민국", value: "大限民國", comment: "", usageCount: 0, baseRank: 10),
        preview(reading: "대한민국", value: "大漢民國", comment: "", usageCount: 0, baseRank: 11),
    ]

    private static func preview(
        reading: String,
        value: String,
        comment: String,
        usageCount: Int,
        baseRank: Int
    ) -> HanjaCandidate {
        HanjaCandidate(
            reading: reading,
            value: value,
            comment: comment,
            source: .system,
            usageCount: usageCount,
            frequency: 0,
            baseRank: baseRank
        )
    }
}

#Preview("후보 목록") {
    HanjaCandidatePanelPreviewContainer(
        content: .candidates(.preview),
        size: hanjaCandidatePanelPreviewSize
    )
}

#Preview("긴 후보 목록") {
    HanjaCandidatePanelPreviewContainer(
        content: .candidates(.longPreview),
        size: hanjaCandidatePanelPreviewSize
    )
}

#Preview("후보 없음") {
    HanjaCandidatePanelPreviewContainer(
        content: .candidates(.emptyPreview),
        size: CGSize(width: 176, height: 96)
    )
}

#Preview("안내") {
    HanjaCandidatePanelPreviewContainer(
        content: .notice(.preview),
        size: CGSize(width: 176, height: 76)
    )
}
#endif
