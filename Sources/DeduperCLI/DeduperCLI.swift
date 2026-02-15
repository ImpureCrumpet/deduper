import ArgumentParser

@main
struct DeduperCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "deduper",
        abstract: "Find and manage duplicate media files.",
        subcommands: [
            Scan.self, Merge.self, History.self,
            Show.self, Undo.self, DeleteSession.self,
            Purge.self
        ],
        defaultSubcommand: Scan.self
    )
}
