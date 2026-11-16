import CryoAPI
import CryoClient
import CryoHTTP

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

/// The slice of the bay client the poller uses. `CryoClient` conforms.
public protocol BayClient: Sendable {
	func createLease(_ req: LeaseRequest) throws -> Lease
	func listLeases() throws -> [Lease]
	func release(_ id: String, saveCache: Bool) throws
	func renew(_ id: String) throws -> RenewResponse
	func status() throws -> Status
}

extension CryoClient: BayClient {}

public protocol CIClock: Sendable {
	func now() -> Date
	func sleep(seconds: Double)
}

public struct SystemCIClock: CIClock {
	public init() {}
	public func now() -> Date { Date(timeIntervalSince1970: nowSeconds()) }
	public func sleep(seconds: Double) {
		var ts = timespec(tv_sec: Int(seconds), tv_nsec: Int((seconds - Double(Int(seconds))) * 1e9))
		var rem = timespec()
		while nanosleep(&ts, &rem) != 0 && errno == EINTR { ts = rem }
	}
}

public struct CIConfig: Sendable {
	public var repos: [String]
	public var offeredLabels: [String]
	public var pollInterval: Double = 10
	/// How many jobs may be in flight at once (a hint: the bay has 2 capsules by default).
	public var maxConcurrent: Int = 2
	/// `--timeout-minutes` per repo. The jobs API does not return a job's `timeout-minutes`.
	public var timeoutMinutes: [String: Int] = [:]
	public var defaultTimeoutMinutes = 360
	/// `wait_s` of the lease request. A job we cannot place in time stays queued on GitHub.
	public var leaseWaitS = 600
	/// Seconds between renews of a running job's lease. The poller renews itself instead of relying
	/// on the runner holding an SSH connection open.
	public var renewInterval: Double = 60
	/// Seconds between looks at a running job: its runner is stopped once the job is cancelled,
	/// over, or taken by another runner. One GitHub call per running job.
	public var watchInterval: Double = 60
	/// Tries per job whose runner never took it (ssh failed, the runner did not start).
	public var maxRunnerAttempts = 3
	/// How long `run()` waits, once stopped, for job threads to release their capsules.
	public var shutdownTimeout: Double = 60
	/// A run whose jobs are all taken, skipped or past `queued` is not re-read until its
	/// `updated_at` moves, or this many seconds pass.
	public var runRefetchInterval: Double = 300

	public init(repos: [String], offeredLabels: [String]) {
		self.repos = repos
		self.offeredLabels = offeredLabels
	}
}

public enum CIRules {
	/// A job is ours when it asks for a cryo label (`cryo` or `cryo-…`, e.g. `runs-on:
	/// cryo-xcode-27.2`) and every label it asks for is one we offer (`self-hosted` is ignored).
	public static func matches(labels: [String], offered: [String]) -> Bool {
		let have = Set(labels.map { $0.lowercased() }).subtracting(["self-hosted"])
		let ok = Set(offered.map { $0.lowercased() })
		return have.contains { $0 == "cryo" || $0.hasPrefix("cryo-") } && have.isSubset(of: ok)
	}

	/// The cache name of a repo: `acme/App` becomes `app`.
	public static func cacheName(_ repo: String) -> String {
		(repo.split(separator: "/").last.map(String.init) ?? repo).lowercased()
	}

	/// Job `timeout-minutes` + 10 minutes, capped at 24 h.
	public static func idleSeconds(timeoutMinutes: Int) -> Int {
		min(min(max(timeoutMinutes, 1), 24 * 60) + 10, 24 * 60) * 60
	}

	/// Only runs on the default branch that are not from pull requests save the cache.
	public static func mayWriteCache(event: String, headBranch: String, defaultBranch: String) -> Bool {
		!headBranch.isEmpty && headBranch == defaultBranch && event != "pull_request" && event != "pull_request_target"
	}

