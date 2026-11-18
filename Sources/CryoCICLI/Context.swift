import CryoClient
import CryoHTTP

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

public let cryoCIVersion = "0.1.1"

/// Everything a command touches from the outside world, so tests can substitute it.
public struct CLIContext {
	public var home: String
	public var cwd: String
	public var environment: [String: String]
	public var target: CryoTarget
	/// Writers take text as is (commands add their own newlines).
	public var out: (String) -> Void
	public var err: (String) -> Void
	/// Reads one line from stdin (without the newline); nil at EOF.
	public var readLine: () -> String?
	public var stdinIsTTY: Bool
	/// File descriptors used by `cryo ssh` in ProxyCommand mode.
	public var stdinFD: Int32
	public var stdoutFD: Int32
	/// Replaces the process with the given argv (`execvp`). Returns only on failure (or in tests),
	/// giving the exit code.
	public var exec: ([String]) -> Int32

	public init(
		home: String, cwd: String, environment: [String: String] = [:], target: CryoTarget,
		out: @escaping (String) -> Void, err: @escaping (String) -> Void,
		readLine: @escaping () -> String? = { nil },
		stdinIsTTY: Bool = false,
		stdinFD: Int32 = 0, stdoutFD: Int32 = 1,
		exec: @escaping ([String]) -> Int32
	) {
		self.home = home
		self.cwd = cwd
		self.environment = environment
		self.target = target
		self.out = out
		self.err = err
		self.readLine = readLine
		self.stdinIsTTY = stdinIsTTY
		self.stdinFD = stdinFD
		self.stdoutFD = stdoutFD
		self.exec = exec
	}

	func say(_ s: String) { out(s + "\n") }
	func warn(_ s: String) { err(s + "\n") }
	var client: CryoClient { CryoClient(target: target) }
}

func readLineFromFD(_ fd: Int32) -> String? {
	var line: [UInt8] = []
	var b: UInt8 = 0
	while true {
		let n = read(fd, &b, 1)
		if n < 0 && errno == EINTR { continue }
		if n <= 0 { return line.isEmpty ? nil : String(decoding: line, as: UTF8.self) }
		if b == 10 { return String(decoding: line, as: UTF8.self) }
		line.append(b)
	}
}

func realExec(_ argv: [String]) -> Int32 {
	var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
	cargs.append(nil)
	execvp(argv[0], &cargs)
	let e = errno
	writeAll(2, "cryo: cannot run \(argv[0]): \(String(cString: strerror(e)))\n")
	return 127
}

extension CLIContext {
	/// The context for the real process.
	public static func process(target: CryoTarget, home: String, environment: [String: String]) -> CLIContext {
		CLIContext(
			home: home, cwd: currentDirectory(), environment: environment, target: target,
			out: { writeAll(1, $0) }, err: { writeAll(2, $0) },
			readLine: { readLineFromFD(0) },
			stdinIsTTY: isatty(0) != 0,
			exec: realExec)
	}
}
