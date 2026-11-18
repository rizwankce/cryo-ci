import CryoAPI
import CryoClient
import CryoHTTP

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

// MARK: runner cache

/// Keeps the latest `actions/runner` release for macOS arm64 under `~/.cryo/runner` (docs/ci.md:
/// the runner is not in the image). The tarball is staged as is and unpacked in the guest, so it is
/// not extracted here. Layout:
///   runner/actions-runner-osx-arm64-<version>.tar.gz   only under this name once its SHA-256 matched
///   runner/last-check               unix time of the last successful release check
public final class RunnerCache: @unchecked Sendable {
	public static let checkInterval: Double = 24 * 3600
	public static let keepVersions = 2

	private let root: String
	private let transport: any GitHubTransport
	private let token: String
	private let commands: any CommandRunner
	private let now: @Sendable () -> Double
	private let log: @Sendable (String) -> Void
	private let lock = Monitor()

	/// `token` may be empty: the releases endpoint is public (the token only raises the rate limit).
	public init(
		home: String, transport: any GitHubTransport, token: String, commands: any CommandRunner = ProcessRunner(),
		now: @escaping @Sendable () -> Double = nowSeconds, log: @escaping @Sendable (String) -> Void
	) {
		self.root = home + "/.cryo/runner"
		self.transport = transport
		self.token = token
		self.commands = commands
		self.now = now
		self.log = log
	}

	private static let tarPrefix = "actions-runner-osx-arm64-"
	private static let tarSuffix = ".tar.gz"

	public func tarball(_ version: String) -> String { root + "/" + Self.tarPrefix + version + Self.tarSuffix }
	private var lastCheckPath: String { root + "/last-check" }

	/// Versions whose verified tarball is in place, newest first. A download is written to a `.part`
	/// file and renamed only after its SHA-256 matched, so the final name means complete.
	public func cachedVersions() -> [String] {
		listDir(root).compactMap { name -> String? in
			guard name.hasPrefix(Self.tarPrefix), name.hasSuffix(Self.tarSuffix) else { return nil }
			let v = String(name.dropFirst(Self.tarPrefix.count).dropLast(Self.tarSuffix.count))
			return Self.isVersion(v) ? v : nil
		}.sorted { Self.isNewer($0, than: $1) }
	}

	/// The newest runner: checks GitHub at most once per 24 h, falls back to what is cached when the
	/// check fails. Returns the version and its tarball.
	public func ensureLatest() throws -> (version: String, tarball: String) {
		try lock.withLock {
			let cached = cachedVersions().first
			if let cached, let last = lastCheck(), now() - last < Self.checkInterval, now() >= last {
				return (cached, tarball(cached))
			}
			do {
				let v = try checkAndInstall()
				return (v, tarball(v))
			} catch {
				if let cached {
					log("runner update check failed (\(error)); using cached runner \(cached)")
					return (cached, tarball(cached))
				}
				throw CILauncherError("no runner is cached and the latest actions/runner release cannot be fetched: \(error)")
			}
		}
	}

	private func lastCheck() -> Double? {
		readTextFile(lastCheckPath).flatMap { Double($0.trimmingSpaces()) }
	}

	private func checkAndInstall() throws -> String {
		let release = try fetchRelease()
		if !pathExists(tarball(release.version)) {
			try install(release)
			log("downloaded actions/runner \(release.version)")
		}
		try makeDirs(root, mode: 0o700)
		try writeAtomically(lastCheckPath, String(Int(now())))
		prune()
		return release.version
	}

	struct Release: Equatable {
		var version: String
		var url: String
		var sha256: String
	}

	private func fetchRelease() throws -> Release {
		let r: GitHubResponse
		do {
			r = try transport.send(method: "GET", path: "/repos/actions/runner/releases/latest", query: [:], body: nil, token: token)
		} catch {
			throw CILauncherError("\(error)")
		}
		guard (200..<300).contains(r.status) else { throw CILauncherError("releases API answered HTTP \(r.status)") }
		return try Self.parseRelease(r.body)
	}

