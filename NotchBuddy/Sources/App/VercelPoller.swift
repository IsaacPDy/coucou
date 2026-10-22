import Foundation

// MARK: - VercelPoller
// Polls Vercel API for latest deployments every 30s.
// On new terminal deployment: updates integration_vercel task state + AppState.vercelDeployments.
// Also lists the projects (every 5 min, or when the card opens) and fetches one
// project's deployments when the user opens it in the notch.

final class VercelPoller: @unchecked Sendable {
    static let shared = VercelPoller()
    private var timer: DispatchSourceTimer?
    private var lastDeploymentId: String = ""
    // Main thread only.
    private var projectsFetchedAt: Date?
    private var projectsInFlight = false

    private init() {}

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .background))
        t.schedule(deadline: .now() + 5, repeating: 30, leeway: .seconds(5))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    // MARK: - Poll

    private func poll() {
        guard !DemoEngine.isPollerPaused else { return }
        guard let token = KeychainStore.shared.get("vercel-token") else { return }
        refreshProjectsIfStale(maxAge: 300)

        // Fetch last 5 terminal deployments
        guard let url = URL(string: "https://api.vercel.com/v6/deployments?limit=5") else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data, code == 200 else { return }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rawList = json["deployments"] as? [[String: Any]] else { return }

            // Only terminal deployments (READY, ERROR, CANCELED)
            let terminal = ["READY", "ERROR", "CANCELED"]
            let parsed = rawList
                .compactMap { self.parseDeployment($0) }
                .filter { terminal.contains($0.state) }
            guard !parsed.isEmpty else { return }

            DispatchQueue.main.async { self.handleDeployments(parsed) }
        }.resume()
    }

    // MARK: - Projects

    /// Fetches the project list if the last fetch is older than maxAge seconds. Safe to call from any thread.
    func refreshProjectsIfStale(maxAge: TimeInterval = 60) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.projectsInFlight else { return }
            if let at = self.projectsFetchedAt, Date().timeIntervalSince(at) < maxAge { return }
            guard !DemoEngine.isPollerPaused,
                  let token = KeychainStore.shared.get("vercel-token") else { return }
            self.projectsInFlight = true
            self.fetchProjects(token: token)
        }
    }

    private func fetchProjects(token: String) {
        guard let url = URL(string: "https://api.vercel.com/v9/projects?limit=50") else { return }
        URLSession.shared.dataTask(with: request(url, token: token)) { [weak self] data, response, _ in
            guard let self else { return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            var projects: [VercelProject]?
            if let data, code == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let raw = json["projects"] as? [[String: Any]] {
                projects = raw.compactMap { self.parseProject($0) }
                    .sorted { $0.updatedAt > $1.updatedAt }
            }
            DispatchQueue.main.async {
                self.projectsInFlight = false
                guard let projects else { return }
                self.projectsFetchedAt = Date()
                AppState.shared.setIfChanged(\.vercelProjects, projects)
            }
        }.resume()
    }

    private func parseProject(_ p: [String: Any]) -> VercelProject? {
        guard let id = p["id"] as? String, let name = p["name"] as? String else { return nil }
        let latest = (p["latestDeployments"] as? [[String: Any]])?.first
        let production = (p["targets"] as? [String: Any])?["production"] as? [String: Any]
        let latestState = latest?["readyState"] as? String ?? production?["readyState"] as? String
        let alias = (production?["alias"] as? [String])?.first
        let updatedMs = (p["updatedAt"] as? Double)
            ?? (latest?["createdAt"] as? Double)
            ?? 0
        return VercelProject(id: id, name: name,
                             updatedAt: Date(timeIntervalSince1970: updatedMs / 1000),
                             latestState: latestState, productionURL: alias)
    }

    /// Fetches the latest deployments of one project, every state included (building, queued…).
    func fetchDeployments(projectId: String) {
        guard !DemoEngine.isPollerPaused,
              let token = KeychainStore.shared.get("vercel-token"),
              let encoded = projectId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.vercel.com/v6/deployments?projectId=\(encoded)&limit=20") else { return }
        URLSession.shared.dataTask(with: request(url, token: token)) { [weak self] data, response, _ in
            guard let self else { return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data, code == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rawList = json["deployments"] as? [[String: Any]] else { return }
            let parsed = rawList.compactMap { self.parseDeployment($0) }
            DispatchQueue.main.async {
                AppState.shared.vercelProjectDeployments[projectId] = parsed
            }
        }.resume()
    }

    private func request(_ url: URL, token: String) -> URLRequest {
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    private func parseDeployment(_ d: [String: Any]) -> VercelDeployment? {
        guard let uid   = d["uid"]   as? String,
              let name  = d["name"]  as? String,
              let state = d["state"] as? String ?? d["readyState"] as? String else { return nil }

        let url = (d["url"] as? String) ?? ""
        let createdAtMs = (d["createdAt"] as? Double) ?? 0
        let createdAt = Date(timeIntervalSince1970: createdAtMs / 1000)

        let meta = d["meta"] as? [String: Any]
        let commitMessage = meta?["githubCommitMessage"] as? String
                         ?? meta?["gitlabCommitMessage"] as? String
                         ?? meta?["bitbucketCommitMessage"] as? String
        let branch = meta?["githubCommitRef"] as? String
                  ?? meta?["gitlabCommitRef"] as? String
                  ?? meta?["bitbucketBranch"] as? String

        return VercelDeployment(id: uid, projectName: name, url: url, state: state,
                                 createdAt: createdAt, commitMessage: commitMessage, branch: branch)
    }

    @MainActor
    private func handleDeployments(_ deployments: [VercelDeployment]) {
        let appState = AppState.shared
        appState.vercelDeployments = deployments

        // Apply project filter (empty = all projects)
        let filter = appState.vercelProjectFilter
        let filtered = filter.isEmpty ? deployments : deployments.filter { filter.contains($0.projectName) }
        guard let latest = filtered.first else { return }
        guard latest.id != lastDeploymentId else { return }
        lastDeploymentId = latest.id

        guard let idx = appState.tasks.firstIndex(where: { $0.id == "integration_vercel" }) else { return }
        let focused = appState.focusId == "integration_vercel"

        appState.tasks[idx].state = latest.isSuccess ? .finished : .error
        appState.tasks[idx].steps = [latest.projectName]

        if !focused {
            appState.tasks[idx].pillBadge = latest.isSuccess ? .finished : .error
        }
        SoundEngine.shared.play(latest.isSuccess ? "finish" : "error")

        // Reveal compact island so user sees the badge
        NotificationCenter.default.post(name: .hookReveal, object: nil)

        // Auto-clear task state after 60s (deployments list stays)
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            guard let i = appState.tasks.firstIndex(where: { $0.id == "integration_vercel" }) else { return }
            guard appState.tasks[i].state == .finished || appState.tasks[i].state == .error else { return }
            appState.tasks[i].state = .idle
            appState.tasks[i].steps = []
            appState.tasks[i].pillBadge = nil
        }
    }
}
