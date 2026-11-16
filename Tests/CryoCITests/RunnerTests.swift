import CryoAPI
import CryoClient
import CryoHTTP
import Testing

@testable import CryoCI

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

// MARK: fakes

func makeTempHome() -> String {
	var t = Array("/tmp/cryo-runner-test-XXXXXX".utf8CString)
	let p = mkdtemp(&t)!
	return String(cString: p)
}

/// Serves the releases API from a scripted body.
final class FakeReleases: GitHubTransport, @unchecked Sendable {
	private let m = Monitor()
	private var _calls = 0
	private var _tokens: [String] = []
	private var _body: Data
	private var _status = 200
	private var _fail = false
	struct Down: Error {}

	init(version: String, sha: String) {
		_body = FakeReleases.json(version: version, sha: sha)
	}

	static func json(version: String, sha: String, platform: String = "osx-arm64", assetName: String? = nil) -> Data {
		let a = String(repeating: "a", count: 64)
		let notes =
			"- x64 <!-- BEGIN SHA osx-x64 -->\(a)<!-- END SHA osx-x64 -->\\r\\n- arm64 <!-- BEGIN SHA \(platform) -->\(sha)<!-- END SHA \(platform) -->\\r\\n"
		let name = assetName ?? "actions-runner-osx-arm64-\(version).tar.gz"
		return Data(
			"""
			{"tag_name":"v\(version)","body":"\(notes)","assets":[
			{"name":"actions-runner-osx-x64-\(version).tar.gz","browser_download_url":"https://github.com/actions/runner/releases/download/v\(version)/x64.tar.gz"},
			{"name":"\(name)","browser_download_url":"https://github.com/actions/runner/releases/download/v\(version)/\(name)"}]}
			""".utf8)
	}

	var calls: Int { m.withLock { _calls } }
	var tokens: [String] { m.withLock { _tokens } }
	func setBody(_ d: Data) { m.withLock { _body = d } }
	func setFail(_ f: Bool) { m.withLock { _fail = f } }
	func setStatus(_ s: Int) { m.withLock { _status = s } }

	func send(method: String, path: String, query: [String: String], body: Data?, token: String) throws -> GitHubResponse {
		let (fail, status, data): (Bool, Int, Data) = m.withLock {
			_calls += 1
			_tokens.append(token)
			return (_fail, _status, _body)
		}
		if fail { throw Down() }
		#expect(path == "/repos/actions/runner/releases/latest")
		return GitHubResponse(status: status, body: data)
	}
}

/// Records argv; curl is faked on disk, shasum is real, anything else goes to `other`.
final class FakeCommands: CommandRunner, @unchecked Sendable {
	private let m = Monitor()
	private var _argvs: [[String]] = []
	private var _curlFails = false
	private var _other: @Sendable ([String]) -> CommandResult = { _ in CommandResult(exitCode: 0) }

	var argvs: [[String]] { m.withLock { _argvs } }
	func argvs(_ program: String) -> [[String]] { argvs.filter { $0.first == program } }
	func setCurlFails() { m.withLock { _curlFails = true } }
	func setOther(_ f: @escaping @Sendable ([String]) -> CommandResult) { m.withLock { _other = f } }

	func run(argv: [String], timeout: Double) -> CommandResult {
		let (fails, other): (Bool, @Sendable ([String]) -> CommandResult) = m.withLock {
			_argvs.append(argv)
			return (_curlFails, _other)
		}
		switch argv.first {
		case "/usr/bin/curl":
			if fails { return CommandResult(exitCode: 22, stderr: "404\n") }
			let out = argv[argv.firstIndex(of: "-o")! + 1]
			try? writeAtomically(out, "tarball")
			return CommandResult(exitCode: 0)
		case "/usr/bin/shasum":
			return ProcessRunner().run(argv: argv, timeout: 30)
		default:
			return other(argv)
		}
	}
}

/// SHA-256 of the bytes the fake curl writes.
func tarballSHA() -> String {
	let home = makeTempHome()
	defer { removeTree(home) }
	try? writeAtomically(home + "/f", "tarball")
	let r = ProcessRunner().run(argv: ["/usr/bin/shasum", "-a", "256", home + "/f"], timeout: 30)
	return String(r.stdout.split(separator: " ")[0])
}

