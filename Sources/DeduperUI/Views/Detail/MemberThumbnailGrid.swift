import SwiftUI

/// N-up thumbnail grid showing all members of a duplicate group.
public struct MemberThumbnailGrid: View {
    public let members: [MemberDetail]

    public init(members: [MemberDetail]) {
        self.members = members
    }

    private let columns = [
        GridItem(.adaptive(minimum: 220, maximum: 280), spacing: 12)
    ]

    public var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(members) { member in
                MemberCard(member: member)
            }
        }
    }
}
