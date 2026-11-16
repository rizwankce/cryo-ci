import CryoClient
import CryoHTTP

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

/// `cryo ci install`: `cryo ci github …` as a LaunchAgent in the logged-in user's GUI session,
/// next to the bay (ci.md). launchd starts it at login and restarts it when it exits; its output
/// goes to `~/.cryo/ci.log`.
public struct CIAgent {
	public static let label = "dev.rizwan.cryo.ci"

	public let home: String
	public let uid: uid_t
	public let commands: any CommandRunner

	public init(home: String, uid: uid_t = getuid(), commands: any CommandRunner = ProcessRunner()) {
		self.home = home
		self.uid = uid
		self.commands = commands
	}

	public var plistPath: String { home + "/Library/LaunchAgents/\(Self.label).plist" }
	public var logPath: String { home + "/.cryo/ci.log" }
	var domain: String { "gui/\(uid)" }

	/// The agent's property list. `arguments` is the full argv, program first.
	public func plist(arguments: [String]) -> String {
		let args = arguments.map { "\t\t<string>\(xmlEscape($0))</string>" }.joined(separator: "\n")
		return """
			<?xml version="1.0" encoding="UTF-8"?>
			<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
			<plist version="1.0">
			<dict>
			\t<key>Label</key>
			\t<string>\(Self.label)</string>
			\t<key>ProgramArguments</key>
			\t<array>
			\(args)
			\t</array>
			\t<key>RunAtLoad</key>
			\t<true/>
			\t<key>KeepAlive</key>
			\t<true/>
			\t<key>ThrottleInterval</key>
			\t<integer>30</integer>
			\t<key>StandardOutPath</key>
			\t<string>\(xmlEscape(logPath))</string>
			\t<key>StandardErrorPath</key>
			\t<string>\(xmlEscape(logPath))</string>
			</dict>
			</plist>

			"""
	}

	/// Writes the plist and (re)loads the agent; an agent already loaded is replaced.
	public func install(arguments: [String]) throws {
		try makeDirs(home + "/Library/LaunchAgents", mode: 0o755)
		try makeDirs(home + "/.cryo", mode: 0o700)
		try writeAtomically(plistPath, plist(arguments: arguments), mode: 0o644)
		_ = bootout()
		// bootstrap right after a bootout can fail with EIO while launchd still tears the old
		// job down; a short retry covers it.
		var last = CommandResult(exitCode: 1)
		for attempt in 0..<5 {
			if attempt > 0 { usleep(1_000_000) }
			last = commands.run(argv: ["/bin/launchctl", "bootstrap", domain, plistPath], timeout: 30)
			if last.exitCode == 0 { return }
		}
		throw CIAgentError("launchctl bootstrap \(domain) failed (\(last.exitCode)): \((last.stderr + last.stdout).trimmingSpaces())")
	}

	/// Stops the agent and removes its plist. Returns false when it was not installed.
	@discardableResult
	public func uninstall() throws -> Bool {
		let wasLoaded = bootout()
		let hadPlist = pathExists(plistPath)
		if hadPlist && unlink(plistPath) != 0 {
			throw CIAgentError("cannot remove \(plistPath): \(String(cString: strerror(errno)))")
		}
		return wasLoaded || hadPlist
	}

	/// True when the agent was loaded.
	private func bootout() -> Bool {
		commands.run(argv: ["/bin/launchctl", "bootout", "\(domain)/\(Self.label)"], timeout: 30).exitCode == 0
	}
}

public struct CIAgentError: Error, CustomStringConvertible {
	public let description: String
	public init(_ description: String) { self.description = description }
}

private func xmlEscape(_ s: String) -> String {
	var out = ""
	for c in s {
		switch c {
		case "&": out += "&amp;"
		case "<": out += "&lt;"
		case ">": out += "&gt;"
		default: out.append(c)
		}
	}
	return out
}