	/// What this bay offers, one label per capsule kind, no size (every capsule is the same):
	/// `cryo` (any capsule), `cryo-<image tag>` (e.g. `cryo-xcode-27.2`) and `cryo-macos-<major>`.
	/// The guest runs the host's macOS (latest macOS only, host and guest on the same release).
	public static func defaultLabels(bay: any BayClient, macOSMajor: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) -> [String] {
		var l = ["cryo"]
		if let image = try? bay.status().bay.image, !image.isEmpty {
			l.append(image.hasPrefix("cryo-") ? image : "cryo-" + image)
		}
		#if os(macOS)
			l.append("cryo-macos-\(macOSMajor)")
		#endif
		return l
	}

	public static func shortHost(_ full: String) -> String {
		let first = full.split(separator: ".").first.map(String.init) ?? full
		let s = String(first.lowercased().map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" })
		return s.isEmpty ? "mac" : s
	}
}

public final class CIPoller: @unchecked Sendable {
	public let config: CIConfig
	private let api: GitHubAPI
	private let bay: any BayClient
	private let launcher: any CapsuleRunnerLauncher
	private let store: CIStateStore?
	private let clock: any CIClock
	private let host: String
	private let log: @Sendable (String) -> Void
	/// Reads the stored token again (after `cryo ci github login` rotated it); nil: no store.
	private let reloadToken: (@Sendable () -> String?)?

	private let m = Monitor()
	// Guarded by `m`.
	private var handled: Set<Int> = []
	private var inFlight = 0
	private var state = CIState()
	private var stopped = false
	/// Runs with nothing left to take, by `repo#run id`.
	private var settled: [String: (updatedAt: String, at: Double)] = [:]
	/// No GitHub calls before this time (unix seconds): a rate limit said to wait.
	private var pausedUntil: Double = 0
	/// When the "token rejected" line was last logged; nil while GitHub accepts the token.
	private var rejectedLoggedAt: Double?
	/// Jobs waiting for a free slot, logged once when they start waiting; `waitingNow` is this
	/// tick's set, so a job that waits again later is logged again.
	private var waiting: Set<Int> = []
	private var waitingNow: Set<Int> = []
	/// Runner start failures per job.
	private var attempts: [Int: Int] = [:]

	public init(
		config: CIConfig, api: GitHubAPI, bay: any BayClient, launcher: any CapsuleRunnerLauncher,
		store: CIStateStore?, clock: any CIClock = SystemCIClock(), hostName: String,
		reloadToken: (@Sendable () -> String?)? = nil, log: @escaping @Sendable (String) -> Void
	) {
		self.config = config
		self.api = api
		self.bay = bay
		self.launcher = launcher
		self.store = store
		self.clock = clock
		self.host = CIRules.shortHost(hostName)
		self.reloadToken = reloadToken
		self.log = log
		// Counts and results carry over; `running` is what a previous process left (`recover()`).
		self.state = store?.load() ?? CIState()
	}

	public var snapshot: CIState { m.withLock { state } }

	/// Stops taking jobs and stops the runners that run; `run()` then waits for their capsules to
	/// be released and their runners deleted, and returns. Safe from any thread.
	public func stop() {
		let leases: [String] = m.withLock {
			stopped = true
			return state.running.compactMap(\.lease)
		}
		for l in leases { launcher.stopRunner(lease: l) }
	}

	/// Cleans up after a previous process, then polls until `stop()`, then winds down.
	public func run() {
		recover()
		while !isStopped {
			tick()
			var left = config.pollInterval
			while left > 0 && !isStopped {
				clock.sleep(seconds: min(1, left))
				left -= 1
			}
		}
		windDown()
	}

