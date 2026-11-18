import CryoAPI
import CryoCI
import CryoClient
import CryoHTTP

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

/// Write end of the `cryo-ci github` signal pipe. Only the signal handler touches it, with write(2).
nonisolated(unsafe) private var ciSignalWriteFD: Int32 = -1

private func onCISignal(_ sig: Int32) {
	var b = UInt8(truncatingIfNeeded: sig)
	_ = write(ciSignalWriteFD, &b, 1)
}

extension CryoCICLI {
	/// `cryo-ci …` (and `cryo ci …`, which runs it). The transport, token store and agent are passed
	/// in so only macOS needs the URLSession transport, the Keychain and launchctl, and tests can
	/// substitute them.
	static func ciCommand(
		_ ctx: CLIContext, _ args: [String], transport: @escaping () -> any GitHubTransport,
		tokens: any TokenStore, agent: CIAgent
	) -> Int32 {
		guard let sub = args.first else {
			ctx.out(Help.main)
			return 0
		}
		let rest = Array(args.dropFirst())
		switch sub {
		case "--help", "-h", "help":
			ctx.out(Help.main)
			return 0
		case "github":
			if rest.first == "login" {
				return guarded(ctx, Array(rest.dropFirst()), ArgSpec(values: ["token"])) { ctx, p in
					try ciLogin(ctx, p, transport: transport, tokens: tokens)
				}
			}
			trimLaunchdLog(agent.logPath)
			return guarded(ctx, rest, ArgSpec(values: ["repo", "labels", "timeout-minutes"])) { ctx, p in
				try ciGitHub(ctx, p, transport: transport, tokens: tokens)
			}
		case "status":
			return guarded(ctx, rest, ArgSpec(bools: ["json"])) { ctx, p in
				let state = CIStateStore(home: ctx.home).load()
				if p.flag("json") {
					let e = CryoJSON.encoder()
					e.outputFormatting.insert(.prettyPrinted)
					ctx.say(String(decoding: try e.encode(state ?? CIState()), as: UTF8.self))
				} else {
					ctx.out(renderCIStatus(state))
				}
				return 0
			}
		case "install":
			return guarded(ctx, rest, ArgSpec(values: ["repo", "labels", "timeout-minutes"])) { ctx, p in
				let o = try ciOptions(p)
				guard try tokens.load() != nil else {
					throw UsageError(message: "no stored GitHub token; run `cryo-ci github login` first (the agent does not see GITHUB_TOKEN)")
				}
				var argv = [launchAgentExecutablePath(currentExecutablePath()), "github"]
				for r in o.repos { argv += ["--repo", r] }
				if let l = p.values["labels"] { argv += ["--labels", l] }
				if let t = o.timeout { argv += ["--timeout-minutes", String(t)] }
				if cryoExecutable() == nil {
					ctx.warn("cryo-ci: warning: cannot find the cryo program; jobs will fail until it is installed (brew install cryo)")
				}
				try agent.install(arguments: argv)
				ctx.say("installed LaunchAgent \(CIAgent.label) (\(agent.plistPath)); it starts at login and restarts if it exits")
				ctx.say("log: \(agent.logPath)    status: cryo-ci status")
				return 0
			}
		case "uninstall":
			return guarded(ctx, rest, ArgSpec()) { ctx, _ in
				ctx.say(try agent.uninstall() ? "removed LaunchAgent \(CIAgent.label)" : "LaunchAgent \(CIAgent.label) was not installed")
				return 0
			}
		default:
			ctx.warn("cryo-ci: unknown subcommand '\(sub)'\n")
			ctx.err(Help.main)
			return 2
		}
	}

	private static func ciLogin(_ ctx: CLIContext, _ p: ParsedArgs, transport: () -> any GitHubTransport, tokens: any TokenStore) throws -> Int32 {
		var token = p.values["token"]
		if token == nil {
			if ctx.stdinIsTTY { ctx.err("GitHub token: ") }
			token = ctx.readLine()
		}
		guard let token = token?.trimmingSpaces(), !token.isEmpty else {
			throw UsageError(message: "no token given (use --token or pipe it on stdin)")
		}
		let login = try GitHubAPI(transport: transport(), token: token).user()
		try tokens.save(token)
		ctx.say("logged in to GitHub as \(login); token saved to \(tokens.place)")
		return 0
	}

