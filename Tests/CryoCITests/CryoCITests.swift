import CryoAPI
import CryoClient
import CryoHTTP
import FakeBay
import Testing

@testable import CryoCI
@testable import CryoCICLI

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

// MARK: fakes

/// GitHub as far as `cryo ci` uses it: runs filtered by `status`, lists paged by `per_page` and
/// `page`, one job, runners. Answers can be scripted per call with `respond`.
final class MockGitHub: GitHubTransport, @unchecked Sendable {
	struct Call: Equatable {
		var method: String
		var path: String
		var query: [String: String]
		var body: String
		var token: String
	}

	struct Run {
		var id: Int
		var status: String
		var event: String
		var branch: String
		var updatedAt: String
	}

	struct Job {
		var id: Int
		var run: Int
		var status: String
		var labels: [String]
		var branch: String
		var conclusion = ""
		var runnerName = ""
	}

	private struct Canned {
		var match: String
		var status: Int
		var headers: [String: String]
		var body: String
		var times: Int
	}

	private let m = Monitor()
	private var _calls: [Call] = []
	private var _runs: [Run] = []
	private var _jobs: [Job] = []
	private var _defaultBranch = "main"
	private var _failStatus: Int?
	private var _runnerCounter = 100
	private var _runnerNames: [Int: String] = [:]  // registered runners
	private var _busy: Set<Int> = []
	private var _canned: [Canned] = []
	private var _tokens: Set<String>?

	var calls: [Call] { m.withLock { _calls } }
	func calls(_ method: String, _ s: String) -> [Call] { calls.filter { $0.method == method && $0.path.contains(s) } }
	func clearCalls() { m.withLock { _calls = [] } }
	var runners: [Int: String] { m.withLock { _runnerNames } }

	func setDefaultBranch(_ b: String) { m.withLock { _defaultBranch = b } }
	func failAll(with status: Int?) { m.withLock { _failStatus = status } }
	/// Only these tokens are accepted (401 for others); nil accepts any.
	func acceptTokens(_ t: Set<String>?) { m.withLock { _tokens = t } }
	func setRunnerBusy(_ id: Int, _ busy: Bool) { m.withLock { if busy { _busy.insert(id) } else { _busy.remove(id) } } }

	/// The next `times` calls whose "METHOD path" contains `match` get this answer.
	func respond(_ match: String, status: Int, headers: [String: String] = [:], body: String = "{}", times: Int = 1) {
		m.withLock { _canned.append(Canned(match: match, status: status, headers: headers, body: body, times: times)) }
	}

	/// Adds a job to a run (the run is created, queued, when new).
	func queue(
		run: Int = 1, job: Int = 11, event: String = "push", branch: String = "main", labels: [String] = ["cryo-fake-image"],
		status: String = "queued", runStatus: String = "queued"
	) {
		m.withLock {
			if !_runs.contains(where: { $0.id == run }) {
				_runs.append(Run(id: run, status: runStatus, event: event, branch: branch, updatedAt: "t0"))
			}
			_jobs.append(Job(id: job, run: run, status: status, labels: labels, branch: branch))
		}
	}

	func setRun(_ id: Int, updatedAt: String) {
		m.withLock { if let i = _runs.firstIndex(where: { $0.id == id }) { _runs[i].updatedAt = updatedAt } }
	}

	/// What GitHub does when the JIT runner `jit` ("JIT<runner id>") starts: hands it the job.
	func runnerTakes(jit: String, job: Int) {
		m.withLock {
			guard let id = Int(jit.dropFirst(3)), let name = _runnerNames[id], let i = _jobs.firstIndex(where: { $0.id == job }) else { return }
			_jobs[i].status = "in_progress"
			_jobs[i].runnerName = name
		}
	}

	/// The runner finished its job: the job completes and the one-job runner deregisters.
	func runnerFinished(jit: String, job: Int, conclusion: String = "success") {
		m.withLock {
			guard let id = Int(jit.dropFirst(3)), let i = _jobs.firstIndex(where: { $0.id == job }) else { return }
			if _jobs[i].runnerName == _runnerNames[id] {
				_jobs[i].status = "completed"
				_jobs[i].conclusion = conclusion
			}
			_runnerNames[id] = nil
		}
	}

	func setJob(_ id: Int, status: String? = nil, conclusion: String? = nil, runnerName: String? = nil) {
		m.withLock {
			guard let i = _jobs.firstIndex(where: { $0.id == id }) else { return }
			if let status { _jobs[i].status = status }
			if let conclusion { _jobs[i].conclusion = conclusion }
			if let runnerName { _jobs[i].runnerName = runnerName }
		}
	}

	private func json(_ j: Job) -> String {
		let quoted = j.labels.map { "\"\($0)\"" }.joined(separator: ",")
		return "{\"id\":\(j.id),\"run_id\":\(j.run),\"status\":\"\(j.status)\",\"conclusion\":\"\(j.conclusion)\",\"labels\":[\(quoted)],"
			+ "\"head_branch\":\"\(j.branch)\",\"name\":\"test\",\"runner_name\":\"\(j.runnerName)\"}"
	}

	private func json(_ r: Run) -> String {
		"{\"id\":\(r.id),\"event\":\"\(r.event)\",\"head_branch\":\"\(r.branch)\",\"updated_at\":\"\(r.updatedAt)\"}"
	}

	/// One page of `items`, as GitHub pages: `per_page` (default 30) and `page` (from 1).
	private func page(_ items: [String], _ query: [String: String]) -> [String] {
		let per = Int(query["per_page"] ?? "") ?? 30
		let page = Int(query["page"] ?? "") ?? 1
		let start = min((page - 1) * per, items.count)
		return Array(items[start..<min(start + per, items.count)])
	}