	static func parseRelease(_ data: Data) throws -> Release {
		// swift-format-ignore: AlwaysUseLowerCamelCase
		struct Asset: Decodable {
			var name: String
			var browser_download_url: String
		}
		// swift-format-ignore: AlwaysUseLowerCamelCase
		struct R: Decodable {
			var tag_name: String
			var body: String?
			var assets: [Asset]
		}
		let r: R
		do { r = try JSONDecoder().decode(R.self, from: data) } catch {
			throw CILauncherError("cannot read the release JSON: \(error)")
		}
		let version = r.tag_name.hasPrefix("v") ? String(r.tag_name.dropFirst()) : r.tag_name
		// The tag becomes a directory name and is compared as dotted numbers: be strict.
		guard isVersion(version) else {
			throw CILauncherError("unexpected runner version '\(r.tag_name)'")
		}
		let name = "actions-runner-osx-arm64-\(version).tar.gz"
		guard let asset = r.assets.first(where: { $0.name == name }) else {
			throw CILauncherError("release \(version) has no asset \(name)")
		}
		guard asset.browser_download_url.hasPrefix("https://github.com/actions/runner/") else {
			throw CILauncherError("unexpected download URL \(asset.browser_download_url)")
		}
		guard let sha = parseSHA(body: r.body ?? "", platform: "osx-arm64") else {
			throw CILauncherError("release \(version) lists no SHA-256 for osx-arm64; refusing an unverified download")
		}
		return Release(version: version, url: asset.browser_download_url, sha256: sha)
	}

	static func isVersion(_ v: String) -> Bool {
		!v.isEmpty && v.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
	}

	/// `<!-- BEGIN SHA osx-arm64 -->hash<!-- END SHA osx-arm64 -->` in the release notes.
	static func parseSHA(body: String, platform: String) -> String? {
		let begin = "<!-- BEGIN SHA \(platform) -->"
		let end = "<!-- END SHA \(platform) -->"
		guard let b = body.firstRange(of: begin), let e = body[b.upperBound...].firstRange(of: end) else { return nil }
		let hash = body[b.upperBound..<e.lowerBound].trimmingSpaces().lowercased()
		return hash.count == 64 && hash.allSatisfy(\.isHexDigit) ? hash : nil
	}

	private func install(_ r: Release) throws {
		try makeDirs(root, mode: 0o700)
		let tar = tarball(r.version)
		let tmp = tar + ".part"
		unlink(tmp)
		let dl = commands.run(argv: ["/usr/bin/curl", "-fsSL", "--retry", "2", "-o", tmp, r.url], timeout: 1800)
		guard dl.exitCode == 0, !dl.timedOut else {
			unlink(tmp)
			throw CILauncherError("downloading \(r.url) failed: \(dl.timedOut ? "timed out" : dl.stderr.trimmingSpaces())")
		}
		let sum = commands.run(argv: ["/usr/bin/shasum", "-a", "256", tmp], timeout: 300)
		let actual = sum.stdout.split(separator: " ").first.map { String($0).lowercased() } ?? ""
		guard sum.exitCode == 0, actual == r.sha256 else {
			unlink(tmp)
			throw CILauncherError(
				"SHA-256 of the runner download does not match the release (expected \(r.sha256), got \(actual.isEmpty ? "nothing" : actual)); refusing it")
		}
		guard rename(tmp, tar) == 0 else { throw CILauncherError("cannot move the download into place: \(String(cString: strerror(errno)))") }
	}

