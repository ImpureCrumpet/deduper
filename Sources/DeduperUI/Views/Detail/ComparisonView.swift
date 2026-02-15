import SwiftUI

/// Container view: split image comparison + member carousel.
public struct ComparisonView: View {
    public let members: [MemberDetail]

    @State private var selectedMemberId: String?

    public init(members: [MemberDetail]) {
        self.members = members
    }

    private var keeper: MemberDetail? {
        members.first(where: \.isKeeper)
    }

    private var nonKeepers: [MemberDetail] {
        members.filter { !$0.isKeeper }
    }

    public var body: some View {
        VStack(spacing: 12) {
            if let keeper,
               let selected = members.first(
                   where: { $0.id == selectedMemberId }
               ) {
                SplitImageComparison(
                    keeperPath: keeper.path,
                    comparisonPath: selected.path,
                    keeperLabel: "Keeper: \(keeper.fileName)",
                    comparisonLabel: selected.fileName
                )
                .frame(minHeight: 400)
            } else {
                Text("Select a member to compare")
                    .foregroundStyle(.secondary)
                    .frame(height: 300)
                    .frame(maxWidth: .infinity)
            }

            ComparisonCarousel(
                members: members,
                selectedMemberId: $selectedMemberId
            )
        }
        .onAppear {
            if selectedMemberId == nil {
                selectedMemberId = nonKeepers.first?.id
            }
        }
    }
}
