import CryoClient

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif
#if os(macOS)
	import Foundation
#endif

extension String {
	fileprivate func trimmingNewlines() -> String {
		var s = Substring(self)
		while let l = s.last, l == "\n" || l == "\r" { s = s.dropLast() }
		return String(s)
	}
}

/// Where `cryo ci github login` keeps the GitHub token. `GITHUB_TOKEN` in the environment wins
/// over any store; the CLI checks it first.
public protocol TokenStore: Sendable {
	/// The stored GitHub token, or nil when none is stored.
	func load() throws -> String?
	func save(_ token: String) throws
	/// Where the token is kept, for messages.
	var place: String { get }
}

/// `~/.cryo/github-token` (dir 0700, file 0600). Used on Linux and in tests; on macOS it is only
/// read as a fallback for tokens saved before the Keychain store.
public struct FileTokenStore: TokenStore {
	public let path: String
	public let dir: String

	public init(home: String) {
		self.dir = home + "/.cryo"
		self.path = home + "/.cryo/github-token"
	}

	public var place: String { path }

	public func load() throws -> String? {
		guard let text = readTextFile(path) else { return nil }
		let t = text.trimmingSpaces().trimmingNewlines()
		return t.isEmpty ? nil : t
	}

	public func save(_ token: String) throws {
		try makeDirs(dir, mode: 0o700)
		try writeSecretFile(path, token + "\n")
	}
}

#if os(macOS)
	public struct KeychainError: Error, CustomStringConvertible {
		public let description: String
		/// `status`: the exit status of `security`; 36 is errSecInteractionNotAllowed (Keychain locked).
		init(_ action: String, _ stderr: String, status: Int32 = 1) {
			// `security -i` ends with "<command>: returned <status>"; the reason is on a `security:` line.
			let lines = stderr.split(separator: "\n")
			var msg = (lines.last { $0.hasPrefix("security:") } ?? lines.last).map { String($0).trimmingSpaces() } ?? ""
			if msg.isEmpty { msg = "security failed" }
			// Over SSH the login Keychain stays locked even while the GUI session has it unlocked.
			if status == 36 || msg.contains("User interaction is not allowed") {
				msg += " (the login Keychain is locked in this session; over SSH, run `security unlock-keychain` first)"
			}
			description = "Keychain: cannot \(action) the GitHub token: \(msg)"
		}
	}

	/// A generic password in the login Keychain (service `dev.rizwan.cryo.ci`, account `github`), ci.md.
	/// The `cryo ci` LaunchAgent runs in the logged-in session, where that Keychain is unlocked.
	/// Reads fall back to `~/.cryo/github-token`; a save removes that file.
	///
	/// Written and read through `/usr/bin/security`, not the Security framework: an item's access
	/// list trusts the program that created it by code signature, and an ad-hoc signed `cryo` gets a
	/// new one on every build, after which the agent would block on a Keychain dialog nobody sees.
	/// `security` keeps one Apple signature. The token goes in on stdin, never in argv.
	public struct KeychainTokenStore: TokenStore {
		public let service: String
		public let account: String
		public let legacy: FileTokenStore

		public init(home: String, service: String = "dev.rizwan.cryo.ci", account: String = "github") {
			self.service = service
			self.account = account
			self.legacy = FileTokenStore(home: home)
		}

		public var place: String { "the login Keychain (\(service))" }

		public func load() throws -> String? {
			let r = try security(["find-generic-password", "-s", service, "-a", account, "-w"])
			switch r.status {
			case 0:
				let t = r.stdout.trimmingSpaces().trimmingNewlines()
				return t.isEmpty ? nil : t
			case 44:  // errSecItemNotFound
				return try legacy.load()
			default:
				throw KeychainError("read", r.stderr, status: r.status)
			}
		}

		public func save(_ token: String) throws {
			// `security -i` splits its input line on spaces; GitHub tokens are [A-Za-z0-9_].
			guard !token.isEmpty,
				token.utf8.allSatisfy({ b in
					(b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x5F || b == 0x2D || b == 0x2E
				})
			else { throw KeychainError("save", "the token has characters a GitHub token never has") }
			let line = "add-generic-password -U -s \(service) -a \(account) -l \"cryo ci GitHub token\" -w \(token)\n"
			let r = try security(["-i"], stdin: line)
			// On failure `security -i` echoes the command; keep only lines without the token.
			let err = r.stderr.split(separator: "\n").filter { !$0.contains(token) }.joined(separator: "\n")
			guard r.status == 0 else { throw KeychainError("save", err, status: r.status) }
			unlink(legacy.path)
		}

		/// Removes the token (tests, and a manual reset).
		public func delete() throws {
			let r = try security(["delete-generic-password", "-s", service, "-a", account])
			guard r.status == 0 || r.status == 44 else { throw KeychainError("delete", r.stderr, status: r.status) }
		}

		private func security(_ args: [String], stdin: String? = nil) throws -> (status: Int32, stdout: String, stderr: String) {
			let p = Process()
			p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
			p.arguments = args
			let inPipe = Pipe()
			let outPipe = Pipe()
			let errPipe = Pipe()
			p.standardInput = stdin == nil ? FileHandle.nullDevice : inPipe
			p.standardOutput = outPipe
			p.standardError = errPipe
			try p.run()
			if let stdin {
				inPipe.fileHandleForWriting.write(Data(stdin.utf8))
				try inPipe.fileHandleForWriting.close()
			}
			// Small outputs: read both to EOF, then reap.
			let out = outPipe.fileHandleForReading.readDataToEndOfFile()
			let err = errPipe.fileHandleForReading.readDataToEndOfFile()
			p.waitUntilExit()
			return (p.terminationStatus, String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
		}
	}
#endif