	/// Keeps the newest `keepVersions` tarballs; removes older ones, and leftovers (unfinished
	/// downloads, and the extracted trees older versions of cryo kept next to the tarballs).
	private func prune() {
		let keep = Set(cachedVersions().prefix(Self.keepVersions))
		for name in listDir(root) {
			if name.hasSuffix(".partial") || name.hasSuffix(".part") || pathExists(root + "/" + name + "/.cryo-complete") {
				removeTree(root + "/" + name)
			} else if name.hasPrefix(Self.tarPrefix), name.hasSuffix(Self.tarSuffix) {
				let v = String(name.dropFirst(Self.tarPrefix.count).dropLast(Self.tarSuffix.count))
				if !keep.contains(v) { unlink(root + "/" + name) }
			}
		}
	}

	static func isNewer(_ a: String, than b: String) -> Bool {
		let x = a.split(separator: ".").map { Int($0) ?? 0 }
		let y = b.split(separator: ".").map { Int($0) ?? 0 }
		for i in 0..<max(x.count, y.count) {
			let p = i < x.count ? x[i] : 0
			let q = i < y.count ? y[i] : 0
			if p != q { return p > q }
		}
		return false
	}
}

/// rm -rf without a shell; does not follow symlinks.
func removeTree(_ path: String) {
	var st = stat()
	guard lstat(path, &st) == 0 else { return }
	if (st.st_mode & S_IFMT) == S_IFDIR {
		for name in listDir(path) { removeTree(path + "/" + name) }
		_ = chmod(path, 0o700)
		rmdir(path)
	} else {
		unlink(path)
	}
}

// MARK: launcher

/// Runs the one-job runner inside a capsule. The runner is copied into the lease folder on the
/// host (an APFS clone, so it costs nothing), then over SSH copied from the share onto the VM
/// disk (builds must not run on the share) and started with the JIT config.
public final class GuestRunnerLauncher: CapsuleRunnerLauncher, @unchecked Sendable {
	public static let staleStagingSeconds: Double = 24 * 3600
	/// Used when the lease carries no idle bound: a 6 h job plus 10 min.
	public static let defaultTimeoutSeconds: Double = 6 * 3600 + 600

	private let local: LocalState
	private let cache: RunnerCache
	private let commands: any CommandRunner
	/// The `cryo` the runner's ssh runs as its ProxyCommand (`cryo ssh <id>`).
	private let executable: String
	private let now: @Sendable () -> Double
	private let log: @Sendable (String) -> Void

	public init(
		home: String, cache: RunnerCache, commands: any CommandRunner = ProcessRunner(outputCap: 1024 * 1024),
		executable: String = cryoExecutable() ?? "cryo", now: @escaping @Sendable () -> Double = nowSeconds,
		log: @escaping @Sendable (String) -> Void
	) {
		self.local = LocalState(home: home)
		self.cache = cache
		self.commands = commands
		self.executable = executable
		self.now = now
		self.log = log
	}

	private var ciDir: String { local.cryoDir + "/ci" }
	var stagingRoot: String { ciDir + "/staging" }
	var logsDir: String { ciDir + "/logs" }

	// MARK: prepareFolder

	public func prepareFolder(job: CIJob) throws -> String? {
		let runner = try cache.ensureLatest()
		removeStaleStaging()
		let staging = stagingRoot + "/\(job.id)"
		removeTree(staging)
		do { try makeDirs(staging, mode: 0o700) } catch { throw CILauncherError("\(error)") }
		// Stage the verified release tarball, not the extracted tree: copying the runner's
		// symlinks out of the virtiofs share failed ("could not copy extended attributes") and
		// twice left the guest unreachable. One plain file crosses the share; the guest
		// unpacks it on its own disk in ~2 s. `cp -c` is clonefile(2): no extra disk.
		#if os(macOS)
			let cp = ["/bin/cp", "-c", runner.tarball, staging + "/actions-runner.tar.gz"]
		#else
			let cp = ["/bin/cp", runner.tarball, staging + "/actions-runner.tar.gz"]
		#endif
		let r = commands.run(argv: cp, timeout: 120)
		guard r.exitCode == 0 else {
			removeTree(staging)
			throw CILauncherError("cannot stage the runner: \(r.stderr.trimmingSpaces())")
		}
		return staging
	}

