import CryoCI
import CryoClient
import CryoHTTP

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

public enum CryoCICLI {
	/// The process entry point: builds the real context and runs.
	public static func main(_ arguments: [String]) -> Int32 {
		var env: [String: String] = [:]
		for k in ["HOME", "GITHUB_TOKEN"] {
			if let v = getenv(k) { env[k] = String(cString: v) }
		}
		let target: CryoTarget
		do {
			target = try CryoTarget.fromProcessEnvironment()
		} catch {
			// Help and version need no bay; the other commands report the bad target.
			let ctx = CLIContext.process(target: CryoTarget(endpoint: .unix(path: "/nonexistent")), home: env["HOME"] ?? "", environment: env)
			if let cmd = arguments.first, ["version", "help", "--help", "-h", "--version"].contains(cmd) || arguments.contains("--help") {
				return run(arguments, ctx)
			}
			ctx.warn("cryo-ci: \(error)")
			return 1
		}
		return run(arguments, CLIContext.process(target: target, home: env["HOME"] ?? "", environment: env))
	}

	/// Runs one command line (without the program name) and returns the exit code.
	public static func run(_ arguments: [String], _ ctx: CLIContext) -> Int32 {
		switch arguments.first {
		case "version", "--version":
			ctx.say("cryo-ci \(cryoCIVersion)")
			return 0
		case nil, "-h", "--help", "help":
			ctx.out(Help.main)
			return 0
		default:
			#if os(macOS)
				return ciCommand(
					ctx, arguments, transport: { URLSessionGitHubTransport() },
					tokens: KeychainTokenStore(home: ctx.home), agent: CIAgent(home: ctx.home))
			#else
				if arguments.contains("--help") || arguments.contains("-h") {
					ctx.out(Help.main)
					return 0
				}
				ctx.warn("cryo-ci: macOS bay only")
				return 1
			#endif
		}
	}

	/// Parses arguments (handling help and usage errors) and maps thrown errors to messages.
	static func guarded(
		_ ctx: CLIContext, _ args: [String], _ spec: ArgSpec,
		_ body: (CLIContext, ParsedArgs) throws -> Int32
	) -> Int32 {
		let parsed: ParsedArgs
		do {
			parsed = try parseArgs(args, spec)
		} catch let e as UsageError {
			ctx.warn("cryo-ci: \(e.message)\n")
			ctx.err(Help.main)
			return 2
		} catch {
			return 2
		}
		if parsed.help {
			ctx.out(Help.main)
			return 0
		}
		do {
			return try body(ctx, parsed)
		} catch let e as UsageError {
			ctx.warn("cryo-ci: \(e.message)")
			return 2
		} catch {
			ctx.warn("cryo-ci: \(describe(error))")
			return 1
		}
	}
}

func describe(_ error: Error) -> String {
	if let e = error as? CryoClientError {
		switch e {
		case .upgradeRequired: return "this cryo-ci is too old for the bay; update it"
		case .api(let a, _): return "\(a.code): \(a.message)"
		default: return e.description
		}
	}
	return "\(error)"
}

enum Help {
	static let main = """
		usage: cryo-ci github login [--token T]
		       cryo-ci github --repo owner/name [--repo ...] [--labels a,b] [--timeout-minutes N]
		       cryo-ci status [--json]
		       cryo-ci install --repo owner/name [--repo ...] [--labels a,b] [--timeout-minutes N]
		       cryo-ci uninstall
		       cryo-ci version

		Runs GitHub Actions jobs on cryo capsules, one job per capsule (macOS bay only).
		`cryo ci …` runs this program with the same arguments.
		  login             store a GitHub token with admin rights on the repos in the login
		                    Keychain (GITHUB_TOKEN in the environment wins over it)
		  --labels          labels this Mac offers (default: cryo, cryo-<image tag>, cryo-macos-<major>)
		  --timeout-minutes job timeout assumed for the lease idle timeout (default 360)
		  status            jobs seen, running, last results
		  install           run `cryo-ci github` with these options as a LaunchAgent
		                    (dev.rizwan.cryo.ci, starts at login, log in ~/.cryo/ci.log)
		  uninstall         stop the LaunchAgent and remove it

		Target: CRYO_URL (default unix://~/.cryo/bay.sock). The runner's ssh uses `cryo ssh` as its
		ProxyCommand: `cryo` next to cryo-ci, else the first on PATH.

		"""
}

/// launchd opens a LaunchAgent's log once and appends to it for good, so nothing rotates
/// `ci.log`. At start, when stdout is that file and it is over 10 MB, keep one old copy in
/// `<log>.1` and empty the log; stdout is in append mode, so writes go on from the start.
func trimLaunchdLog(_ path: String, maxBytes: Int = 10 << 20) {
	#if os(macOS)
		var out = stat()
		var file = stat()
		guard fstat(STDOUT_FILENO, &out) == 0, stat(path, &file) == 0,
			out.st_dev == file.st_dev, out.st_ino == file.st_ino, Int(out.st_size) > maxBytes
		else { return }
		try? FileManager.default.removeItem(atPath: path + ".1")
		guard (try? FileManager.default.copyItem(atPath: path, toPath: path + ".1")) != nil else { return }
		ftruncate(STDOUT_FILENO, 0)
	#endif
}