	/// `--repo`, `--timeout-minutes`, checked; shared by `github` and `install`.
	private static func ciOptions(_ p: ParsedArgs) throws -> (repos: [String], timeout: Int?) {
		if let extra = p.positionals.first { throw UsageError(message: "unexpected argument '\(extra)'") }
		let repos = p.all["repo"] ?? []
		guard !repos.isEmpty else { throw UsageError(message: "--repo owner/name is required") }
		for r in repos {
			let parts = r.split(separator: "/", omittingEmptySubsequences: false)
			guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
				throw UsageError(message: "--repo must look like owner/name, got '\(r)'")
			}
		}
		var timeout: Int?
		if let t = p.values["timeout-minutes"] {
			guard let n = Int(t), n > 0 else { throw UsageError(message: "--timeout-minutes must be a positive number, got '\(t)'") }
			timeout = n
		}
		return (repos, timeout)
	}

	private static func ciGitHub(_ ctx: CLIContext, _ p: ParsedArgs, transport: () -> any GitHubTransport, tokens: any TokenStore) throws -> Int32 {
		let (repos, timeout) = try ciOptions(p)
		let envToken = ctx.environment["GITHUB_TOKEN"]?.trimmingSpaces()
		guard let token = try (envToken?.isEmpty == false ? envToken : tokens.load()) else {
			throw UsageError(message: "no GitHub token; run `cryo-ci github login` or set GITHUB_TOKEN")
		}
		let bay = ctx.client
		var labels = (p.values["labels"] ?? "").split(separator: ",").map { $0.trimmingSpaces() }.filter { !$0.isEmpty }
		if labels.isEmpty {
			// The image label comes from the bay; without it, jobs asking for `cryo-xcode-…` would
			// sit queued. Wait for a bay that is still starting (it refills capsules first).
			var waited = 0
			while (try? bay.status()) == nil {
				guard waited < 120 else { throw UsageError(message: "no bay answering at \(ctx.target.display); start it with `cryo bay start`") }
				if waited == 0 { ctx.err("cryo-ci: waiting for the bay...\n") }
				usleep(2_000_000)
				waited += 2
			}
			labels = CIRules.defaultLabels(bay: bay)
		}
		var config = CIConfig(repos: repos, offeredLabels: labels)
		if let timeout { for r in repos { config.timeoutMinutes[r] = timeout } }
		let ciLog: @Sendable (String) -> Void = { writeAll(2, $0 + "\n") }
		// Only macOS gets here (cryo-ci is macOS bay only, CLI.swift).
		let cryo = cryoExecutable()
		if let cryo {
			ciLog("cryo-ci: using \(cryo) for the runners' ssh")
		} else {
			ciLog("cryo-ci: cannot find the cryo program (looked next to cryo-ci, in Homebrew's bin, on PATH); every job will fail until it is installed, e.g. brew install cryo")
		}
		let launcher = GuestRunnerLauncher(
			home: ctx.home,
			cache: RunnerCache(home: ctx.home, transport: transport(), token: token, log: ciLog),
			executable: cryo ?? "cryo", log: ciLog)
		var host = [CChar](repeating: 0, count: 256)
		gethostname(&host, host.count - 1)
		let poller = CIPoller(
			config: config, api: GitHubAPI(transport: transport(), token: token), bay: bay,
			launcher: launcher, store: CIStateStore(home: ctx.home),
			hostName: String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self),
			reloadToken: { envToken?.isEmpty == false ? envToken : (try? tokens.load()) ?? nil }, log: ciLog)
		// launchd stops the agent with SIGTERM (`cryo-ci uninstall`, logout): stop the runners and
		// release their capsules first instead of leaving them leased until their idle bound.
		onTerminationSignal { sig in
			ciLog("cryo-ci: signal \(sig): stopping runners, releasing their capsules")
			poller.stop()
		}
		ctx.warn("cryo-ci: watching \(repos.joined(separator: ", ")) for jobs labeled \(labels.joined(separator: ", "))")
		poller.run()
		ctx.warn("cryo-ci: stopped")
		return 0
	}

	/// Runs `body` on a thread of its own on the first SIGINT, SIGTERM or SIGHUP (a self-pipe: a
	/// signal handler may only write(2)).
	private static func onTerminationSignal(_ body: @escaping @Sendable (Int32) -> Void) {
		var fds: [Int32] = [-1, -1]
		guard pipe(&fds) == 0 else { return }
		for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
		_ = fcntl(fds[1], F_SETFL, fcntl(fds[1], F_GETFL) | O_NONBLOCK)
		ciSignalWriteFD = fds[1]
		let readFD = fds[0]
		for sig in [SIGINT, SIGTERM, SIGHUP] { signal(sig, onCISignal) }
		spawnThread {
			var b: UInt8 = 0
			while read(readFD, &b, 1) < 0 && errno == EINTR {}
			body(Int32(b))
		}
	}
}