final class Clock: @unchecked Sendable {
	private let m = Monitor()
	private var t: Double
	init(_ t: Double = 1_000_000) { self.t = t }
	func now() -> Double { m.withLock { t } }
	func advance(_ s: Double) { m.withLock { t += s } }
}

func makeCache(home: String, transport: FakeReleases, commands: any CommandRunner, clock: Clock, token: String = "tok") -> RunnerCache {
	RunnerCache(home: home, transport: transport, token: token, commands: commands, now: { clock.now() }, log: { _ in })
}

func makeLease(id: String = "l1", name: String? = "ci-app-11", idleS: Int? = 4200) -> Lease {
	Lease(
		id: id, name: name, capsule: 0, state: "active", createdAt: Date(), renewBy: Date(), expiresAt: Date(), idleS: idleS,
		ssh: SSHInfo(user: "admin", host: "cryo-\(id)", key: "KEY\n", config: "Host cryo-\(id)\n  User admin\n"))
}

// MARK: cache

@Suite struct RunnerCacheTests {
	@Test func parsesReleaseJSONAndSHA() throws {
		let sha = String(repeating: "ab", count: 32)
		let r = try RunnerCache.parseRelease(FakeReleases.json(version: "2.338.2", sha: sha))
		#expect(r.version == "2.338.2")
		#expect(r.sha256 == sha)
		#expect(r.url.hasSuffix("actions-runner-osx-arm64-2.338.2.tar.gz"))
		#expect(RunnerCache.parseSHA(body: "x <!-- BEGIN SHA osx-arm64 -->nothex<!-- END SHA osx-arm64 -->", platform: "osx-arm64") == nil)
		#expect(RunnerCache.parseSHA(body: "no markers", platform: "osx-arm64") == nil)
	}

