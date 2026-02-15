import SwiftUI
import AppKit

/// Horizontal carousel for selecting which member to compare
/// against the keeper.
public struct ComparisonCarousel: View {
    public let members: [MemberDetail]
    @Binding public var selectedMemberId: String?

    public init(
        members: [MemberDetail],
        selectedMemberId: Binding<String?>
    ) {
        self.members = members
        self._selectedMemberId = selectedMemberId
    }

    private var nonKeepers: [MemberDetail] {
        members.filter { !$0.isKeeper }
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(nonKeepers) { member in
                    carouselItem(member)
                        .onTapGesture {
                            selectedMemberId = member.id
                        }
                }
            }
            .padding(.horizontal)
        }
        .frame(height: 110)
    }

    private func carouselItem(
        _ member: MemberDetail
    ) -> some View {
        VStack(spacing: 4) {
            thumbnailView(member)
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            Text(member.fileName)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 80)
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    selectedMemberId == member.id
                        ? Color.accentColor : Color.clear,
                    lineWidth: 2
                )
        )
    }

    @ViewBuilder
    private func thumbnailView(
        _ member: MemberDetail
    ) -> some View {
        if let data = member.thumbnailData,
           let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Image(systemName: "photo")
                .font(.title2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.gray.opacity(0.1))
        }
    }
}