	func send(method: String, path: String, query: [String: String], body: Data?, token: String) throws -> GitHubResponse {
		let (status, headers, out): (Int, [String: String], String) = m.withLock {
			_calls.append(Call(method: method, path: path, query: query, body: body.map { String(decoding: $0, as: UTF8.self) } ?? "", token: token))
			if let s = _failStatus { return (s, [:], "{\"message\":\"Bad credentials\"}") }
			if let ok = _tokens, !ok.contains(token) { return (401, [:], "{\"message\":\"Bad credentials\"}") }
			if let i = _canned.firstIndex(where: { "\(method) \(path)".contains($0.match) }) {
				let c = _canned[i]
				_canned[i].times -= 1
				if _canned[i].times <= 0 { _canned.remove(at: i) }
				return (c.status, c.headers, c.body)
			}
			let parts = path.split(separator: "/").map(String.init)
			switch (method, path) {
			case ("GET", "/user"): return (200, [:], "{\"login\":\"octocat\"}")
			case ("GET", "/repos/acme/App"): return (200, [:], "{\"default_branch\":\"\(_defaultBranch)\"}")
			case ("GET", "/repos/acme/App/actions/runs"):
				let runs = _runs.filter { query["status"] == nil || $0.status == query["status"] }.map(json)
				return (200, [:], "{\"total_count\":\(runs.count),\"workflow_runs\":[\(page(runs, query).joined(separator: ","))]}")
			case ("POST", "/repos/acme/App/actions/runners/generate-jitconfig"):
				struct B: Decodable { var name: String }
				let name = body.flatMap { try? JSONDecoder().decode(B.self, from: $0) }?.name ?? ""
				if _runnerNames.values.contains(name) { return (409, [:], "{\"message\":\"Already exists - A runner with the name \(name) already exists.\"}") }
				_runnerCounter += 1
				_runnerNames[_runnerCounter] = name
				return (201, [:], "{\"runner\":{\"id\":\(_runnerCounter)},\"encoded_jit_config\":\"JIT\(_runnerCounter)\"}")
			default:
				// /repos/acme/App/actions/runs/<run>/jobs
				if method == "GET", parts.count == 7, parts[4] == "runs", parts[6] == "jobs", let run = Int(parts[5]) {
					let jobs = _jobs.filter { $0.run == run }.map(json)
					return (200, [:], "{\"total_count\":\(jobs.count),\"jobs\":[\(page(jobs, query).joined(separator: ","))]}")
				}
				// /repos/acme/App/actions/jobs/<id>
				if method == "GET", parts.count == 6, parts[4] == "jobs", let id = Int(parts[5]), let j = _jobs.first(where: { $0.id == id }) {
					return (200, [:], json(j))
				}
				// /repos/acme/App/actions/runners/<id>
				if parts.count == 6, parts[4] == "runners", let id = Int(parts[5]), _runnerNames[id] != nil {
					if method == "DELETE" {
						_runnerNames[id] = nil
						return (204, [:], "")
					}
					let name = _runnerNames[id]
					let busy = _busy.contains(id) || _jobs.contains { $0.runnerName == name && $0.status == "in_progress" }
					if method == "GET" { return (200, [:], "{\"id\":\(id),\"busy\":\(busy)}") }
				}
				return (404, [:], "{\"message\":\"Not Found\"}")
			}
		}
		return GitHubResponse(status: status, body: Data(out.utf8), headers: headers)
	}
}

final class FakeLauncher: CapsuleRunnerLauncher, @unchecked Sendable {
	private let m = Monitor()
	private var _runs: [(Lease, String)] = []
	private var _running: Set<String> = []
	private var _stops: [String] = []
	private var _forgotten: [String] = []
	var exitCode: Int32 = 0
	var failRun = false
	var folder: String? = "/tmp/stage"
	var runSeconds: Double = 0
	/// When the runner starts and when it ends (not when it fails or is stopped): (lease, JIT config).
	var onStart: (@Sendable (Lease, String) -> Void)?
	var onFinish: (@Sendable (Lease, String) -> Void)?
	var runs: [(lease: Lease, jit: String)] { m.withLock { _runs.map { ($0.0, $0.1) } } }
	/// Leases whose runner was stopped.
	var stops: [String] { m.withLock { _stops } }
	var forgotten: [String] { m.withLock { _forgotten } }
	func forgetLease(_ id: String) { m.withLock { _forgotten.append(id) } }
	struct Boom: Error {}
	func prepareFolder(job: CIJob) throws -> String? { folder }
	func runRunner(lease: Lease, jitConfig: String) throws -> Int32 {
		let deadline = nowSeconds() + runSeconds
		m.withLock {
			_runs.append((lease, jitConfig))
			_running.insert(lease.id)
		}
		if failRun {
			m.withLock { _ = _running.remove(lease.id) }
			throw Boom()
		}
		onStart?(lease, jitConfig)
		let stopped: Bool = m.withLock {
			while !_stops.contains(lease.id) && nowSeconds() < deadline { m.wait(until: deadline) }
			_running.remove(lease.id)
			return _stops.contains(lease.id)
		}
		if stopped { return 143 }  // SIGTERM
		onFinish?(lease, jitConfig)
		return exitCode
	}
	func stopRunner(lease: String) -> Bool {
		m.withLock {
			guard _running.contains(lease) else { return false }
			_stops.append(lease)
			m.broadcast()
			return true
		}
	}
}

/// `ci-app-11` -> 11.
func jobID(_ lease: Lease) -> Int { Int(lease.name?.split(separator: "-").last ?? "") ?? 0 }

final class FakeClock: CIClock, @unchecked Sendable {
	static let start: Double = 1_800_000_000
	private let m = Monitor()
	private var t = FakeClock.start
	func now() -> Date { m.withLock { Date(timeIntervalSince1970: t) } }
	func sleep(seconds: Double) { usleep(2_000) }  // `run()` loops without hammering the mock
	func advance(_ s: Double) { m.withLock { t += s } }
}

final class LogBox: @unchecked Sendable {
	private let m = Monitor()
	private var lines: [String] = []
	func add(_ s: String) { m.withLock { lines.append(s) } }
	var all: [String] { m.withLock { lines } }
}

