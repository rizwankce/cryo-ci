import CryoHTTP

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

/// What GitHub answered. Header names are lowercased.
public struct GitHubResponse: Sendable {
	public var status: Int
	public var body: Data
	public var headers: [String: String]

	public init(status: Int, body: Data, headers: [String: String] = [:]) {
		self.status = status
		self.body = body
		self.headers = headers
	}
}

/// One HTTPS call to the GitHub REST API. The real one (URLSession, macOS only) is
/// `URLSessionGitHubTransport`; tests use a mock. Our own HTTP client has no TLS.
public protocol GitHubTransport: Sendable {
	func send(method: String, path: String, query: [String: String], body: Data?, token: String) throws -> GitHubResponse
}

public enum GitHubError: Error, CustomStringConvertible, Sendable, Equatable {
	case unauthorized(String)
	case forbidden(String)
	case notFound(String)
	case invalid(String)
	/// 403 or 429 for a rate limit. `resetAt` (unix time, `x-ratelimit-reset`) when the hourly budget
	/// is spent; `retryAfter` (seconds, `retry-after`) for a secondary limit. Neither: wait a minute.
	case rateLimited(resetAt: Double?, retryAfter: Double?, message: String)
	case http(status: Int, message: String)
	case transport(String)
	case badResponse(String)

	public var description: String {
		switch self {
		case .unauthorized(let m): return "GitHub rejected the token (401): \(m). Run `cryo ci github login` with a new token."
		case .forbidden(let m):
			return
				"GitHub refused (403): \(m). The token needs admin rights on the repo (and the `repo` scope, or Administration: read/write for a fine-grained token)."
		case .notFound(let m): return "GitHub says not found (404): \(m). Check the repo name, and that the token can see the repo."
		case .invalid(let m): return "GitHub rejected the request (422): \(m)"
		case .rateLimited(_, _, let m): return "GitHub rate limit hit: \(m)"
		case .http(let s, let m): return "GitHub answered HTTP \(s): \(m)"
		case .transport(let m): return "cannot reach GitHub: \(m)"
		case .badResponse(let m): return "unexpected answer from GitHub: \(m)"
		}
	}
}

public struct WorkflowRun: Decodable, Sendable, Equatable {
	public var id: Int
	public var event: String
	public var headBranch: String
	/// Changes whenever the run does (a job queued, started or finished): the poller re-reads the
	/// jobs of a run it has settled only when this moves.
	public var updatedAt: String
	enum CodingKeys: String, CodingKey {
		case id, event
		case headBranch = "head_branch"
		case updatedAt = "updated_at"
	}
	public init(from d: Decoder) throws {
		let c = try d.container(keyedBy: CodingKeys.self)
		id = try c.decode(Int.self, forKey: .id)
		event = try c.decodeIfPresent(String.self, forKey: .event) ?? ""
		headBranch = try c.decodeIfPresent(String.self, forKey: .headBranch) ?? ""
		updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
	}
}

public struct WorkflowJob: Decodable, Sendable, Equatable {
	public var id: Int
	public var status: String
	/// "success", "failure", "cancelled", … once `status` is "completed".
	public var conclusion: String
	public var labels: [String]
	public var headBranch: String
	public var name: String
	/// The runner that took the job; empty while it is queued.
	public var runnerName: String
	enum CodingKeys: String, CodingKey {
		case id, status, conclusion, labels, name
		case headBranch = "head_branch"
		case runnerName = "runner_name"
	}
	public init(from d: Decoder) throws {
		let c = try d.container(keyedBy: CodingKeys.self)
		id = try c.decode(Int.self, forKey: .id)
		status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
		conclusion = try c.decodeIfPresent(String.self, forKey: .conclusion) ?? ""
		labels = try c.decodeIfPresent([String].self, forKey: .labels) ?? []
		headBranch = try c.decodeIfPresent(String.self, forKey: .headBranch) ?? ""
		name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
		runnerName = try c.decodeIfPresent(String.self, forKey: .runnerName) ?? ""
	}
}

public struct JITConfig: Sendable, Equatable {
	public var runnerID: Int
	public var encoded: String
}

/// The GitHub calls `cryo ci` needs (docs/ci.md), over a `GitHubTransport`.
public struct GitHubAPI: Sendable {
	/// Lists are read 100 at a time, at most this many pages (1000 runs or jobs).
	static let perPage = 100
	static let maxPages = 10

