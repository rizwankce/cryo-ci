import CryoAPI

/// What `cryo ci` needs to know about a job.
public struct CIJob: Sendable, Equatable {
	public var repo: String
	public var id: Int
	public var runID: Int
	public var name: String
	public var labels: [String]
	public var event: String
	public var headBranch: String

	public init(repo: String, id: Int, runID: Int, name: String, labels: [String], event: String, headBranch: String) {
		self.repo = repo
		self.id = id
		self.runID = runID
		self.name = name
		self.labels = labels
		self.event = event
		self.headBranch = headBranch
	}
}

public protocol CapsuleRunnerLauncher: Sendable {
	/// Stages the runner copy in a folder on this Mac; the path is passed as the lease `folder`.
	/// nil means no folder.
	func prepareFolder(job: CIJob) throws -> String?
	/// Starts the one-job runner inside the capsule and blocks until it exits; returns its exit code.
	func runRunner(lease: Lease, jitConfig: String) throws -> Int32
	/// Stops the runner `runRunner` runs for this lease, so that call returns soon. False when no
	/// runner is running for it (yet).
	@discardableResult
	func stopRunner(lease: String) -> Bool
	/// Removes what this Mac keeps for a lease (its SSH key and ssh_config block), for a lease a
	/// previous process left behind.
	func forgetLease(_ id: String)
}

public struct CILauncherError: Error, CustomStringConvertible, Sendable {
	public let description: String
	public init(_ description: String) { self.description = description }
}
