import CryoAPI
import CryoClient

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

/// What `cryo ci status` shows, kept in `~/.cryo/ci-state.json` (0600).
public struct CIState: Codable, Sendable, Equatable {
	public struct Seen: Codable, Sendable, Equatable {
		public var job: Int
		public var repo: String
		public var name: String
		public var labels: [String]
		/// "skipped" (labels not ours) or "started".
		public var action: String
		public var at: Date
	}

	public struct Running: Codable, Sendable, Equatable {
		public var job: Int
		public var repo: String
		/// nil while the lease is still being requested.
		public var lease: String?
		public var since: Date
		/// The GitHub runner registered for the job, once there is one.
		public var runner: Int? = nil
	}

	public struct Result: Codable, Sendable, Equatable {
		public var job: Int
		public var repo: String
		/// "exit 0", "exit 1", or "error: …".
		public var conclusion: String
		public var cacheSaved: Bool
		public var finishedAt: Date

		enum CodingKeys: String, CodingKey {
			case job, repo, conclusion
			case cacheSaved = "cache_saved"
			case finishedAt = "finished_at"
		}
	}

	public var updatedAt: Date?
	/// Total jobs seen since the first run (not capped).
	public var seenCount: Int = 0
	/// The most recent `maxSeen` jobs.
	public var seen: [Seen] = []
	public var running: [Running] = []
	public var results: [Result] = []

	public static let maxSeen = 50
	public static let maxResults = 20

	enum CodingKeys: String, CodingKey {
		case updatedAt = "updated_at"
		case seenCount = "seen_count"
		case seen, running, results
	}

	public init() {}
}

public struct CIStateStore: Sendable {
	public let path: String

	public init(home: String) { path = home + "/.cryo/ci-state.json" }

	public func load() -> CIState? {
		guard let text = readTextFile(path) else { return nil }
		return try? CryoJSON.decoder().decode(CIState.self, from: Data(text.utf8))
	}

	public func save(_ state: CIState) throws {
		let slash = path.lastIndex(of: "/")!
		try makeDirs(String(path[..<slash]), mode: 0o700)
		let e = CryoJSON.encoder()
		e.outputFormatting.insert(.prettyPrinted)
		try writeAtomically(path, String(decoding: try e.encode(state), as: UTF8.self) + "\n", mode: 0o600)
	}
}

/// The text of `cryo ci status`.
public func renderCIStatus(_ s: CIState?) -> String {
	guard let s else { return "no CI state yet: `cryo ci github` has not run on this Mac\n" }
	var out = "jobs seen: \(s.seenCount)"
	let skipped = s.seen.filter { $0.action == "skipped" }.count
	if skipped > 0 { out += " (\(skipped) of the last \(s.seen.count) skipped: labels not ours)" }
	out += "\nrunning: \(s.running.count)\n"
	for r in s.running {
		out += "  \(r.repo) job \(r.job)  \(r.lease.map { "lease \($0)" } ?? "waiting for a capsule")  since \(iso(r.since))\n"
	}
	out += "last results: \(s.results.isEmpty ? "none" : "")\n"
	for r in s.results.reversed() {
		out += "  \(r.repo) job \(r.job)  \(r.conclusion)  cache \(r.cacheSaved ? "saved" : "not saved")  \(iso(r.finishedAt))\n"
	}
	return out
}

private func iso(_ d: Date) -> String {
	let e = CryoJSON.encoder()
	guard let data = try? e.encode(d) else { return "" }
	return String(decoding: data, as: UTF8.self).filter { $0 != "\"" }
}