	/// Staging dirs of jobs that ended (or died) more than a day ago.
	func removeStaleStaging() {
		for name in listDir(stagingRoot) {
			let p = stagingRoot + "/" + name
			var st = stat()
			guard lstat(p, &st) == 0 else { continue }
			#if os(Linux)
				let modified = st.st_mtim.tv_sec
			#else
				let modified = st.st_mtimespec.tv_sec
			#endif
			if now() - Double(modified) > Self.staleStagingSeconds { removeTree(p) }
		}
	}

	// MARK: runRunner

	/// Runs on the VM. The JIT config arrives on stdin so it never shows in a process list on the
	/// host. The runner is unpacked on the VM disk (its `_work` must not be on the share).
	static let remoteScript = """
		set -e
		IFS= read -r JIT
		rm -rf "$HOME/actions-runner"
		mkdir -p "$HOME/actions-runner"
		tar -xzf "/Volumes/My Shared Files/actions-runner.tar.gz" -C "$HOME/actions-runner"
		cd "$HOME/actions-runner"
		exec ./run.sh --jitconfig "$JIT"
		"""

	func sshArgv(lease: Lease) -> [String] {
		let command = "/bin/sh -c " + shellQuote(Self.remoteScript)
		return [
			"ssh", "-T", "-F", local.sshConfig, "-o", "BatchMode=yes", "-o", "LogLevel=ERROR",
			"-o", "ServerAliveInterval=30", "-o", "ProxyCommand=\(proxyCommand(lease.id))",
			lease.ssh.host, "--", command,
		]
	}

	public func runRunner(lease: Lease, jitConfig: String) throws -> Int32 {
		// The same files `cryo lease` writes, so `ssh -F ~/.cryo/ssh_config` resolves the host. Only
		// the runner's ssh uses them: they go once it exits, as after `cryo release`.
		defer { local.removeLease(lease.id) }
		do { try local.saveLease(lease) } catch { throw CILauncherError("cannot write the lease's SSH key: \(error)") }
		let tmpDir = ciDir + "/tmp"
		do {
			try makeDirs(tmpDir, mode: 0o700)
			try makeDirs(logsDir, mode: 0o700)
		} catch { throw CILauncherError("\(error)") }
		let jitFile = tmpDir + "/jit-\(lease.id)"
		do { try writeSecretFile(jitFile, jitConfig + "\n") } catch { throw CILauncherError("\(error)") }
		defer { unlink(jitFile) }
		let pidFile = self.pidFile(lease.id)
		defer { unlink(pidFile) }

		// ProcessRunner gives the child /dev/null as stdin, so a `sh` wrapper points it at the 0600
		// file; the credential is never in an argv. The wrapper also leaves its pid (ssh's, after
		// the exec) for `stopRunner`.
		let argv = ["/bin/sh", "-c", Self.wrapper, "sh", jitFile, pidFile] + sshArgv(lease: lease)
		let timeout = lease.idleS.map(Double.init) ?? Self.defaultTimeoutSeconds
		let result = commands.run(argv: argv, timeout: timeout)

		let name = lease.name ?? lease.id
		writeLog(name: name, result: result)
		if result.timedOut {
			throw CILauncherError("the runner did not finish within \(Int(timeout / 60)) min; killed it")
		}
		if result.exitCode == 255 {
			throw CILauncherError("ssh into capsule \(lease.id) failed: \(result.stderr.trimmingSpaces())")
		}
		if result.exitCode != 0 {
			log("\(name): runner exited \(result.exitCode); log \(logsDir)/\(name).log")
		}
		return result.exitCode
	}

	static let wrapper = "echo $$ > \"$2\"; f=\"$1\"; shift 2; exec \"$@\" < \"$f\""