	public let transport: any GitHubTransport
	private let box: TokenBox

	public init(transport: any GitHubTransport, token: String) {
		self.transport = transport
		self.box = TokenBox(token)
	}

	/// The token every call sends; `setToken` swaps it for all copies of this value (the poller's
	/// job threads share it).
	public var token: String { box.value }
	public func setToken(_ token: String) { box.value = token }

	private final class TokenBox: @unchecked Sendable {
		private let m = Monitor()
		private var _value: String
		init(_ value: String) { _value = value }
		var value: String {
			get { m.withLock { _value } }
			set { m.withLock { _value = newValue } }
		}
	}

	/// The login of the token's owner (validates a token).
	public func user() throws -> String {
		struct U: Decodable { var login: String }
		return try call("GET", "/user", context: "token check", as: U.self).login
	}

	public func defaultBranch(_ repo: String) throws -> String {
		// swift-format-ignore: AlwaysUseLowerCamelCase
		struct R: Decodable { var default_branch: String }
		return try call("GET", "/repos/\(repo)", context: repo, as: R.self).default_branch
	}

	/// Runs that may hold queued jobs: queued runs, plus in-progress ones, because a job waiting on
	/// `needs:` is queued inside a run that is already in progress.
	public func queuedRuns(_ repo: String) throws -> [WorkflowRun] {
		// swift-format-ignore: AlwaysUseLowerCamelCase
		struct R: Decodable {
			var total_count: Int?
			var workflow_runs: [WorkflowRun]
		}
		var seen = Set<Int>()
		var runs: [WorkflowRun] = []
		for status in ["queued", "in_progress"] {
			let all = try pages("/repos/\(repo)/actions/runs", query: ["status": status], context: repo, as: R.self) { ($0.workflow_runs, $0.total_count) }
			for run in all where seen.insert(run.id).inserted { runs.append(run) }
		}
		return runs
	}

	public func jobs(_ repo: String, runID: Int) throws -> [WorkflowJob] {
		// swift-format-ignore: AlwaysUseLowerCamelCase
		struct R: Decodable {
			var total_count: Int?
			var jobs: [WorkflowJob]
		}
		return try pages("/repos/\(repo)/actions/runs/\(runID)/jobs", query: ["filter": "latest"], context: repo, as: R.self) { ($0.jobs, $0.total_count) }
	}

	/// One job, to watch it while its runner runs.
	public func job(_ repo: String, id: Int) throws -> WorkflowJob {
		try call("GET", "/repos/\(repo)/actions/jobs/\(id)", context: repo, as: WorkflowJob.self)
	}

	/// Whether a runner is running a job right now.
	public func runnerBusy(_ repo: String, id: Int) throws -> Bool {
		struct R: Decodable { var busy: Bool }
		return try call("GET", "/repos/\(repo)/actions/runners/\(id)", context: repo, as: R.self).busy
	}

	public func generateJITConfig(_ repo: String, name: String, labels: [String]) throws -> JITConfig {
		// swift-format-ignore: AlwaysUseLowerCamelCase
		struct Body: Encodable {
			var name: String
			var runner_group_id = 1
			var labels: [String]
			var work_folder = "_work"
		}
		struct Runner: Decodable { var id: Int }
		// swift-format-ignore: AlwaysUseLowerCamelCase
		struct R: Decodable {
			var runner: Runner
			var encoded_jit_config: String
		}
		let body = try JSONEncoder().encode(Body(name: name, labels: labels))
		let r = try call("POST", "/repos/\(repo)/actions/runners/generate-jitconfig", body: body, context: repo, as: R.self)
		return JITConfig(runnerID: r.runner.id, encoded: r.encoded_jit_config)
	}

	public func deleteRunner(_ repo: String, id: Int) throws {
		_ = try send("DELETE", "/repos/\(repo)/actions/runners/\(id)", query: [:], body: nil, context: repo)
	}

	/// Every page of a list, `perPage` at a time, until a short page or `total_count` items.
	private func pages<Page: Decodable, Item>(
		_ path: String, query: [String: String], context: String, as: Page.Type, _ items: (Page) -> ([Item], Int?)
	) throws -> [Item] {
		var all: [Item] = []
		for page in 1...Self.maxPages {
			var q = query
			q["per_page"] = String(Self.perPage)
			q["page"] = String(page)
			let (got, total) = items(try call("GET", path, query: q, context: context, as: Page.self))
			all += got
			if got.count < Self.perPage || all.count >= (total ?? Int.max) { break }
		}
		return all
	}