	/// Jobs the state file still lists as running belong to a process that is gone (killed, or it
	/// crashed): releases their capsules, also one granted after it stopped waiting (found by the
	/// lease name), forgets their SSH files, and deletes their runners.
	public func recover() {
		let stale = m.withLock { state.running }
		guard !stale.isEmpty else { return }
		let onBay = (try? bay.listLeases()) ?? []
		for r in stale {
			let tag = "\(r.repo) job \(r.job)"
			var leases = Set(r.lease.map { [$0] } ?? [])
			for l in onBay where l.name == "ci-\(CIRules.cacheName(r.repo))-\(r.job)" { leases.insert(l.id) }
			for l in leases.sorted() {
				do {
					try bay.release(l, saveCache: false)
				} catch CryoClientError.api(let e, _) where e.code == APIError.notFound {
				} catch {
					log("\(tag): cannot release lease \(l): \(error)")
				}
				launcher.forgetLease(l)
			}
			if let id = r.runner { deleteRunner(r.repo, id, tag) }
			log("\(tag): left running by an earlier cryo ci; cleaned up (leases: \(leases.isEmpty ? "none" : leases.sorted().joined(separator: ", ")))")
			m.withLock {
				state.results.append(
					.init(job: r.job, repo: r.repo, conclusion: "error: cryo ci stopped while it ran", cacheSaved: false, finishedAt: clock.now()))
				if state.results.count > CIState.maxResults { state.results.removeFirst(state.results.count - CIState.maxResults) }
			}
		}
		m.withLock {
			state.running = []
			persist()
		}
	}

	/// After `stop()`: keeps stopping runners (one may have started since) until every job thread
	/// has released its capsule, or `shutdownTimeout`. What is left is cleaned up by `recover()`.
	private func windDown() {
		let deadline = nowSeconds() + config.shutdownTimeout
		var stoppedLeases = Set<String>()
		while true {
			for l in m.withLock({ state.running.compactMap(\.lease) }) where !stoppedLeases.contains(l) {
				if launcher.stopRunner(lease: l) { stoppedLeases.insert(l) }
			}
			if waitForIdle(timeout: min(0.5, max(0, deadline - nowSeconds()))) { return }
			if nowSeconds() >= deadline {
				log("cryo ci: \(m.withLock { inFlight }) job(s) still winding down after \(Int(config.shutdownTimeout)) s; the next start cleans up")
				return
			}
		}
	}

	/// One poll of every repo. Starts a thread per new matching job and returns.
	public func tick() {
		if isPaused { return }
		m.withLock { waitingNow = [] }
		defer { m.withLock { waiting = waitingNow } }
		var reloaded = false
		for repo in config.repos {
			var again = true
			while again {
				again = false
				do {
					try poll(repo)
					noteAccepted()
				} catch let e as GitHubError {
					switch e {
					case .rateLimited:
						pause(for: e)
						return
					case .unauthorized:
						// Once per tick: the token may have been rotated with `cryo ci github login`.
						if !reloaded {
							reloaded = true
							if reloadedNewToken() {
								again = true
								continue
							}
						}
						noteRejected(e)
					default:
						log("\(repo): \(e)")
					}
				} catch {
					log("\(repo): \(error)")
				}
			}
		}
	}

	/// The rejected-token line, at most every 10 minutes rather than every tick.
	static let rejectedLogInterval: Double = 600

	private func reloadedNewToken() -> Bool {
		guard let t = reloadToken?(), !t.isEmpty, t != api.token else { return false }
		api.setToken(t)
		log("GitHub rejected the token; the stored token changed, using the new one")
		return true
	}

	private func noteRejected(_ e: GitHubError) {
		let now = clock.now().timeIntervalSince1970
		let due: Bool = m.withLock {
			if let last = rejectedLoggedAt, now - last < Self.rejectedLogInterval { return false }
			rejectedLoggedAt = now
			return true
		}
		if due { log("\(e) (the stored token is re-read on every tick; this repeats every \(Int(Self.rejectedLogInterval / 60)) min)") }
	}

	private func noteAccepted() {
		if m.withLock({ rejectedLoggedAt.take() }) != nil { log("GitHub accepts the token again") }
	}

	private var isPaused: Bool {
		let now = clock.now().timeIntervalSince1970
		return m.withLock { now < pausedUntil }
	}

	/// Stops calling GitHub until the time a rate limit gave (a minute when it gave none).
	private func pause(for e: GitHubError) {
		guard case .rateLimited(let resetAt, let retryAfter, _) = e else { return }
		let now = clock.now().timeIntervalSince1970
		let until = min(max(retryAfter.map { now + $0 } ?? resetAt ?? now + 60, now + 1), now + 3600)
		m.withLock { pausedUntil = until }
		log("\(e); no GitHub calls for \(Int((until - now).rounded(.up))) s")
	}

