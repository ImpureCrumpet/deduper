import SwiftUI

/// Comparison display mode.
public enum ComparisonMode: String, CaseIterable {
    case split = "Split"
    case single = "Single"
}

/// Container view: split image comparison + member carousel.
/// Supports split (side-by-side slider) and single (one at a time)
/// display modes, toggled via a segmented control.
public struct ComparisonView: View {
    public let members: [MemberDetail]

    @State private var selectedMemberId: String?
    @State private var mode: ComparisonMode = .split

    public init(members: [MemberDetail]) {
        self.members = members
    }

    private var keeper: MemberDetail? {
        members.first(where: \.isKeeper)
    }

    private var nonKeepers: [MemberDetail] {
        members.filter { !$0.isKeeper }
    }

    private var selectedMember: MemberDetail? {
        members.first { $0.id == selectedMemberId }
    }

    public var body: some View {
        VStack(spacing: 12) {
            // Mode toggle
            HStack {
                Spacer()
                Picker("Mode", selection: $mode) {
                    ForEach(ComparisonMode.allCases, id: \.self) {
                        Text($0.rawValue).tag($0)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .labelsHidden()
            }
            .padding(.horizontal, 4)

            // Comparison area
            switch mode {
            case .split:
                splitView
            case .single:
                singleView
            }

            // Carousel (both modes — selects active member)
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

    @ViewBuilder
    private var splitView: some View {
        if let keeper, let selected = selectedMember {
            SplitImageComparison(
                keeperPath: keeper.path,
                comparisonPath: selected.path,
                keeperLabel: "Keeper: \(keeper.fileName)",
                comparisonLabel: selected.fileName
            )
            .frame(minHeight: 400)
        } else {
            placeholderView
        }
    }

    @ViewBuilder
    private var singleView: some View {
        if let selected = selectedMember ?? keeper {
            SingleImageView(member: selected)
                .frame(minHeight: 400)
        } else {
            placeholderView
        }
    }

    private var placeholderView: some View {
        Text("Select a member to compare")
            .foregroundStyle(.secondary)
            .frame(height: 300)
            .frame(maxWidth: .infinity)
    }
}