	@Test func refusesReleaseWithoutAssetOrSHA() {
		let sha = String(repeating: "a", count: 64)
		#expect(throws: CILauncherError.self) {
			try RunnerCache.parseRelease(FakeReleases.json(version: "2.1.0", sha: sha, assetName: "other.tar.gz"))
		}
		#expect(throws: CILauncherError.self) {
			try RunnerCache.parseRelease(FakeReleases.json(version: "2.1.0", sha: sha, platform: "linux-x64"))
		}
		#expect(throws: CILauncherError.self) {
			try RunnerCache.parseRelease(Data("{\"tag_name\":\"v../x\",\"body\":\"\",\"assets\":[]}".utf8))
		}
	}

	/// The tarball is staged as is and unpacked in the guest: nothing is extracted here.
	@Test func downloadsAndVerifiesWithoutExtracting() throws {
		let home = makeTempHome()
		defer { removeTree(home) }
		let net = FakeReleases(version: "2.338.2", sha: tarballSHA())
		let cmds = FakeCommands()
		let cache = makeCache(home: home, transport: net, commands: cmds, clock: Clock())
		let r = try cache.ensureLatest()
		#expect(r.version == "2.338.2")
		#expect(r.tarball == home + "/.cryo/runner/actions-runner-osx-arm64-2.338.2.tar.gz")
		#expect(readTextFile(r.tarball) == "tarball")
		#expect(listDir(home + "/.cryo/runner").sorted() == ["actions-runner-osx-arm64-2.338.2.tar.gz", "last-check"])
		#expect(net.tokens == ["tok"])
		#expect(cmds.argvs("/usr/bin/tar").isEmpty)
		#expect(cache.cachedVersions() == ["2.338.2"])
	}

	/// An unfinished download is not a cached version; extracted trees from older builds are removed.
	@Test func partialDownloadIsNotCachedAndOldTreesArePruned() throws {
		let home = makeTempHome()
		defer { removeTree(home) }
		let root = home + "/.cryo/runner"
		try makeDirs(root + "/2.300.0", mode: 0o755)
		try writeAtomically(root + "/2.300.0/.cryo-complete", "2.300.0")
		try writeAtomically(root + "/actions-runner-osx-arm64-2.400.0.tar.gz.part", "half")
		let net = FakeReleases(version: "2.338.2", sha: tarballSHA())
		let cache = makeCache(home: home, transport: net, commands: FakeCommands(), clock: Clock())
		#expect(cache.cachedVersions().isEmpty)
		_ = try cache.ensureLatest()
		#expect(listDir(root).sorted() == ["actions-runner-osx-arm64-2.338.2.tar.gz", "last-check"])
	}

	@Test func refusesShaMismatch() {
		let home = makeTempHome()
		defer { removeTree(home) }
		let net = FakeReleases(version: "2.338.2", sha: String(repeating: "0", count: 64))
		let cache = makeCache(home: home, transport: net, commands: FakeCommands(), clock: Clock())
		#expect(throws: CILauncherError.self) { try cache.ensureLatest() }
		#expect(cache.cachedVersions().isEmpty)
		#expect(!pathExists(home + "/.cryo/runner/actions-runner-osx-arm64-2.338.2.tar.gz"))
		#expect(!pathExists(home + "/.cryo/runner/actions-runner-osx-arm64-2.338.2.tar.gz.part"))
	}

	@Test func checksAtMostOncePerDay() throws {
		let home = makeTempHome()
		defer { removeTree(home) }
		let net = FakeReleases(version: "2.338.2", sha: tarballSHA())
		let clock = Clock()
		let cache = makeCache(home: home, transport: net, commands: FakeCommands(), clock: clock)
		_ = try cache.ensureLatest()
		clock.advance(3600)
		_ = try cache.ensureLatest()
		#expect(net.calls == 1)
		clock.advance(24 * 3600)
		let cmds = FakeCommands()
		_ = try makeCache(home: home, transport: net, commands: cmds, clock: clock).ensureLatest()
		#expect(net.calls == 2)
		// Same version as cached: checked, not downloaded again.
		#expect(cmds.argvs("/usr/bin/curl").isEmpty)
	}

	@Test func keepsNewestTwoVersions() throws {
		let home = makeTempHome()
		defer { removeTree(home) }
		let clock = Clock()
		let net = FakeReleases(version: "2.9.0", sha: tarballSHA())
		for v in ["2.9.0", "2.10.0", "2.10.1"] {
			net.setBody(FakeReleases.json(version: v, sha: tarballSHA()))
			_ = try makeCache(home: home, transport: net, commands: FakeCommands(), clock: clock).ensureLatest()
			clock.advance(25 * 3600)
		}
		let cache = makeCache(home: home, transport: net, commands: FakeCommands(), clock: clock)
		#expect(cache.cachedVersions() == ["2.10.1", "2.10.0"])
		#expect(!pathExists(home + "/.cryo/runner/actions-runner-osx-arm64-2.9.0.tar.gz"))
		#expect(pathExists(home + "/.cryo/runner/actions-runner-osx-arm64-2.10.0.tar.gz"))
	}

	@Test func fallsBackToCacheWhenCheckFails() throws {
		let home = makeTempHome()
		defer { removeTree(home) }
		let clock = Clock()
		let net = FakeReleases(version: "2.338.2", sha: tarballSHA())
		_ = try makeCache(home: home, transport: net, commands: FakeCommands(), clock: clock).ensureLatest()
		clock.advance(48 * 3600)
		net.setFail(true)
		let cache = makeCache(home: home, transport: net, commands: FakeCommands(), clock: clock)
		#expect(try cache.ensureLatest().version == "2.338.2")
		net.setFail(false)
		net.setStatus(500)
		#expect(try cache.ensureLatest().version == "2.338.2")
	}

	@Test func failsClearlyWithNothingCachedAndNoNetwork() {
		let home = makeTempHome()
		defer { removeTree(home) }
		let net = FakeReleases(version: "2.338.2", sha: "x")
		net.setFail(true)
		let cache = makeCache(home: home, transport: net, commands: FakeCommands(), clock: Clock())
		do {
			_ = try cache.ensureLatest()
			Issue.record("expected an error")
		} catch let e as CILauncherError {
			#expect(e.description.contains("no runner is cached"))
		} catch { Issue.record("wrong error \(error)") }
	}

	@Test func failedDownloadLeavesNothingBehind() {
		let home = makeTempHome()
		defer { removeTree(home) }
		let cmds = FakeCommands()
		cmds.setCurlFails()
		let net = FakeReleases(version: "2.1.0", sha: String(repeating: "a", count: 64))
		let cache = makeCache(home: home, transport: net, commands: cmds, clock: Clock())
		#expect(throws: CILauncherError.self) { try cache.ensureLatest() }
		#expect(cache.cachedVersions().isEmpty)
	}
}

