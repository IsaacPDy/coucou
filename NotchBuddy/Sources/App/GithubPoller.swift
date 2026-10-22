import Foundation

final class GithubPoller: @unchecked Sendable {
    static let shared = GithubPoller()
    private var timer: DispatchSourceTimer?
    // All properties below are accessed only on the main thread.
    private var pulseInFlight = false
    private var nextPulse: DispatchWorkItem?
    private var tokenGeneration = 0
    private var activityInFlight = false
    private var nextActivity: DispatchWorkItem?
    private init() {}

    func start() {
        guard timer == nil else { return }
        // Stats poll: every 5 minutes, starting 7 s after launch
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .background))
        t.schedule(deadline: .now() + 7, repeating: 300, leeway: .seconds(30))
        t.setEventHandler { [weak self] in self?.pollStats() }
        t.resume()
        timer = t
        // First pulse: 10 s after launch
        DispatchQueue.main.async { [weak self] in
            self?.scheduleNextPulse(hasPending: false, delay: 10)
        }
        // First activity: 15 s after launch, then every 30 min
        DispatchQueue.main.async { [weak self] in
            self?.scheduleNextActivity(delay: 15)
        }
    }

    /// Pull requests, CI and activity are fetched when the GitHub pill is in
    /// the notch, or when the iPhone sync is on (the iPhone shows GitHub even
    /// when its pill isn't in the notch).
    @MainActor private static var isWanted: Bool {
        if AppState.shared.activeIntegrations.contains("integration_github") { return true }
        #if PHONE_LINK
        return UserDefaults.standard.bool(forKey: "iPhoneSyncEnabled")
        #else
        return false
        #endif
    }

    // MARK: - Stats (unchanged logic)

    private func pollStats() {
        guard !DemoEngine.isPollerPaused else { return }
        guard let token = KeychainStore.shared.get("github-token") else { return }
        fetchUser(token: token)
    }

    private func fetchUser(token: String) {
        guard let url = URL(string: "https://api.github.com/user") else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
            guard let self else { return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data, code == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

            let publicRepos  = (json["public_repos"]        as? Int) ?? 0
            let privateOwned = (json["owned_private_repos"] as? Int)
                            ?? (json["total_private_repos"] as? Int)
                            ?? 0
            let login = (json["login"] as? String) ?? ""
            self.fetchStars(token: token, login: login, totalRepos: publicRepos + privateOwned)
        }.resume()
    }

    /// Lists the repos the user owns or reaches through an organization (most recently
    /// pushed first): they feed the notch repo list, and the owned ones the star count.
    private func fetchStars(token: String, login: String, totalRepos: Int) {
        guard let url = URL(string: "https://api.github.com/user/repos?per_page=100&affiliation=owner,organization_member&sort=pushed") else { return }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: req) { data, response, _ in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data, code == 200,
                  let repos = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }

            let owned = repos.filter {
                (($0["owner"] as? [String: Any])?["login"] as? String)?.caseInsensitiveCompare(login) == .orderedSame
            }
            let totalStars = owned.reduce(0) { $0 + (($1["stargazers_count"] as? Int) ?? 0) }
            let list = repos.compactMap(Self.parseRepo)
            DispatchQueue.main.async {
                AppState.shared.githubStats = GitHubStats(totalRepos: totalRepos, totalStars: totalStars)
                AppState.shared.setIfChanged(\.githubRepos, list)
            }
        }.resume()
    }

    private static func parseRepo(_ r: [String: Any]) -> GitHubRepo? {
        guard (r["archived"] as? Bool) != true,
              let fullName = r["full_name"] as? String,
              let name = r["name"] as? String,
              let url = r["html_url"] as? String else { return nil }
        let pushedAt = (r["pushed_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? .distantPast
        return GitHubRepo(fullName: fullName, name: name, url: url,
                          isPrivate: (r["private"] as? Bool) ?? false, pushedAt: pushedAt)
    }

    /// Loads the repo list right away when the card opens before the first stats poll.
    func refreshReposIfEmpty() {
        DispatchQueue.main.async {
            guard AppState.shared.githubRepos.isEmpty else { return }
            DispatchQueue.global(qos: .userInitiated).async { GithubPoller.shared.pollStats() }
        }
    }

    // MARK: - Repo runs (on demand)

    /// Fetches the latest GitHub Actions runs of one repo ("owner/name").
    func fetchRuns(repo: String) {
        guard !DemoEngine.isPollerPaused,
              let token = KeychainStore.shared.get("github-token"),
              let url = URL(string: "https://api.github.com/repos/\(repo)/actions/runs?per_page=20") else { return }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            // 403/404: the token can't read Actions on this repo — show it as having no runs.
            var runs: [GitHubWorkflowRun] = []
            if let data, code == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let raw = json["workflow_runs"] as? [[String: Any]] {
                let iso = ISO8601DateFormatter()
                runs = raw.compactMap { r in
                    guard let id = r["id"] as? Int,
                          let url = r["html_url"] as? String else { return nil }
                    let workflow = (r["name"] as? String) ?? ""
                    return GitHubWorkflowRun(
                        id: id,
                        title: (r["display_title"] as? String) ?? workflow,
                        workflow: workflow,
                        branch: (r["head_branch"] as? String) ?? "",
                        status: (r["status"] as? String) ?? "",
                        conclusion: r["conclusion"] as? String,
                        url: url,
                        createdAt: (r["created_at"] as? String).flatMap { iso.date(from: $0) } ?? .distantPast)
                }
            } else {
                self?.nbLog("runs \(repo) HTTP \(code)")
            }
            DispatchQueue.main.async { AppState.shared.githubRepoRuns[repo] = runs }
        }.resume()
    }

    // MARK: - Pulse (GraphQL, single chain)

    /// Dispatches guards + state reads to main, then fires network on background.
    private func pollPulse() {
        guard !DemoEngine.isPollerPaused else { scheduleNextPulse(hasPending: false); return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.pulseInFlight else { return }
            guard let token = KeychainStore.shared.get("github-token"),
                  Self.isWanted else {
                self.scheduleNextPulse(hasPending: false)
                return
            }
            self.pulseInFlight = true
            let gen = self.tokenGeneration
            DispatchQueue.global(qos: .background).async { self.fetchPulse(token: token, generation: gen) }
        }
    }

    private func fetchPulse(token: String, generation: Int) {
        guard let url = URL(string: "https://api.github.com/graphql") else {
            finishPulse(hasPending: false); return
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let body = try? JSONSerialization.data(withJSONObject: ["query": Self.graphQLQuery]) else {
            finishPulse(hasPending: false); return
        }
        req.httpBody = body

        URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
            guard let self else { return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data, code == 200 else {
                self.nbLog("pulse HTTP \(code)")
                self.finishPulse(hasPending: false)
                return
            }
            // Partial GraphQL errors: if "data" is present, parse anyway and log error count.
            // Only discard if "data" is absent or null.
            if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let errors = root["errors"] as? [[String: Any]], !errors.isEmpty {
                    self.nbLog("pulse GraphQL errors: \(errors.count)")
                }
                guard root["data"] is [String: Any] else {
                    self.finishPulse(hasPending: false); return
                }
            }
            guard let pulse = GitHubPulse.parse(data) else {
                self.finishPulse(hasPending: false); return
            }
            DispatchQueue.main.async {
                // Discard stale response if token changed while request was in flight
                guard self.tokenGeneration == generation else { return }
                let old = AppState.shared.githubPulse
                let events = GitHubPulse.events(old: old, new: pulse)
                AppState.shared.githubPulse = pulse
                // Badge and sound only for the pill in the notch, not when the
                // fetch only feeds the iPhone.
                if AppState.shared.activeIntegrations.contains("integration_github") {
                    AppState.shared.handleGitHubEvents(events)
                }
            }
            self.finishPulse(hasPending: pulse.hasPending)
        }.resume()
    }

    /// Refreshes pulse data immediately if the last fetch is older than maxAge seconds (or absent).
    /// No-op when a request is already in flight. Safe to call from any thread.
    func refreshIfStale(maxAge: TimeInterval = 60) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.pulseInFlight else { return }
            guard GitHubPulse.isStale(fetchedAt: AppState.shared.githubPulse?.fetchedAt,
                                      maxAge: maxAge) else { return }
            self.nextPulse?.cancel()
            self.nextPulse = nil
            self.pollPulse()
        }
    }

    /// Cancels any scheduled next poll, increments tokenGeneration to invalidate in-flight
    /// responses, then fires pollPulse immediately. If a request is already in flight,
    /// does not launch another — finishPulse will reschedule.
    /// Safe to call from any thread.
    func triggerPulseNow() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.tokenGeneration += 1
            self.nextPulse?.cancel()
            self.nextPulse = nil
            guard !self.pulseInFlight else { return }
            self.pollPulse()
        }
    }

    private func nbLog(_ message: String) {
        appendAppLog("github.log", message)
    }

    /// Called from any thread; dispatches cleanup to main then schedules next poll.
    private func finishPulse(hasPending: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pulseInFlight = false
            self.scheduleNextPulse(hasPending: hasPending)
        }
    }

    /// Cancels any pending scheduled poll and schedules a new one on the main queue.
    /// Must run on the main thread.
    private func scheduleNextPulse(hasPending: Bool, delay: Double? = nil) {
        nextPulse?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.pollPulse() }
        nextPulse = work
        let d = delay ?? (hasPending ? 60.0 : 300.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + d, execute: work)
    }

    // MARK: - Activity (contribution calendar, 30 min cadence)

    private func pollActivity() {
        guard !DemoEngine.isPollerPaused else { scheduleNextActivity(); return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.activityInFlight else { return }
            guard let token = KeychainStore.shared.get("github-token"),
                  Self.isWanted else {
                self.scheduleNextActivity()
                return
            }
            self.activityInFlight = true
            let gen = self.tokenGeneration
            DispatchQueue.global(qos: .background).async { self.fetchActivity(token: token, generation: gen) }
        }
    }

    private func fetchActivity(token: String, generation: Int) {
        guard let url = URL(string: "https://api.github.com/graphql") else {
            finishActivity(); return
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let body = try? JSONSerialization.data(withJSONObject: ["query": Self.activityQuery]) else {
            finishActivity(); return
        }
        req.httpBody = body

        URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
            guard let self else { return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data, code == 200 else {
                self.nbLog("activity HTTP \(code)")
                self.finishActivity()
                return
            }
            if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let errors = root["errors"] as? [[String: Any]], !errors.isEmpty {
                    self.nbLog("activity GraphQL errors: \(errors.count)")
                }
                guard root["data"] is [String: Any] else {
                    self.finishActivity(); return
                }
            }
            guard let activity = GitHubActivity.parse(data) else {
                self.finishActivity(); return
            }
            DispatchQueue.main.async {
                guard self.tokenGeneration == generation else { return }
                AppState.shared.githubActivity = activity
            }
            self.finishActivity()
        }.resume()
    }

    /// Refreshes activity data immediately if stale. Safe to call from any thread.
    func refreshActivityIfStale(maxAge: TimeInterval = 300) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.activityInFlight else { return }
            guard GitHubPulse.isStale(fetchedAt: AppState.shared.githubActivity?.fetchedAt,
                                      maxAge: maxAge) else { return }
            self.nextActivity?.cancel()
            self.nextActivity = nil
            self.pollActivity()
        }
    }

    private func finishActivity() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.activityInFlight = false
            self.scheduleNextActivity()
        }
    }

    private func scheduleNextActivity(delay: Double? = nil) {
        nextActivity?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.pollActivity() }
        nextActivity = work
        let d = delay ?? 1800.0   // 30 minutes
        DispatchQueue.main.asyncAfter(deadline: .now() + d, execute: work)
    }

    // MARK: - GraphQL queries

    private static let graphQLQuery = """
    query {
      viewer {
        login
        pullRequests(states: OPEN, first: 20, orderBy: {field: UPDATED_AT, direction: DESC}) {
          nodes {
            number title url isDraft reviewDecision
            repository { nameWithOwner url }
            commits(last: 1) {
              nodes { commit { oid statusCheckRollup { state } } }
            }
          }
        }
        repositories(first: 10, ownerAffiliations: [OWNER], orderBy: {field: PUSHED_AT, direction: DESC}) {
          nodes {
            nameWithOwner url isArchived
            defaultBranchRef {
              name
              target { ... on Commit { oid statusCheckRollup { state } } }
            }
          }
        }
      }
      reviewRequested: search(query: "is:pr is:open review-requested:@me archived:false", type: ISSUE, first: 20) {
        issueCount
        nodes {
          ... on PullRequest {
            number title url isDraft
            author { login }
            repository { nameWithOwner url }
          }
        }
      }
    }
    """

    private static let activityQuery = """
    query {
      viewer {
        login
        contributionsCollection {
          contributionCalendar {
            totalContributions
            weeks {
              contributionDays {
                date contributionCount contributionLevel weekday
              }
            }
          }
        }
      }
    }
    """
}