	func pidFile(_ lease: String) -> String { ciDir + "/tmp/pid-\(lease)" }

	/// SIGTERM to the runner's ssh and its ProxyCommand: ProcessRunner starts the child in a
	/// process group of its own. The capsule is released right after, which ends the runner there.
	@discardableResult
	public func stopRunner(lease: String) -> Bool {
		guard let text = readTextFile(pidFile(lease)), let pid = pid_t(text.filter(\.isNumber)), pid > 1 else { return false }
		let group = kill(-pid, SIGTERM) == 0
		return kill(pid, SIGTERM) == 0 || group
	}

	public func forgetLease(_ id: String) {
		local.removeLease(id)
		unlink(pidFile(id))
		unlink(ciDir + "/tmp/jit-\(id)")
	}

	/// The runner's output, as far as the output cap kept it (its tail), once the job is over.
	private func writeLog(name: String, result: CommandResult) {
		let safe = String(name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
		var text = result.stdout
		if result.stdoutTruncated { text = "[earlier output dropped]\n" + text }
		if !result.stderr.isEmpty { text += "\n[stderr]\n" + result.stderr }
		try? writeAtomically(logsDir + "/\(safe).log", text, mode: 0o600)
	}

	/// `<self> ssh <id>`, quoted for the shell ssh runs it in (ssh also expands `%` there).
	private func proxyCommand(_ id: String) -> String {
		sshProxyCommand(executable: executable, leaseID: id)
	}
}

/// The `cryo` program for the runner's ProxyCommand, as an absolute path, or nil when none is found.
/// Looked up in order: next to cryo-ci (both install to ~/.cryo/bin), next to how cryo-ci was
/// invoked (a Homebrew symlink), Homebrew's stable links for the prefix a versioned Cellar path
/// points into (`<prefix>/opt/cryo/bin`, `<prefix>/bin`; they survive `brew upgrade`), the first
/// `cryo` on `path`, then the usual install directories, because a LaunchAgent's PATH is only
/// /usr/bin:/bin:/usr/sbin:/sbin.
public func cryoExecutable(
	beside program: String = currentExecutablePath(), path: String? = getenv("PATH").map { String(cString: $0) },
	invokedAs invoked: String? = CommandLine.arguments.first,
	fallbackDirectories: [String] = ["/opt/homebrew/bin", "/usr/local/bin"]
) -> String? {
	func parent(_ p: String) -> String? {
		guard p.contains("/") else { return nil }
		let dir = p.split(separator: "/", omittingEmptySubsequences: false).dropLast().joined(separator: "/")
		return dir.isEmpty ? nil : dir
	}
	var candidates = [parent(program), invoked.flatMap(parent)].compactMap { $0 }
	// <prefix>/Cellar/<formula>/<version>/bin/<program>
	for p in [program, invoked].compactMap({ $0 }) {
		let parts = p.components(separatedBy: "/Cellar/")
		if parts.count == 2, !parts[0].isEmpty, parts[1].split(separator: "/").count >= 3 {
			candidates += [parts[0] + "/opt/cryo/bin", parts[0] + "/bin"]
		}
	}
	candidates += (path ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
	candidates += fallbackDirectories
	for d in candidates where access(d + "/cryo", X_OK) == 0 { return d + "/cryo" }
	return nil
}

/// Single-quotes `s` for a POSIX shell; plain words stay bare unless `always`.
func shellQuote(_ s: String, always: Bool = true) -> String {
	let plain =
		!s.isEmpty
		&& s.utf8.allSatisfy { b in
			(b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x2F || b == 0x2E || b == 0x5F || b == 0x2D || b == 0x2B
		}
	if plain && !always { return s }
	return "'" + replaceAll(s, "'", "'\\''") + "'"
}

func replaceAll(_ s: String, _ target: Character, _ with: String) -> String {
	var out = ""
	for c in s { if c == target { out += with } else { out.append(c) } }
	return out
}
