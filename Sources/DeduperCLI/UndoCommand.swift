import ArgumentParser
import Foundation
import DeduperKit

struct Undo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Undo a merge by restoring trashed files."
    )

    @Argument(
        help: "Transaction ID to undo. Omit to list transactions."
    )
    var transactionId: String?

    @Flag(name: .long, help: "List recent merge transactions.")
    var list = false

    func run() async throws {
        let merger = MergeService()

        if list || transactionId == nil {
            try printTransactionList(merger: merger)
            return
        }

        guard let idStr = transactionId,
              let uuid = UUID(uuidString: idStr) else {
            throw ValidationError(
                "Invalid transaction ID: \(transactionId ?? "")"
            )
        }

        let transactions = try merger.listTransactions()
        guard let transaction = transactions.first(where: {
            $0.id == uuid
        }) else {
            throw ValidationError(
                "Transaction not found: \(uuid.uuidString)\n"
                + "Run 'deduper undo --list' to see transactions."
            )
        }

        guard transaction.status.isStatusUndoEligible else {
            let reason = transaction.status == .undone
                ? "undone" : "purged"
            throw ValidationError(
                "Transaction \(uuid.uuidString) has already"
                + " been \(reason)."
            )
        }

        print("Restoring \(transaction.filesMoved) file(s)...")
        let failures = merger.undo(transaction: transaction)

        if failures.isEmpty {
            try merger.markUndone(transaction: transaction)
            print("All files restored successfully.")
        } else {
            let restored = transaction.filesMoved - failures.count
            print("Restored \(restored) file(s).")
            print("\(failures.count) failure(s):")
            for failure in failures {
                print("  \(failure)")
            }
        }
    }

    private func printTransactionList(
        merger: MergeService
    ) throws {
        let transactions = try merger.listTransactions()

        if transactions.isEmpty {
            print("No merge transactions found.")
            return
        }

        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .short

        print(
            "TRANSACTION ID".padding(toLength: 36, withPad: " ", startingAt: 0)
            + "  " + "DATE".padding(toLength: 16, withPad: " ", startingAt: 0)
            + "  " + "MOVED".padding(toLength: 6, withPad: " ", startingAt: 0)
            + "  " + "ERRORS".padding(toLength: 6, withPad: " ", startingAt: 0)
            + "  MODE"
        )
        print(String(repeating: "-", count: 80))

        for t in transactions {
            let id = t.id.uuidString.padding(
                toLength: 36, withPad: " ", startingAt: 0
            )
            let date = df.string(from: t.date).padding(
                toLength: 16, withPad: " ", startingAt: 0
            )
            let moved = String(t.filesMoved).padding(
                toLength: 6, withPad: " ", startingAt: 0
            )
            let errors = String(t.errorCount).padding(
                toLength: 6, withPad: " ", startingAt: 0
            )
            print("\(id)  \(date)  \(moved)  \(errors)  \(t.mode.rawValue)")
        }

        print()
        print(
            "Run 'deduper undo <transaction-id>' to restore files."
        )
    }
}