	private func call<T: Decodable>(_ method: String, _ path: String, query: [String: String] = [:], body: Data? = nil, context: String, as: T.Type) throws -> T
	{
		let data = try send(method, path, query: query, body: body, context: context)
		do {
			return try JSONDecoder().decode(T.self, from: data)
		} catch {
			throw GitHubError.badResponse("cannot decode \(method) \(path): \(error)")
		}
	}

	private func send(_ method: String, _ path: String, query: [String: String], body: Data?, context: String) throws -> Data {
		let r: GitHubResponse
		do {
			r = try transport.send(method: method, path: path, query: query, body: body, token: token)
		} catch let e as GitHubError {
			throw e
		} catch {
			throw GitHubError.transport("\(error)")
		}
		if (200..<300).contains(r.status) { return r.body }
		struct M: Decodable { var message: String? }
		let detail = (try? JSONDecoder().decode(M.self, from: r.body))?.message ?? ""
		let text = detail.isEmpty ? context : "\(context): \(detail)"
		if r.status == 403 || r.status == 429 {
			// docs.github.com "Rate limits for the REST API": a spent hourly budget has
			// x-ratelimit-remaining 0 and the reset time; a secondary limit sends retry-after or
			// only says so in the message.
			let retryAfter = r.headers["retry-after"].flatMap { Double($0) }
			let spent = r.headers["x-ratelimit-remaining"] == "0"
			let resetAt = spent ? r.headers["x-ratelimit-reset"].flatMap { Double($0) } : nil
			if r.status == 429 || retryAfter != nil || spent || detail.lowercased().contains("rate limit") {
				throw GitHubError.rateLimited(resetAt: resetAt, retryAfter: retryAfter, message: text)
			}
		}
		switch r.status {
		case 401: throw GitHubError.unauthorized(detail.isEmpty ? "bad credentials" : detail)
		case 403: throw GitHubError.forbidden(text)
		case 404: throw GitHubError.notFound(text)
		case 422: throw GitHubError.invalid(text)
		default: throw GitHubError.http(status: r.status, message: text)
		}
	}
}

#if os(macOS)
	import Foundation

	/// The real transport: HTTPS to api.github.com through URLSession.
	public struct URLSessionGitHubTransport: GitHubTransport {
		public var baseURL = "https://api.github.com"
		public init() {}

		private final class Box: @unchecked Sendable {
			var data: Data?
			var response: URLResponse?
			var error: Error?
		}

		func request(method: String, path: String, query: [String: String], body: Data?, token: String) throws -> URLRequest {
			guard var comps = URLComponents(string: baseURL + path) else { throw GitHubError.transport("bad URL \(path)") }
			if !query.isEmpty {
				comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
			}
			guard let url = comps.url else { throw GitHubError.transport("bad URL \(path)") }
			var req = URLRequest(url: url)
			req.httpMethod = method
			req.timeoutInterval = 30
			// GitHub sends `max-age=60`: the default policy would answer a poll from the cache for a minute.
			req.cachePolicy = .reloadIgnoringLocalCacheData
			req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
			req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
			req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
			req.setValue("cryo-ci", forHTTPHeaderField: "User-Agent")
			if let body {
				req.httpBody = body
				req.setValue("application/json", forHTTPHeaderField: "Content-Type")
			}
			return req
		}

		public func send(method: String, path: String, query: [String: String], body: Data?, token: String) throws -> GitHubResponse {
			let req = try request(method: method, path: path, query: query, body: body, token: token)
			let box = Box()
			let done = DispatchSemaphore(value: 0)
			URLSession.shared.dataTask(with: req) { data, response, error in
				box.data = data
				box.response = response
				box.error = error
				done.signal()
			}.resume()
			done.wait()
			if let e = box.error { throw GitHubError.transport(e.localizedDescription) }
			guard let http = box.response as? HTTPURLResponse else { throw GitHubError.badResponse("no HTTP response") }
			var headers: [String: String] = [:]
			for (k, v) in http.allHeaderFields {
				if let k = k as? String, let v = v as? String { headers[k.lowercased()] = v }
			}
			return GitHubResponse(status: http.statusCode, body: box.data ?? Data(), headers: headers)
		}
	}
#endif