	/// Waits until no job thread is running. False on timeout.
	@discardableResult
	public func waitForIdle(timeout: Double = 30) -> Bool {
		let deadline = nowSeconds() + timeout
		m.lock()
		defer { m.unlock() }
		while inFlight > 0 {
			if !m.wait(until: deadline) { return inFlight == 0 }
		}
		return true
	}

	// MARK: polling

	private func poll(_ repo: String) throws {
		let runs = try api.queuedRuns(repo)
		let now = clock.now().timeIntervalSince1970
		let live = Set(runs.map { Self.runKey(repo, $0.id) })
		m.withLock { settled = settled.filter { !$0.key.hasPrefix(repo + "#") || live.contains($0.key) } }
		for run in runs {
			let key = Self.runKey(repo, run.id)
			let skip = m.withLock {
				settled[key].map { $0.updatedAt == run.updatedAt && now - $0.at < config.runRefetchInterval } ?? false
			}
			if skip { continue }
			let jobs = try api.jobs(repo, runID: run.id)
			for j in jobs where j.status == "queued" {
				let job = CIJob(
					repo: repo, id: j.id, runID: run.id, name: j.name, labels: j.labels, event: run.event,
					headBranch: run.headBranch.isEmpty ? j.headBranch : run.headBranch)
				consider(job)
			}
			// Settled: every job is taken by us, not ours, or past `queued` (a job waiting on
			// `needs:` or an environment is not).
			m.withLock {
				let done = jobs.allSatisfy { handled.contains($0.id) || $0.status == "in_progress" || $0.status == "completed" }
				settled[key] = done ? (run.updatedAt, now) : nil
			}
		}
	}

	private static func runKey(_ repo: String, _ run: Int) -> String { "\(repo)#\(run)" }

	private func consider(_ job: CIJob) {
		let action: String? = m.withLock {
			if stopped || handled.contains(job.id) { return nil }
			if !CIRules.matches(labels: job.labels, offered: config.offeredLabels) {
				handled.insert(job.id)
				noteSeen(job, "skipped")
				return "skipped"
			}
			if inFlight >= config.maxConcurrent {
				waitingNow.insert(job.id)
				return waiting.contains(job.id) ? nil : "full"
			}
			handled.insert(job.id)
			inFlight += 1
			noteSeen(job, "started")
			state.running.append(.init(job: job.id, repo: job.repo, lease: nil, since: clock.now()))
			persist()
			return "started"
		}
		switch action {
		case "skipped": log("\(job.repo) job \(job.id) (\(job.name)): labels \(job.labels.joined(separator: ",")) not ours, left for another runner")
		case "started":
			log("\(job.repo) job \(job.id) (\(job.name)): matched, starting")
			spawnThread { [self] in
				let retry = handle(job)
				m.withLock {
					if retry {
						handled.remove(job.id)
						settled[Self.runKey(job.repo, job.runID)] = nil
					}
					state.running.removeAll { $0.job == job.id }
					persist()
					inFlight -= 1
					m.broadcast()
				}
			}
		case "full": log("\(job.repo) job \(job.id): \(config.maxConcurrent) jobs already in flight, waiting")
		default: break
		}
	}

	// Call with `m` held.
	private func noteSeen(_ job: CIJob, _ action: String) {
		state.seenCount += 1
		state.seen.append(.init(job: job.id, repo: job.repo, name: job.name, labels: job.labels, action: action, at: clock.now()))
		if state.seen.count > CIState.maxSeen { state.seen.removeFirst(state.seen.count - CIState.maxSeen) }
	}

	// Call with `m` held.
	private func persist() {
		state.updatedAt = clock.now()
		do { try store?.save(state) } catch { log("cannot write ci state: \(error)") }
	}

	// MARK: one job