private func tempHome() -> String {
	var t = Array("/tmp/cryo-ci-XXXXXX".utf8CString)
	_ = mkdtemp(&t)
	return String(decoding: t.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

private struct Rig {
	var gh = MockGitHub()
	var launcher = FakeLauncher()
	var bay: FakeBay
	var home = tempHome()
	var log = LogBox()
	var clock = FakeClock()
	var poller: CIPoller

	init(
		capacity: Int = 2, labels: [String] = ["cryo", "cryo-fake-image"], tokens: (any TokenStore)? = nil,
		configure: (inout CIConfig) -> Void = { _ in }
	) throws {
		bay = FakeBay(capacity: capacity)
		try bay.start()
		var cfg = CIConfig(repos: ["acme/App"], offeredLabels: labels)
		cfg.leaseWaitS = 5
		configure(&cfg)
		let client = CryoClient(target: CryoTarget(endpoint: .unix(path: bay.socketPath)))
		let log = self.log
		let gh = self.gh
		launcher.onStart = { lease, jit in gh.runnerTakes(jit: jit, job: jobID(lease)) }
		launcher.onFinish = { lease, jit in gh.runnerFinished(jit: jit, job: jobID(lease)) }
		var reload: (@Sendable () -> String?)?
		if let tokens { reload = { (try? tokens.load()) ?? nil } }
		poller = CIPoller(
			config: cfg, api: GitHubAPI(transport: gh, token: "tok"), bay: client, launcher: launcher,
			store: CIStateStore(home: home), clock: clock, hostName: "Mini-1.local", reloadToken: reload, log: { log.add($0) })
	}

	func runOnce() {
		poller.tick()
		#expect(poller.waitForIdle(timeout: 10))
	}
}

// MARK: tests

@Suite struct LabelTests {
	@Test func subsetRule() {
		let offered = ["cryo", "cryo-xcode-27.2", "cryo-macos-27"]
		#expect(CIRules.matches(labels: ["cryo-xcode-27.2"], offered: offered))
		#expect(CIRules.matches(labels: ["cryo-macos-27"], offered: offered))
		#expect(CIRules.matches(labels: ["cryo"], offered: offered))
		#expect(CIRules.matches(labels: ["self-hosted", "cryo", "cryo-xcode-27.2"], offered: offered))
		#expect(CIRules.matches(labels: ["CRYO-XCODE-27.2"], offered: offered))
		#expect(!CIRules.matches(labels: ["cryo-xcode-26.4"], offered: offered))  // an Xcode this bay hasn't
		#expect(!CIRules.matches(labels: ["self-hosted"], offered: offered))  // no cryo label
		#expect(!CIRules.matches(labels: ["self-hosted", "cryo", "gpu"], offered: offered))  // unknown label
		#expect(!CIRules.matches(labels: ["macos-latest"], offered: offered))
		#expect(!CIRules.matches(labels: [], offered: offered))
	}

	@Test func derivedValues() {
		#expect(CIRules.cacheName("acme/App") == "app")
		#expect(CIRules.idleSeconds(timeoutMinutes: 360) == 370 * 60)
		#expect(CIRules.idleSeconds(timeoutMinutes: 100_000) == 24 * 3600)
		#expect(CIRules.idleSeconds(timeoutMinutes: Int.max) == 24 * 3600)
		#expect(CIRules.shortHost("Mini-1.local") == "mini-1")
		#expect(CIRules.mayWriteCache(event: "push", headBranch: "main", defaultBranch: "main"))
		#expect(!CIRules.mayWriteCache(event: "pull_request", headBranch: "main", defaultBranch: "main"))
		#expect(!CIRules.mayWriteCache(event: "pull_request_target", headBranch: "main", defaultBranch: "main"))
		#expect(!CIRules.mayWriteCache(event: "push", headBranch: "dev", defaultBranch: "main"))
	}
}

@Suite struct PollerTests {
	@Test func queuedJobRunsAndReleases() throws {
		let r = try Rig()
		defer { r.bay.stop() }
		r.gh.queue()
		r.runOnce()
		let jit = r.gh.calls("POST", "generate-jitconfig")
		#expect(jit.count == 1)
		#expect(jit[0].body.contains("\"name\":\"cryo-mini-1-11-"))
		#expect(jit[0].body.contains("\"labels\":[\"cryo-fake-image\"]"))
		#expect(jit[0].body.contains("\"runner_group_id\":1"))
		#expect(jit[0].body.contains("\"work_folder\":\"_work\""))
		let req = try #require(r.bay.lastLeaseRequest)
		#expect(req.cache == "app")
		#expect(req.name == "ci-app-11")
		#expect(req.idleS == (360 + 10) * 60)
		#expect(req.folder == "/tmp/stage")
		#expect(r.launcher.runs.count == 1)
		#expect(r.launcher.runs[0].jit == "JIT101")
		#expect(r.launcher.runs[0].lease.id == "L1")
		#expect(r.bay.releases == [.init(id: "L1", saveCache: true)])
		// the queued-runs query
		let q = r.gh.calls("GET", "/actions/runs").first { $0.query["status"] != nil }
		#expect(q?.query["status"] == "queued")
		#expect(q?.query["per_page"] == "100")
		#expect(q?.query["page"] == "1")
		// in-progress runs too, for jobs waiting on `needs:`
		#expect(r.gh.calls("GET", "/actions/runs").contains { $0.query["status"] == "in_progress" })
		#expect(r.bay.releases.count == 1)
	}

	@Test func leaseIsRenewedWhileTheRunnerRuns() throws {
		let r = try Rig { $0.renewInterval = 0.05 }
		defer { r.bay.stop() }
		r.launcher.runSeconds = 0.4
		r.gh.queue()
		r.runOnce()
		let renews = r.bay.renews
		#expect(renews.count >= 3)
		#expect(Set(renews) == ["L1"])
		usleep(200_000)
		#expect(r.bay.renews.count == renews.count)  // stopped after release
	}

	@Test func saveCacheTrustRule() throws {
		for (event, branch, expected) in [
			("push", "main", true), ("pull_request", "main", false), ("push", "feature/x", false), ("pull_request_target", "main", false),
		] {
			let r = try Rig()
			defer { r.bay.stop() }
			r.gh.queue(event: event, branch: branch)
			r.runOnce()
			#expect(r.bay.releases.map(\.saveCache) == [expected], "\(event) \(branch)")
		}
	}

	@Test func nonDefaultDefaultBranch() throws {
		let r = try Rig()
		defer { r.bay.stop() }
		r.gh.setDefaultBranch("trunk")
		r.gh.queue(branch: "trunk")
		r.runOnce()
		#expect(r.bay.releases.map(\.saveCache) == [true])
	}

	@Test func nonMatchingJobsAreSkipped() throws {
		let r = try Rig()
		defer { r.bay.stop() }
		r.gh.queue(run: 1, job: 11, labels: ["self-hosted", "linux"])
		r.gh.queue(run: 2, job: 12, labels: ["self-hosted", "cryo", "gpu"])
		r.gh.queue(run: 3, job: 13, labels: ["self-hosted", "cryo"], status: "in_progress")
		r.runOnce()
		#expect(r.gh.calls("POST", "generate-jitconfig").isEmpty)
		#expect(r.bay.leases.isEmpty)
		let s = r.poller.snapshot
		#expect(s.seen.map(\.action) == ["skipped", "skipped"])
		#expect(s.seen.map(\.job) == [11, 12])
	}

	@Test func sameJobNotHandledTwice() throws {
		let r = try Rig()
		defer { r.bay.stop() }
		r.gh.queue()
		r.runOnce()
		r.runOnce()
		r.runOnce()
		#expect(r.gh.calls("POST", "generate-jitconfig").count == 1)
		#expect(r.launcher.runs.count == 1)
	}

	/// The capsule comes first: while the bay is full or down, nothing is registered on GitHub.
	@Test func noCapsuleRegistersNoRunnerAndRetries() throws {
		let r = try Rig(capacity: 0) { $0.leaseWaitS = 0 }
		defer { r.bay.stop() }
		r.gh.queue()
		r.runOnce()
		r.runOnce()  // retried
		#expect(r.bay.lastLeaseRequest?.name == "ci-app-11")
		#expect(r.gh.calls("POST", "generate-jitconfig").isEmpty)
		#expect(r.gh.calls("DELETE", "/actions/runners/").isEmpty)
		#expect(r.launcher.runs.isEmpty)
		#expect(r.poller.snapshot.running.isEmpty)
		#expect(r.log.all.filter { $0.contains("no capsule, will retry") }.count == 2)
	}

	@Test func runnerConfigFailureReleasesTheLeaseAndRetries() throws {
		let r = try Rig()
		defer { r.bay.stop() }
		r.gh.queue()
		r.gh.respond("POST /repos/acme/App/actions/runners/generate-jitconfig", status: 500, body: "{\"message\":\"boom\"}")
		r.runOnce()
		#expect(r.bay.releases == [.init(id: "L1", saveCache: false)])
		#expect(r.launcher.runs.isEmpty)
		r.runOnce()
		#expect(r.launcher.runs.map(\.lease.id) == ["L2"])
		#expect(r.bay.releases.map(\.id) == ["L1", "L2"])
	}

	/// A runner registered by an earlier attempt that could not be deleted does not block the next.
	@Test func runnerNamesDifferPerAttempt() throws {
		let r = try Rig()
		defer { r.bay.stop() }
		r.launcher.failRun = true
		r.gh.queue()
		r.gh.respond("DELETE /repos/acme/App/actions/runners/", status: 500, times: 10)
		r.runOnce()
		r.runOnce()
		let names = r.gh.calls("POST", "generate-jitconfig").map(\.body)
		#expect(names.count == 2)
		#expect(names[0] != names[1])
		#expect(names.allSatisfy { $0.contains("\"name\":\"cryo-mini-1-11-") })
		#expect(r.launcher.runs.count == 2)  // no 409 for the second
		#expect(r.gh.runners.count == 2)  // both left registered by the failing deletes
	}

	/// ssh failed (exit 255), or the lease files could not be written: the job is still queued on
	/// GitHub, so it is tried again, a bounded number of times.
	@Test func runnerThatNeverStartedIsRetriedAFewTimes() throws {
		let r = try Rig { $0.maxRunnerAttempts = 3 }
		defer { r.bay.stop() }
		r.launcher.failRun = true
		r.gh.queue()
		for _ in 0..<5 { r.runOnce() }
		#expect(r.launcher.runs.count == 3)
		#expect(r.bay.releases.map(\.saveCache) == [false, false, false])  // nothing ran: no cache write
		#expect(r.bay.leases.isEmpty)
		#expect(r.gh.runners.isEmpty)  // each unused runner deleted
		let results = r.poller.snapshot.results.map(\.conclusion)
		#expect(results.count == 3)
		#expect(results.allSatisfy { $0.hasPrefix("error:") })
		#expect(results[0].contains("will retry (1 of 3 attempts)"))
		#expect(results[2].contains("giving up after 3 attempts"))
	}

	/// A runner that took the job and then failed (ssh dropped mid-job) is not retried.
	@Test func runnerFailingAfterTakingTheJobIsNotRetried() throws {
		let r = try Rig()
		defer { r.bay.stop() }
		r.gh.queue()
		r.launcher.onFinish = nil
		r.gh.respond("GET /repos/acme/App/actions/jobs/11", status: 200, body: "{\"id\":11,\"status\":\"in_progress\",\"runner_name\":\"x\"}", times: 10)
		r.launcher.exitCode = 1
		r.runOnce()
		r.runOnce()
		#expect(r.launcher.runs.count == 1)
		#expect(r.poller.snapshot.results.map(\.conclusion) == ["exit 1"])
		#expect(r.bay.releases.map(\.saveCache) == [true])
	}

	/// The job was cancelled while its runner waited: the runner is stopped and the capsule freed
	/// instead of idling until timeout-minutes + 10 min.
	@Test func cancelledJobStopsItsRunner() throws {
		let r = try Rig { $0.watchInterval = 0.05 }
		defer { r.bay.stop() }
		r.launcher.runSeconds = 20
		r.launcher.onStart = { _, _ in }  // the runner never gets the job
		r.gh.queue()
		r.poller.tick()
		usleep(100_000)
		r.gh.setJob(11, status: "completed", conclusion: "cancelled")
		let start = nowSeconds()
		#expect(r.poller.waitForIdle(timeout: 10))
		#expect(nowSeconds() - start < 5)
		#expect(r.launcher.stops == ["L1"])
		let res = try #require(r.poller.snapshot.results.first)
		#expect(res.conclusion == "stopped: the job is cancelled")
		#expect(r.bay.releases == [.init(id: "L1", saveCache: false)])
		#expect(r.gh.runners.isEmpty)  // the unused runner deleted
	}

	@Test func jobTakenByAnotherRunnerStopsOurs() throws {
		let r = try Rig { $0.watchInterval = 0.05 }
		defer { r.bay.stop() }
		r.launcher.runSeconds = 20
		r.launcher.onStart = { _, _ in }
		r.gh.queue()
		r.poller.tick()
		r.gh.setJob(11, status: "in_progress", runnerName: "GitHub Actions 7")
		#expect(r.poller.waitForIdle(timeout: 10))
		#expect(r.launcher.stops == ["L1"])
		#expect(r.poller.snapshot.results.first?.conclusion == "stopped: the job went to runner GitHub Actions 7")
	}

	/// A JIT runner takes any queued job with its labels; while it runs one, it is left alone.
	@Test func busyRunnerIsNotStopped() throws {
		let r = try Rig { $0.watchInterval = 0.05 }
		defer { r.bay.stop() }
		r.launcher.runSeconds = 0.6
		r.launcher.onStart = { _, _ in }
		r.gh.queue()
		r.poller.tick()
		r.gh.setJob(11, status: "in_progress", runnerName: "GitHub Actions 7")
		r.gh.setRunnerBusy(101, true)
		#expect(r.poller.waitForIdle(timeout: 10))
		#expect(r.launcher.stops.isEmpty)
		#expect(r.poller.snapshot.results.first?.conclusion == "exit 0")
	}

	/// Our own runner finishing its job: one look at "completed" is not enough to stop it.
	@Test func ownRunnerIsNotStoppedOnItsOwnJob() throws {
		let r = try Rig { $0.watchInterval = 0.05 }
		defer { r.bay.stop() }
		r.launcher.runSeconds = 0.5
		r.gh.queue()
		r.runOnce()
		#expect(r.launcher.stops.isEmpty)
		#expect(r.poller.snapshot.results.first?.conclusion == "exit 0")
		#expect(r.gh.calls("GET", "/actions/jobs/11").count >= 3)
	}

	@Test func runnerThrowingStillReleases() throws {
		let r = try Rig { $0.maxRunnerAttempts = 1 }
		defer { r.bay.stop() }
		r.launcher.failRun = true
		r.gh.queue()
		r.runOnce()
		#expect(r.bay.releases.count == 1)
		let res = try #require(r.poller.snapshot.results.first)
		#expect(res.conclusion.hasPrefix("error:"))
		#expect(r.bay.leases.isEmpty)
	}

	@Test func idleIsCappedAt24h() throws {
		let r = try Rig { $0.timeoutMinutes["acme/App"] = 100_000 }
		defer { r.bay.stop() }
		r.gh.queue()
		r.runOnce()
		#expect(r.bay.lastLeaseRequest?.idleS == 24 * 3600)
	}

	@Test func perRepoTimeoutOverride() throws {
		let r = try Rig { $0.timeoutMinutes["acme/App"] = 30 }
		defer { r.bay.stop() }
		r.gh.queue()
		r.runOnce()
		#expect(r.bay.lastLeaseRequest?.idleS == 40 * 60)
	}

	@Test func githubUnauthorizedIsClear() throws {
		let r = try Rig()
		defer { r.bay.stop() }
		r.gh.failAll(with: 401)
		r.runOnce()
		#expect(r.log.all.contains { $0.contains("GitHub rejected the token (401)") && $0.contains("cryo ci github login") })
		let api = GitHubAPI(transport: r.gh, token: "x")
		do {
			_ = try api.queuedRuns("acme/App")
			Issue.record("expected 401")
		} catch let e as GitHubError {
			guard case .unauthorized = e else {
				Issue.record("wrong case \(e)")
				return
			}
		}
	}

	/// After `cryo ci github login` rotates the token, the running agent picks it up on the next 401.
	@Test func rotatedTokenIsReReadOn401() throws {
		final class Stored: TokenStore, @unchecked Sendable {
			private let m = Monitor()
			private var _token = "tok"
			private var _reads = 0
			var reads: Int { m.withLock { _reads } }
			var place: String { "memory" }
			func load() throws -> String? {
				m.withLock {
					_reads += 1
					return _token
				}
			}
			func save(_ token: String) throws { m.withLock { _token = token } }
		}
		let stored = Stored()
		let r = try Rig(tokens: stored)
		defer { r.bay.stop() }
		r.gh.acceptTokens(["new"])
		r.gh.queue()
		r.runOnce()
		r.runOnce()
		#expect(stored.reads == 2)  // once per tick, not once per call
		#expect(r.log.all.filter { $0.contains("GitHub rejected the token (401)") }.count == 1)  // not every tick
		#expect(r.log.all.contains { $0.contains("repeats every 10 min") })
		r.clock.advance(601)
		r.runOnce()
		#expect(r.log.all.filter { $0.contains("GitHub rejected the token (401)") }.count == 2)
		try stored.save("new")
		r.runOnce()
		#expect(r.log.all.contains { $0.contains("the stored token changed") })
		#expect(r.log.all.contains { $0.contains("accepts the token again") })
		#expect(r.launcher.runs.count == 1)
		#expect(r.gh.calls("POST", "generate-jitconfig").map(\.token) == ["new"])
	}

	@Test func statusCodesMap() throws {
		let gh = MockGitHub()
		let api = GitHubAPI(transport: gh, token: "x")
		gh.failAll(with: 403)
		#expect(throws: GitHubError.self) { try api.defaultBranch("a/b") }
		gh.failAll(with: 404)
		do { _ = try api.defaultBranch("a/b") } catch let e as GitHubError {
			guard case .notFound = e else {
				Issue.record("\(e)")
				return
			}
		}
		gh.failAll(with: 422)
		do { _ = try api.generateJITConfig("a/b", name: "n", labels: []) } catch let e as GitHubError {
			guard case .invalid = e else {
				Issue.record("\(e)")
				return
			}
		}
	}

	@Test func stateFile() throws {
		let r = try Rig()
		defer { r.bay.stop() }
		r.gh.queue()
		r.gh.queue(run: 2, job: 12, labels: ["linux"])
		r.runOnce()
		let path = r.home + "/.cryo/ci-state.json"
		#expect(fileMode(path) == 0o600)
		let st = try #require(CIStateStore(home: r.home).load())
		#expect(st.seenCount == 2)
		#expect(st.running.isEmpty)
		#expect(st.results.count == 1)
		#expect(st.results[0].job == 11)
		#expect(st.results[0].repo == "acme/App")
		#expect(st.results[0].conclusion == "exit 0")
		#expect(st.results[0].cacheSaved)
		let text = renderCIStatus(st)
		#expect(text.contains("jobs seen: 2"))
		#expect(text.contains("job 11  exit 0  cache saved"))
		#expect(renderCIStatus(nil).contains("no CI state yet"))
	}

	/// SIGTERM (launchd) calls `stop()`: running runners are stopped, their capsules released
	/// without a cache write, their runners deleted, and `run()` returns.
	@Test func stopWindsDownRunningJobs() throws {
		let r = try Rig()
		defer { r.bay.stop() }
		r.launcher.runSeconds = 30
		r.gh.queue()
		let done = LogBox()
		let poller = r.poller
		spawnThread {
			poller.run()
			done.add("returned")
		}
		let start = nowSeconds()
		while r.launcher.runs.isEmpty && nowSeconds() - start < 5 { usleep(10_000) }
		#expect(r.launcher.runs.count == 1)
		r.poller.stop()
		while done.all.isEmpty && nowSeconds() - start < 10 { usleep(10_000) }
		#expect(done.all == ["returned"])
		#expect(nowSeconds() - start < 10)
		#expect(r.launcher.stops == ["L1"])
		#expect(r.bay.releases == [.init(id: "L1", saveCache: false)])
		#expect(r.gh.runners.isEmpty)
		let st = try #require(CIStateStore(home: r.home).load())
		#expect(st.running.isEmpty)
		#expect(st.results.map(\.conclusion) == ["stopped: cryo ci is shutting down"])
		#expect(r.gh.calls("POST", "generate-jitconfig").count == 1)
	}

	/// A process that was killed left `running` entries: the next start loads the state (counts
	/// and results survive), releases the leftover capsules and deletes the leftover runners.
	@Test func startCleansUpWhatAKilledProcessLeft() throws {
		// What the bay and GitHub still hold for the dead process.
		let bay = FakeBay()
		try bay.start()
		defer { bay.stop() }
		let client = CryoClient(target: CryoTarget(endpoint: .unix(path: bay.socketPath)))
		let gh = MockGitHub()
		let api = GitHubAPI(transport: gh, token: "tok")
		let l1 = try client.createLease(LeaseRequest(name: "ci-app-11"))
		let l2 = try client.createLease(LeaseRequest(name: "ci-app-12"))  // granted after it died
		let runner = try api.generateJITConfig("acme/App", name: "cryo-mini-1-11-abc", labels: ["cryo"])
		var old = CIState()
		old.seenCount = 7
		old.running = [
			.init(job: 11, repo: "acme/App", lease: l1.id, since: Date(), runner: runner.runnerID),
			.init(job: 12, repo: "acme/App", lease: nil, since: Date()),
		]
		old.results = [.init(job: 9, repo: "acme/App", conclusion: "exit 0", cacheSaved: true, finishedAt: Date())]
		let home = tempHome()
		try CIStateStore(home: home).save(old)

		let launcher = FakeLauncher()
		let log = LogBox()
		let poller = CIPoller(
			config: CIConfig(repos: ["acme/App"], offeredLabels: ["cryo"]), api: api, bay: client, launcher: launcher,
			store: CIStateStore(home: home), clock: FakeClock(), hostName: "Mini-1.local", log: { log.add($0) })
		#expect(poller.snapshot.seenCount == 7)
		poller.recover()
		#expect(Set(bay.releases.map(\.id)) == [l1.id, l2.id])
		#expect(bay.releases.allSatisfy { !$0.saveCache })
		#expect(bay.leases.isEmpty)
		#expect(Set(launcher.forgotten) == [l1.id, l2.id])
		#expect(gh.runners.isEmpty)
		let st = try #require(CIStateStore(home: home).load())
		#expect(st.running.isEmpty)
		#expect(st.seenCount == 7)
		#expect(st.results.map(\.job) == [9, 11, 12])
		#expect(st.results.last?.conclusion == "error: cryo ci stopped while it ran")
		#expect(renderCIStatus(st).contains("running: 0"))
	}

	@Test func maxConcurrentLeavesTheRestForLater() throws {
		let r = try Rig { $0.maxConcurrent = 1 }
		defer { r.bay.stop() }
		r.gh.queue(run: 1, job: 11)
		r.gh.queue(run: 2, job: 12)
		r.runOnce()
		#expect(r.launcher.runs.count == 1)
		r.runOnce()
		#expect(r.launcher.runs.count == 2)
	}

	/// "waiting" is logged when a job starts waiting, not on every tick it waits.
	@Test func waitingIsLoggedOnce() throws {
		let r = try Rig { $0.maxConcurrent = 1 }
		defer { r.bay.stop() }
		r.launcher.runSeconds = 1
		r.gh.queue(run: 1, job: 11)
		r.gh.queue(run: 2, job: 12)
		for _ in 0..<5 { r.poller.tick() }
		#expect(r.poller.waitForIdle(timeout: 10))
		#expect(r.log.all.filter { $0.contains("job 12") && $0.contains("waiting") }.count == 1)
	}

	@Test func runsAndJobsArePaged() throws {
		let r = try Rig()
		defer { r.bay.stop() }
		// 105 queued runs; the last one has 150 jobs, and only the last job is ours.
		for run in 1...104 { r.gh.queue(run: run, job: run, labels: ["linux"]) }
		for job in 1001...1149 { r.gh.queue(run: 105, job: job, labels: ["linux"]) }
		r.gh.queue(run: 105, job: 1150)
		r.runOnce()
		#expect(r.gh.calls("GET", "/actions/runs").filter { $0.query["status"] == "queued" }.map { $0.query["page"] } == ["1", "2"])
		#expect(r.gh.calls("GET", "/runs/105/jobs").map { $0.query["page"] } == ["1", "2"])
		#expect(r.launcher.runs.count == 1)
		#expect(r.bay.lastLeaseRequest?.name == "ci-app-1150")
	}

	/// A run whose jobs are all taken, skipped or running elsewhere is not re-read every tick.
	@Test func settledRunsAreNotReReadUntilTheyChange() throws {
		let r = try Rig()
		defer { r.bay.stop() }
		r.gh.queue(run: 1, job: 11, labels: ["linux"])
		r.gh.queue(run: 1, job: 12, labels: ["linux"], status: "in_progress")
		r.gh.queue(run: 2, job: 21, labels: ["linux"], status: "waiting")  // not settled: may still queue
		r.runOnce()
		r.runOnce()
		r.runOnce()
		#expect(r.gh.calls("GET", "/runs/1/jobs").count == 1)
		#expect(r.gh.calls("GET", "/runs/2/jobs").count == 3)
		r.gh.setRun(1, updatedAt: "t1")
		r.runOnce()
		#expect(r.gh.calls("GET", "/runs/1/jobs").count == 2)
		r.runOnce()
		#expect(r.gh.calls("GET", "/runs/1/jobs").count == 2)
		r.clock.advance(301)
		r.runOnce()
		#expect(r.gh.calls("GET", "/runs/1/jobs").count == 3)
	}

	@Test func spentRateLimitPausesUntilTheReset() throws {
		let r = try Rig()
		defer { r.bay.stop() }
		r.gh.queue()
		let reset = Int(FakeClock.start) + 120
		r.gh.respond(
			"GET /repos/acme/App/actions/runs", status: 403,
			headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": String(reset)],
			body: "{\"message\":\"API rate limit exceeded for user ID 1.\"}")
		r.runOnce()
		#expect(r.log.all.contains { $0.contains("GitHub rate limit hit") && $0.contains("no GitHub calls for 120 s") })
		#expect(r.gh.calls.count == 1)
		r.clock.advance(60)
		r.runOnce()
		#expect(r.gh.calls.count == 1)  // still paused
		r.clock.advance(61)
		r.runOnce()
		#expect(r.launcher.runs.count == 1)
	}

	@Test func secondaryRateLimitWaitsRetryAfterOrAMinute() throws {
		for (status, headers, message, wait) in [
			(429, ["retry-after": "30"], "slow down", 30),
			(403, ["retry-after": "45"], "You have exceeded a secondary rate limit.", 45),
			(403, [:], "You have exceeded a secondary rate limit.", 60),
		] {
			let r = try Rig()
			defer { r.bay.stop() }
			r.gh.queue()
			r.gh.respond("GET /repos/acme/App/actions/runs", status: status, headers: headers, body: "{\"message\":\"\(message)\"}")
			r.runOnce()
			#expect(r.log.all.contains { $0.contains("no GitHub calls for \(wait) s") }, "\(status) \(headers)")
			r.clock.advance(Double(wait) - 1)
			r.runOnce()
			#expect(r.gh.calls.count == 1)
			r.clock.advance(1)
			r.runOnce()
			#expect(r.launcher.runs.count == 1)
		}
	}

	@Test func plainForbiddenIsNotARateLimit() throws {
		let gh = MockGitHub()
		gh.respond("GET", status: 403, headers: ["x-ratelimit-remaining": "4000"], body: "{\"message\":\"Resource not accessible\"}")
		do {
			_ = try GitHubAPI(transport: gh, token: "x").defaultBranch("acme/App")
			Issue.record("expected 403")
		} catch let e as GitHubError {
			guard case .forbidden = e else {
				Issue.record("wrong case \(e)")
				return
			}
		}
	}

	#if os(macOS)
		/// GitHub answers with `max-age=60`; a poll must not be served from URLSession's cache.
		@Test func requestsSkipTheURLCache() throws {
			let req = try URLSessionGitHubTransport().request(method: "GET", path: "/repos/a/b/actions/runs", query: ["page": "2"], body: nil, token: "t")
			#expect(req.cachePolicy == .reloadIgnoringLocalCacheData)
			#expect(req.url?.absoluteString == "https://api.github.com/repos/a/b/actions/runs?page=2")
		}
	#endif

	@Test func defaultLabelsUseBayImage() throws {
		let bay = FakeBay()
		try bay.start()
		defer { bay.stop() }
		let c = CryoClient(target: CryoTarget(endpoint: .unix(path: bay.socketPath)))
		#if os(macOS)
			#expect(CIRules.defaultLabels(bay: c, macOSMajor: 27) == ["cryo", "cryo-fake-image", "cryo-macos-27"])
		#else
			#expect(CIRules.defaultLabels(bay: c, macOSMajor: 27) == ["cryo", "cryo-fake-image"])
		#endif
	}
}

@Suite struct TokenTests {
	@Test func writesPrivateFile() throws {
		let home = tempHome()
		let store = FileTokenStore(home: home)
		#expect(try store.load() == nil)
		try store.save("ghp_abc")
		#expect(fileMode(home + "/.cryo/github-token") == 0o600)
		#expect(fileMode(home + "/.cryo") == 0o700)
		#expect(try store.load() == "ghp_abc")
		try store.save("ghp_new")
		#expect(try store.load() == "ghp_new")
		#expect(fileMode(home + "/.cryo/github-token") == 0o600)
	}

	#if os(macOS)
		/// The real login Keychain, under a service name of its own that the test removes again.
		@Test func keychainSavesReadsAndReplacesTheOldFile() throws {
			let home = tempHome()
			let store = KeychainTokenStore(home: home, service: "dev.rizwan.cryo.ci.test.\(getpid())")
			defer { try? store.delete() }
			#expect(try store.load() == nil)
			try FileTokenStore(home: home).save("ghp_old_file")
			#expect(try store.load() == "ghp_old_file")  // tokens saved before the Keychain still work
			try store.save("ghp_dummy_1")
			#expect(!pathExists(home + "/.cryo/github-token"))
			#expect(try store.load() == "ghp_dummy_1")
			try store.save("ghp_dummy_2")
			#expect(try store.load() == "ghp_dummy_2")
			#expect(try KeychainTokenStore(home: tempHome(), service: store.service).load() == "ghp_dummy_2")
			#expect(throws: KeychainError.self) { try store.save("ghp_x -s other") }  // would be parsed by `security -i`
			#expect(try store.load() == "ghp_dummy_2")
			try store.delete()
			#expect(try store.load() == nil)
		}
	#endif
}

@Suite struct CLITests {
	private func ctx(home: String, input: [String] = [], out: LogBox, err: LogBox) -> CLIContext {
		var lines = input
		return CLIContext(
			home: home, cwd: "/", environment: [:], target: CryoTarget(endpoint: .unix(path: "/nonexistent")),
			out: { out.add($0) }, err: { err.add($0) }, readLine: { lines.isEmpty ? nil : lines.removeFirst() }, exec: { _ in 0 })
	}

	private func ci(_ c: CLIContext, _ args: [String], gh: MockGitHub = MockGitHub(), launchctl: FakeCommands = FakeCommands()) -> Int32 {
		CryoCICLI.ciCommand(
			c, args, transport: { gh }, tokens: FileTokenStore(home: c.home),
			agent: CIAgent(home: c.home, uid: 501, commands: launchctl))
	}

	@Test func macOSOnlyOnLinux() {
		#if !os(macOS)
			let out = LogBox()
			let err = LogBox()
			let code = CryoCICLI.run(["github", "--repo", "a/b"], ctx(home: tempHome(), out: out, err: err))
			#expect(code == 1)
			#expect(err.all.joined() == "cryo-ci: macOS bay only\n")
		#endif
	}

	@Test func helpExitsZero() {
		for flag in ["--help", "-h", "help"] {
			let out = LogBox()
			let err = LogBox()
			#expect(ci(ctx(home: tempHome(), out: out, err: err), [flag]) == 0, "\(flag)")
			#expect(out.all.joined() == Help.main, "\(flag)")
			#expect(err.all.isEmpty, "\(flag)")
		}
	}

	@Test func loginSavesToken() {
		let gh = MockGitHub()
		let home = tempHome()
		let out = LogBox()
		let err = LogBox()
		let code = ci(ctx(home: home, input: ["  ghp_x  "], out: out, err: err), ["github", "login"], gh: gh)
		#expect(code == 0)
		#expect(out.all.joined().contains("logged in to GitHub as octocat"))
		#expect((try? FileTokenStore(home: home).load()) == "ghp_x")
		#expect(fileMode(home + "/.cryo/github-token") == 0o600)
	}

	@Test func loginRejectsBadToken() {
		let gh = MockGitHub()
		gh.failAll(with: 401)
		let home = tempHome()
		let out = LogBox()
		let err = LogBox()
		let code = ci(ctx(home: home, out: out, err: err), ["github", "login", "--token", "bad"], gh: gh)
		#expect(code == 1)
		#expect(err.all.joined().contains("401"))
		#expect(!pathExists(home + "/.cryo/github-token"))
	}

	@Test func githubNeedsRepoAndToken() {
		let out = LogBox()
		let err = LogBox()
		let c = ctx(home: tempHome(), out: out, err: err)
		#expect(ci(c, ["github"]) == 2)
		#expect(ci(c, ["github", "--repo", "nope"]) == 2)
		#expect(ci(c, ["github", "--repo", "a/b"]) == 2)  // no token
		#expect(err.all.joined().contains("no GitHub token"))
	}

	@Test func status() throws {
		let home = tempHome()
		let out = LogBox()
		let err = LogBox()
		let c = ctx(home: home, out: out, err: err)
		#expect(ci(c, ["status"]) == 0)
		#expect(out.all.joined().contains("no CI state yet"))
		var s = CIState()
		s.seenCount = 3
		try CIStateStore(home: home).save(s)
		let out2 = LogBox()
		let c2 = ctx(home: home, out: out2, err: err)
		#expect(ci(c2, ["status", "--json"]) == 0)
		#expect(out2.all.joined().contains("\"seen_count\" : 3"))
	}

	/// `cryo bay install` and `cryo-ci install` put this path in their LaunchAgents: a Homebrew keg
	/// path is gone after `brew upgrade`, the prefix's `opt/` symlink is not.
	@Test func launchAgentsRunHomebrewsOptSymlinkNotTheKeg() {
		#expect(launchAgentExecutablePath("/opt/homebrew/Cellar/cryo/0.1.0/bin/cryo") == "/opt/homebrew/opt/cryo/bin/cryo")
		#expect(launchAgentExecutablePath("/usr/local/Cellar/cryo/0.1.0_1/bin/cryo") == "/usr/local/opt/cryo/bin/cryo")
		#expect(launchAgentExecutablePath("/Users/me/brew/Cellar/cryo/HEAD-346bac9/bin/cryo") == "/Users/me/brew/opt/cryo/bin/cryo")
		// Not a keg: kept as is.
		#expect(launchAgentExecutablePath("/Users/me/.cryo/bin/cryo") == "/Users/me/.cryo/bin/cryo")
		#expect(launchAgentExecutablePath("/opt/homebrew/opt/cryo/bin/cryo") == "/opt/homebrew/opt/cryo/bin/cryo")
		#expect(launchAgentExecutablePath("/Users/me/Cellar/cryo/bin/cryo") == "/Users/me/Cellar/cryo/bin/cryo")
		#expect(launchAgentExecutablePath("/opt/homebrew/Cellar/cryo/0.1.0/libexec/cryo") == "/opt/homebrew/Cellar/cryo/0.1.0/libexec/cryo")
	}

	@Test func installWritesTheAgentAndLoadsIt() throws {
		let home = tempHome()
		let out = LogBox()
		let err = LogBox()
		let c = ctx(home: home, out: out, err: err)
		let launchctl = FakeCommands()
		let plist = home + "/Library/LaunchAgents/dev.rizwan.cryo.ci.plist"
		// The agent does not see the shell's GITHUB_TOKEN, so a stored token is required.
		#expect(ci(c, ["install", "--repo", "a/b"], launchctl: launchctl) == 2)
		#expect(err.all.joined().contains("no stored GitHub token"))
		#expect(ci(c, ["install", "--repo", "nope"], launchctl: launchctl) == 2)
		#expect(launchctl.argvs.isEmpty && !pathExists(plist))

		try FileTokenStore(home: home).save("ghp_dummy")
		#expect(ci(c, ["install", "--repo", "a/b", "--repo", "c/d&e", "--labels", "cryo,x", "--timeout-minutes", "30"], launchctl: launchctl) == 0)
		#expect(
			launchctl.argvs == [
				["/bin/launchctl", "bootout", "gui/501/dev.rizwan.cryo.ci"],
				["/bin/launchctl", "bootstrap", "gui/501", plist],
			])
		let text = try #require(readTextFile(plist))
		#expect(fileMode(plist) == 0o644)
		let args =
			"</string>\n\t\t<string>github</string>\n\t\t<string>--repo</string>\n\t\t<string>a/b</string>\n"
			+ "\t\t<string>--repo</string>\n\t\t<string>c/d&amp;e</string>\n\t\t<string>--labels</string>\n\t\t<string>cryo,x</string>\n"
			+ "\t\t<string>--timeout-minutes</string>\n\t\t<string>30</string>\n\t</array>"
		#expect(text.contains(args))
		#expect(text.contains("<string>\(home)/.cryo/ci.log</string>"))
		#expect(out.all.joined().contains("installed LaunchAgent dev.rizwan.cryo.ci"))

		let out2 = LogBox()
		#expect(ci(ctx(home: home, out: out2, err: err), ["uninstall"], launchctl: launchctl) == 0)
		#expect(launchctl.argvs.last == ["/bin/launchctl", "bootout", "gui/501/dev.rizwan.cryo.ci"])
		#expect(!pathExists(plist))
		#expect(out2.all.joined() == "removed LaunchAgent dev.rizwan.cryo.ci\n")
		launchctl.setOther { _ in CommandResult(exitCode: 3, stderr: "Boot-out failed: 3: No such process\n") }
		#expect(ci(ctx(home: home, out: out2, err: err), ["uninstall"], launchctl: launchctl) == 0)
		#expect(out2.all.last == "LaunchAgent dev.rizwan.cryo.ci was not installed\n")
	}
}