// MARK: launcher

final class Capture: @unchecked Sendable {
	private let m = Monitor()
	private var _argv: [String] = []
	private var _jit: String?
	private var _files: [String: String] = [:]
	private var _timeouts: [Double] = []
	var argv: [String] { m.withLock { _argv } }
	var jit: String? { m.withLock { _jit } }
	/// Files as they were while the runner ran, by path.
	var files: [String: String] { m.withLock { _files } }
	var timeouts: [Double] { m.withLock { _timeouts } }
	func set(_ a: [String], jit: String?, files: [String: String] = [:]) {
		m.withLock {
			_argv = a
			_jit = jit
			_files = files
		}
	}
	func add(timeout: Double) { m.withLock { _timeouts.append(timeout) } }
}

struct TimeoutRecorder: CommandRunner {
	let inner: any CommandRunner
	let seen: Capture
	func run(argv: [String], timeout: Double) -> CommandResult {
		seen.add(timeout: timeout)
		return inner.run(argv: argv, timeout: timeout)
	}
}

@Suite struct GuestRunnerLauncherTests {
	func launcher(home: String, commands: any CommandRunner, cacheCommands: (any CommandRunner)? = nil, clock: Clock = Clock()) -> GuestRunnerLauncher {
		let net = FakeReleases(version: "2.338.2", sha: tarballSHA())
		let cache = makeCache(home: home, transport: net, commands: cacheCommands ?? FakeCommands(), clock: clock)
		return GuestRunnerLauncher(home: home, cache: cache, commands: commands, executable: "/usr/local/bin/cryo", now: { clock.now() }, log: { _ in })
	}

	let job = CIJob(repo: "acme/App", id: 11, runID: 1, name: "test", labels: [], event: "push", headBranch: "main")

	/// cryo-ci is its own program, so the runner's ProxyCommand must name `cryo`, never cryo-ci: the
	/// one installed next to cryo-ci first, then the first on PATH.
	@Test func proxyCommandFindsCryo() throws {
		let bin = makeTempHome()
		let onPath = makeTempHome()
		let empty = makeTempHome()
		for dir in [bin, onPath] {
			try writeAtomically(dir + "/cryo", "#!/bin/sh\n", mode: 0o755)
		}
		#expect(cryoExecutable(beside: bin + "/cryo-ci", path: "\(empty):\(onPath)") == bin + "/cryo")
		#expect(cryoExecutable(beside: empty + "/cryo-ci", path: "\(empty):\(onPath)") == onPath + "/cryo")
		#expect(cryoExecutable(beside: empty + "/cryo-ci", path: empty) == "cryo")
	}

	@Test func stagingIsAClone() throws {
		let home = makeTempHome()
		defer { removeTree(home) }
		// Real cp, so this exercises clonefile on the temp volume.
		let l = launcher(home: home, commands: ProcessRunner())
		let folder = try #require(try l.prepareFolder(job: job))
		#expect(folder == home + "/.cryo/ci/staging/11")
		// The verified tarball is staged (one plain file crosses the share), not the tree.
		let copy = folder + "/actions-runner.tar.gz"
		let src = home + "/.cryo/runner/actions-runner-osx-arm64-2.338.2.tar.gz"
		#expect(readTextFile(copy) == readTextFile(src))
		var a = stat()
		var b = stat()
		#expect(stat(copy, &a) == 0 && stat(src, &b) == 0)
		#expect(a.st_size == b.st_size)
		#expect(a.st_ino != b.st_ino)  // a separate file, not a hard link
		#expect(!pathExists(folder + "/actions-runner"))
	}

