import ArgumentParser
import Foundation
import DeduperKit

struct Purge: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Permanently delete quarantined files."
    )

    @Argument(help: "Transaction ID of the quarantine to purge.")
    var transactionId: String

    func run() async throws {
        guard let uuid = UUID(uuidString: transactionId) else {
            throw ValidationError(
                "Invalid transaction ID: \(transactionId)"
            )
        }

        let merger = MergeService()
        let transactions = try merger.listTransactions()

        guard let transaction = transactions.first(where: {
            $0.id == uuid
        }) else {
            throw ValidationError(
                "Transaction not found: \(uuid.uuidString)\n"
                + "Run 'deduper undo --list' to see transactions."
            )
        }

        guard transaction.mode == .quarantine else {
            throw ValidationError(
                "Transaction \(uuid.uuidString) used OS Trash, "
                + "not quarantine. Empty Trash manually."
            )
        }

        guard transaction.status.isStatusUndoEligible else {
            let reason = transaction.status == .undone
                ? "undone" : "purged"
            throw ValidationError(
                "Transaction \(uuid.uuidString) has already"
                + " been \(reason) and cannot be purged."
            )
        }

        print(
            "Permanently deleting \(transaction.filesMoved)"
            + " quarantined file(s)..."
        )
        let deleted = try merger.purge(transaction: transaction)
        try merger.markPurged(transaction: transaction)

        print("Deleted \(deleted) file(s).")
    }
}