	// Call with `m` held.
	private func updateRunning(_ job: Int, _ change: (inout CIState.Running) -> Void) {
		if let i = state.running.firstIndex(where: { $0.job == job }) { change(&state.running[i]) }
		persist()
	}

	private var isStopped: Bool { m.withLock { stopped } }

	/// Returns true when the job should be tried again on the next tick.
	private func handle(_ job: CIJob) -> Bool {
		let tag = "\(job.repo) job \(job.id)"
		// The capsule first: while the bay is full or down nothing is registered on GitHub.
		let lease: Lease
		do {
			let folder = try launcher.prepareFolder(job: job)
			let timeout = config.timeoutMinutes[job.repo] ?? config.defaultTimeoutMinutes
			lease = try bay.createLease(
				LeaseRequest(
					folder: folder, cache: CIRules.cacheName(job.repo), waitS: config.leaseWaitS,
					name: "ci-\(CIRules.cacheName(job.repo))-\(job.id)", idleS: CIRules.idleSeconds(timeoutMinutes: timeout)))
		} catch {
			log("\(tag): no capsule, will retry: \(error)")
			return true
		}
		m.withLock { updateRunning(job.id) { $0.lease = lease.id } }
		if isStopped {
			_ = release(lease.id, save: false, tag)
			return false
		}
		// A new name per attempt: a runner an earlier attempt could not delete never clashes.
		let name = "cryo-\(host)-\(job.id)-\(String(UInt32.random(in: 0...0xffff_ffff), radix: 16))"
		let jit: JITConfig
		do {
			jit = try api.generateJITConfig(job.repo, name: name, labels: job.labels)
		} catch {
			log("\(tag): cannot get a runner config, will retry: \(error)")
			_ = release(lease.id, save: false, tag)
			return true
		}
		m.withLock { updateRunning(job.id) { $0.runner = jit.runnerID } }
		log("\(tag): lease \(lease.id), runner \(name) starting")
		let keepAlive = Repeating(interval: config.renewInterval) { [bay, log] in
			do { _ = try bay.renew(lease.id) } catch { log("\(tag): renew of \(lease.id) failed: \(error)") }
		}
		let watch = JobWatch()
		let watcher = Repeating(interval: config.watchInterval) { [self] in
			self.watch(job, runner: name, id: jit.runnerID, lease: lease.id, watch)
		}
		var conclusion: String
		do {
			conclusion = "exit \(try launcher.runRunner(lease: lease, jitConfig: jit.encoded))"
		} catch {
			conclusion = "error: \(error)"
		}
		keepAlive.stop()
		watcher.stop()

		var retry = false
		var ranJob = false
		if let why = watch.reason {
			conclusion = "stopped: \(why)"
		} else if isStopped {
			conclusion = "stopped: cryo ci is shutting down"
		} else if stillQueued(job) {
			// The runner never took the job: ssh or the lease files failed, the runner could not
			// start, or (a JIT runner takes any job with its labels) it ran another one of ours.
			let n: Int = m.withLock {
				attempts[job.id, default: 0] += 1
				return attempts[job.id] ?? 0
			}
			retry = n < config.maxRunnerAttempts
			conclusion +=
				retry
				? "; the job is still queued, will retry (\(n) of \(config.maxRunnerAttempts) attempts)"
				: "; the job is still queued, giving up after \(n) attempts"
		} else {
			ranJob = true
		}
		if !retry { m.withLock { attempts[job.id] = nil } }
		// A runner that ran its job to the end deregisters itself; one stopped, killed or never used
		// stays registered.
		if !ranJob || conclusion.hasPrefix("error") { deleteRunner(job.repo, jit.runnerID, tag) }
		// The trust rule: a failure to learn the default branch means no cache write. A capsule whose
		// runner never ran the job, or was stopped, has nothing worth saving.
		var save = false
		if ranJob, let def = try? api.defaultBranch(job.repo) {
			save = CIRules.mayWriteCache(event: job.event, headBranch: job.headBranch, defaultBranch: def)
		}
		if let failure = release(lease.id, save: save, tag) {
			conclusion += " (release failed: \(failure))"
			save = false
		}
		m.withLock {
			state.results.append(.init(job: job.id, repo: job.repo, conclusion: conclusion, cacheSaved: save, finishedAt: clock.now()))
			if state.results.count > CIState.maxResults { state.results.removeFirst(state.results.count - CIState.maxResults) }
		}
		log("\(tag): \(conclusion), cache \(save ? "saved" : "not saved")")
		return retry
	}