	@Test func stagingUsesCloneFlagOnMac() throws {
		let home = makeTempHome()
		defer { removeTree(home) }
		let cmds = FakeCommands()
		let l = launcher(home: home, commands: cmds)
		_ = try l.prepareFolder(job: job)
		let cp = try #require(cmds.argvs("/bin/cp").first)
		#if os(macOS)
			#expect(cp.contains("-c"))
		#endif
		#expect(cp.last == home + "/.cryo/ci/staging/11/actions-runner.tar.gz")
	}

	@Test func removesStaleStagingOnly() throws {
		let home = makeTempHome()
		defer { removeTree(home) }
		let clock = Clock(Double(Int(Date().timeIntervalSince1970)))
		let l = launcher(home: home, commands: ProcessRunner(), clock: clock)
		_ = try l.prepareFolder(job: job)
		try makeDirs(home + "/.cryo/ci/staging/old", mode: 0o700)
		let t = timeval(tv_sec: Int(clock.now()) - 3 * 86400, tv_usec: 0)
		var times = [t, t]
		#expect(utimes(home + "/.cryo/ci/staging/old", &times) == 0)
		_ = try l.prepareFolder(job: CIJob(repo: "acme/App", id: 12, runID: 1, name: "t", labels: [], event: "push", headBranch: "main"))
		#expect(!pathExists(home + "/.cryo/ci/staging/old"))
		#expect(pathExists(home + "/.cryo/ci/staging/11"))
		#expect(pathExists(home + "/.cryo/ci/staging/12/actions-runner.tar.gz"))
	}

	/// Runs the launcher with a fake runner that captures the argv and the JIT file at spawn time.
	func runWith(_ result: CommandResult, lease: Lease = makeLease(), jit: String = "SECRETJIT") -> (code: Result<Int32, Error>, capture: Capture, home: String)
	{
		let home = makeTempHome()
		let box = Capture()
		let cmds = FakeCommands()
		cmds.setOther { argv in
			// argv: /bin/sh -c <script> sh <jitfile> <pidfile> ssh ...
			var files: [String: String] = [:]
			for p in [home + "/.cryo/keys/\(lease.id)", home + "/.cryo/ssh_config"] { files[p] = readTextFile(p) }
			box.set(argv, jit: readTextFile(argv[4]), files: files)
			return result
		}
		let l = launcher(home: home, commands: cmds)
		let code: Result<Int32, Error> = Result { try l.runRunner(lease: lease, jitConfig: jit) }
		return (code, box, home)
	}

	@Test func sshArgvAndJITOnStdinFile() throws {
		let r = runWith(CommandResult(exitCode: 0, stdout: "Listening for Jobs\n"))
		defer { removeTree(r.home) }
		#expect(try r.code.get() == 0)
		let argv = r.capture.argv
		#expect(Array(argv.prefix(3)) == ["/bin/sh", "-c", "echo $$ > \"$2\"; f=\"$1\"; shift 2; exec \"$@\" < \"$f\""])
		#expect(argv[5] == r.home + "/.cryo/ci/tmp/pid-l1")
		#expect(!pathExists(argv[5]))
		let ssh = Array(argv.dropFirst(6))
		#expect(ssh.first == "ssh")
		#expect(ssh.contains("BatchMode=yes"))
		#expect(ssh.firstIndex(of: "-F").map { ssh[$0 + 1] } == r.home + "/.cryo/ssh_config")
		#expect(ssh.contains("ProxyCommand=/usr/local/bin/cryo ssh l1"))
		#expect(ssh.contains("cryo-l1"))
		#expect(ssh.last?.contains("./run.sh --jitconfig \"$JIT\"") == true)
		#expect(ssh.last?.contains("/Volumes/My Shared Files/actions-runner") == true)
		// The credential is in a 0600 file that sh redirects to stdin, never in an argv.
		#expect(!argv.contains { $0.contains("SECRETJIT") })
		#expect(r.capture.jit == "SECRETJIT\n")
		#expect(!pathExists(argv[4]))
		// The lease's key and ssh_config block exist for ssh -F while the runner runs, and are gone
		// after it.
		#expect(r.capture.files[r.home + "/.cryo/keys/l1"] == "KEY\n")
		#expect(r.capture.files[r.home + "/.cryo/ssh_config"]?.contains("Host cryo-l1") == true)
		#expect(!pathExists(r.home + "/.cryo/keys/l1"))
		#expect(readTextFile(r.home + "/.cryo/ssh_config")?.contains("cryo-l1") != true)
		#expect(readTextFile(r.home + "/.cryo/ci/logs/ci-app-11.log")?.contains("Listening for Jobs") == true)
	}

	/// `stopRunner` ends a running runner (ssh and what it started) through the wrapper's pid file.
	@Test func stopRunnerKillsTheRunningSSH() throws {
		let home = makeTempHome()
		defer { removeTree(home) }
		// The real wrapper and ProcessRunner, with `sleep` in place of ssh.
		struct SleepInsteadOfSSH: CommandRunner {
			func run(argv: [String], timeout: Double) -> CommandResult {
				ProcessRunner().run(argv: Array(argv.prefix(6)) + ["/bin/sh", "-c", "sleep 30 & sleep 30"], timeout: timeout)
			}
		}
		let l = launcher(home: home, commands: SleepInsteadOfSSH())
		#expect(!l.stopRunner(lease: "l1"))  // nothing running yet
		final class Out: @unchecked Sendable {
			let m = Monitor()
			var code: Int32?
		}
		let out = Out()
		spawnThread {
			let c = try? l.runRunner(lease: makeLease(), jitConfig: "J")
			out.m.withLock {
				out.code = c
				out.m.broadcast()
			}
		}
		let start = nowSeconds()
		while !pathExists(home + "/.cryo/ci/tmp/pid-l1") && nowSeconds() - start < 5 { usleep(20_000) }
		usleep(100_000)
		#expect(l.stopRunner(lease: "l1"))
		let code: Int32? = out.m.withLock {
			while out.code == nil && nowSeconds() - start < 10 { out.m.wait(until: nowSeconds() + 1) }
			return out.code
		}
		#expect(code == 143)  // SIGTERM
		#expect(nowSeconds() - start < 10)
		#expect(!pathExists(home + "/.cryo/ci/tmp/pid-l1"))
	}

	@Test func quotesForTheShell() {
		#expect(shellQuote("/Users/a b/cryo", always: false) == "'/Users/a b/cryo'")
		#expect(shellQuote("/usr/local/bin/cryo", always: false) == "/usr/local/bin/cryo")
		#expect(shellQuote("it's") == "'it'\\''s'")
	}

	@Test func exitCodeMapping() throws {
		var r = runWith(CommandResult(exitCode: 0))
		#expect(try r.code.get() == 0)
		removeTree(r.home)
		r = runWith(CommandResult(exitCode: 1))
		#expect(try r.code.get() == 1)
		removeTree(r.home)
		r = runWith(CommandResult(exitCode: 255, stderr: "Connection refused\n"))
		defer { removeTree(r.home) }
		#expect(!pathExists(r.home + "/.cryo/keys/l1"))  // removed on failure too
		do {
			_ = try r.code.get()
			Issue.record("expected an error")
		} catch let e as CILauncherError {
			#expect(e.description.contains("ssh into capsule l1 failed"))
			#expect(e.description.contains("Connection refused"))
		}
	}

	@Test func timeoutIsAnErrorAndUsesLeaseIdleBound() throws {
		let home = makeTempHome()
		defer { removeTree(home) }
		let seen = Capture()
		let cmds = FakeCommands()
		cmds.setOther { _ in CommandResult(exitCode: 137, timedOut: true) }
		let l = launcher(home: home, commands: TimeoutRecorder(inner: cmds, seen: seen))
		#expect(throws: CILauncherError.self) { try l.runRunner(lease: makeLease(idleS: 4200), jitConfig: "J") }
		#expect(throws: CILauncherError.self) { try l.runRunner(lease: makeLease(idleS: nil), jitConfig: "J") }
		#expect(seen.timeouts == [4200, GuestRunnerLauncher.defaultTimeoutSeconds])
	}
}