	/// The release error, or nil.
	private func release(_ lease: String, save: Bool, _ tag: String) -> String? {
		do {
			try bay.release(lease, saveCache: save)
			return nil
		} catch {
			log("\(tag): cannot release lease \(lease): \(error)")
			return "\(error)"
		}
	}

	private func deleteRunner(_ repo: String, _ id: Int, _ tag: String) {
		do {
			try api.deleteRunner(repo, id: id)
		} catch let e as GitHubError {
			if case .notFound = e { return }  // gone already
			log("\(tag): cannot delete runner \(id): \(e)")
		} catch {
			log("\(tag): cannot delete runner \(id): \(error)")
		}
	}

	/// True when GitHub still has the job queued with no runner on it. Unknown counts as no.
	private func stillQueued(_ job: CIJob) -> Bool {
		guard let j = try? api.job(job.repo, id: job.id) else { return false }
		return j.status == "queued" && j.runnerName.isEmpty
	}

	/// One look at a running job (every `watchInterval`): stops its runner when the job no longer
	/// needs it, so a capsule is not held until the idle bound (timeout-minutes + 10 min).
	private func watch(_ job: CIJob, runner name: String, id runnerID: Int, lease: String, _ w: JobWatch) {
		if isPaused || isStopped || w.reason != nil { return }
		let j: WorkflowJob
		do {
			j = try api.job(job.repo, id: job.id)
		} catch let e as GitHubError {
			if case .rateLimited = e { pause(for: e) }
			return
		} catch { return }
		var why: String?
		if !j.runnerName.isEmpty && j.runnerName != name {
			why = "the job went to runner \(j.runnerName)"
		} else if j.status == "completed" {
			// Only on the second look: our own runner exits by itself right after its job.
			if w.sawCompleted { why = "the job is \(j.conclusion == "cancelled" ? "cancelled" : "over (\(j.conclusion))")" }
			w.sawCompleted = true
		}
		guard let why else { return }
		// A JIT runner takes any queued job with its labels: leave it alone while it runs one.
		do {
			if try api.runnerBusy(job.repo, id: runnerID) { return }
		} catch let e as GitHubError {
			guard case .notFound = e else { return }
		} catch { return }
		w.reason = why  // before the stop: the job's thread reads it once the runner returns
		guard launcher.stopRunner(lease: lease) else {
			w.reason = nil  // not started yet; the next look tries again
			return
		}
		log("\(job.repo) job \(job.id): \(why); stopped its runner")
	}
}

/// What the watch of one running job found; read by the job's thread once the runner returns.
final class JobWatch: @unchecked Sendable {
	private let m = Monitor()
	private var _reason: String?
	private var _sawCompleted = false
	/// Why the runner was stopped; nil while it was not.
	var reason: String? {
		get { m.withLock { _reason } }
		set { m.withLock { _reason = newValue } }
	}
	var sawCompleted: Bool {
		get { m.withLock { _sawCompleted } }
		set { m.withLock { _sawCompleted = newValue } }
	}
}

/// Runs `body` on its own thread every `interval` seconds until `stop()` (lease renews, job watch).
final class Repeating: @unchecked Sendable {
	private let m = Monitor()
	private var stopped = false  // guarded by `m`

	init(interval: Double, _ body: @escaping @Sendable () -> Void) {
		spawnThread { [self] in
			m.lock()
			defer { m.unlock() }
			while !stopped {
				if m.wait(until: nowSeconds() + interval) || stopped { continue }
				m.unlock()
				body()
				m.lock()
			}
		}
	}

	func stop() {
		m.withLock {
			stopped = true
			m.broadcast()
		}
	}
}
