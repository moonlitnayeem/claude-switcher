import Foundation

/// Membership, credentials and provider observations live in memory. A local
/// restriction contains only account identifiers and survives relay replacement.
actor PoolState {
    struct Attempt: Equatable {
        /// Nil for a request from nobody in the pool, which goes out as sent.
        var member: String?
        /// Nil means the token the request arrived with.
        var token: String?
        var fableRecheck: UUID? = nil
        var staleProbe: UUID? = nil
    }

    private struct Runtime {
        var served = 0
        var lastServed: Date?
        var lastSeen: Date?
        /// Digest of the lent token the service refused. Lending stops until
        /// Graft hands over a different one, which is what a renewed login is.
        var refusedToken: String?
    }

    private struct Conversation {
        var from: String
        var servedBy: String?
        var servedAccount: String?
        var lastAt: Date
        var requests = 0
        var model: String?
        var cacheLifetime: TimeInterval = PoolPolicy.shortCache
        var passedOver: [PoolPass] = []
        /// Set by the first answer to a request carrying a thread. From then
        /// on only such answers say where the conversation is: a title asked
        /// for beside it, answered by another account, holds none of it, and
        /// letting it move `servedBy` sent the next turn to an account that
        /// answered `thread_not_found` and named the wrong one in the dropdown.
        var threaded = false
        var startedAt: Date?
        var promptedAt: Date?
    }

    /// Long enough for the menu to go on naming a conversation somebody stepped
    /// away from for the afternoon, short enough that the list stays the day's.
    static let conversationMemory: TimeInterval = 24 * 60 * 60

    private var configuration: PoolConfiguration?
    private var policy = AccountPolicyStore(directory: UsagePool.directory)
    private var acceptsPolicyChanges = true
    private var pausedProfiles: Set<String> = []
    private var memberByDigest: [String: String] = [:]
    private var lendingDigest: [String: String] = [:]
    private var runtime: [String: Runtime] = [:]
    /// By account rather than by member: two members on one account are one
    /// allowance, and what the service says about either is true of both.
    private var limits: [String: PoolLimits] = [:]
    /// Long enough to avoid hammering a genuinely exhausted backup, short enough
    /// to discover an early reset on an inference-only account automatically.
    static let staleProbeInterval: TimeInterval = 5 * 60

    private enum FableRecheck {
        case queued, sending(UUID)
        // Claude Code can recreate a thread only after its first attempt on
        // the other account reports that the old thread lives elsewhere.
        case awaitingNewThread(session: String?, until: Date)
    }
    private enum StaleProbe {
        case sending(UUID)
        case awaitingNewThread(session: String?, modelFamily: String?, until: Date)
    }
    private var fableRechecks: [String: FableRecheck] = [:]
    private var staleProbes: [String: StaleProbe] = [:]
    private var conversations: [String: Conversation] = [:]
    private var recent: [PoolRouting] = []
    private var activeRoutes: [UUID: PoolActiveRoute] = [:]

    func beginAttempt(_ id: UUID, from: String, attempt: Attempt, model: String?,
                      selection: AccountPolicyStore.Selection?) -> Bool {
        guard policy.readError == nil, selection == policy.selections[from] else { return false }
        let member = attempt.member ?? from
        if let selection {
            guard member == selection.member,
                  let sender = validatedMember(from, account: selection.profileAccount), sender.borrowsFrom != nil,
                  let selected = validatedMember(member, account: selection.memberAccount) else { return false }
            if member != from {
                guard configuration?.enabled == true, !pausedProfiles.contains(from),
                      sender.borrowsFrom?.contains(member) == true, attempt.token != nil,
                      selected.token == attempt.token, runtime[member]?.refusedToken == nil else { return false }
            }
        }
        activeRoutes[id] = PoolActiveRoute(from: from, member: member, model: model, startedAt: Date())
        return true
    }

    func finishRequest(_ id: UUID) {
        activeRoutes.removeValue(forKey: id)
    }

    nonisolated let clients = RelayClients()

    private func accountKey(_ id: String) -> String {
        configuration?.members.first { $0.id == id }?.account ?? id
    }

    func stopPolicyChanges() { acceptsPolicyChanges = false }

    func policyBlocksPassThrough(for own: String?) -> Bool {
        if policy.readError != nil { return true }
        guard let own else { return !policy.selections.isEmpty }
        guard let choice = policy.selections[own] else { return false }
        return choice.member != own || validatedMember(own, account: choice.profileAccount) == nil
    }

    private func validatedMember(_ id: String, account: String) -> PoolMember? {
        let matches = configuration?.members.filter { $0.id == id } ?? []
        guard matches.count == 1, matches[0].account == account else { return nil }
        return matches[0]
    }

    private func selectableAccounts(for sender: PoolMember, in members: [PoolMember]) -> [PoolMember] {
        guard acceptsPolicyChanges, policy.readError == nil, sender.borrowsFrom != nil,
              AccountPolicyStore.validID(sender.id), let profileAccount = sender.account,
              AccountPolicyStore.validID(profileAccount), validatedMember(sender.id, account: profileAccount) != nil,
              sender.identify.contains(where: { memberByDigest[$0] == sender.id }) else { return [] }
        func available(_ member: PoolMember) -> Bool {
            member.token != nil && runtime[member.id]?.refusedToken == nil
        }
        return Self.candidates(for: sender, in: members, canLend: available).filter { member in
            guard AccountPolicyStore.validID(member.id), let account = member.account,
                  AccountPolicyStore.validID(account), validatedMember(member.id, account: account) != nil
            else { return false }
            return member.id == sender.id || (configuration?.enabled == true && available(member))
        }
    }

    private func setAccountPolicy(_ change: PoolAccountPolicyChange) -> String? {
        guard acceptsPolicyChanges else { return "The relay is restarting. Try again in a moment." }
        if let error = policy.readError { return error }
        guard AccountPolicyStore.validID(change.profile) else { return "Choose a known Claude profile." }
        let members = configuration?.members ?? []
        let senders = members.filter { $0.id == change.profile && $0.borrowsFrom != nil }
        if change.mode == .automatic {
            guard change.member == nil, senders.count == 1 || policy.selections[change.profile] != nil else {
                return "Choose a known Claude profile to turn on automatic switching."
            }
            return policy.save(nil, for: change.profile)
        }
        guard senders.count == 1, let sender = senders.first, let profileAccount = sender.account else {
            return "The relay cannot confirm this profile's account yet."
        }
        guard let id = change.member, let selected = selectableAccounts(for: sender, in: members).first(where: { $0.id == id }),
              let account = selected.account else {
            return "Choose an available account already connected to this profile."
        }
        return policy.save(.init(member: id, profileAccount: profileAccount, memberAccount: account), for: sender.id)
    }

    func updateRouting(_ replacement: PoolConfiguration?, paused: Set<String>?, allowedLenders: [String: [String]]?) {
        if let paused { pausedProfiles = paused }
        if let replacement {
            configure(replacement)
        } else if let allowedLenders, var existing = configuration {
            // A locked keychain can still revoke permission. New grants wait
            // until this relay can receive fresh identities and credentials.
            for index in existing.members.indices {
                let member = existing.members[index]
                let allowed = Set(allowedLenders[member.id] ?? [])
                existing.members[index].borrowsFrom = member.borrowsFrom?.filter(allowed.contains)
            }
            configuration = existing
        }
    }

    func configure(_ new: PoolConfiguration, now: Date = Date()) {
        configuration = new
        var owners: [String: Set<String>] = [:]
        lendingDigest = [:]
        var kept: [String: Runtime] = [:]
        for member in new.members {
            for digest in member.identify { owners[digest, default: []].insert(member.id) }
            var state = runtime[member.id] ?? Runtime()
            if let token = member.token {
                let digest = UsagePool.digest(token)
                lendingDigest[member.id] = digest
                owners[digest, default: []].insert(member.id)
                if state.refusedToken != digest { state.refusedToken = nil }
            }
            // The service's own headers are fresher than any poll while the
            // account is in use, and a poll is fresher once it has gone quiet.
            let key = member.account ?? member.id
            if var pushed = member.limits, pushed.observed > (limits[key]?.observed ?? .distantPast) {
                preserveCooldowns(in: &pushed, from: limits[key], now: now)
                limits[key] = pushed
            }
            kept[member.id] = state
        }
        // The proxy sees only the bearer. When two distinct senders share it,
        // choosing either one's permissions could borrow an unauthorized account.
        memberByDigest = owners.compactMapValues { $0.count == 1 ? $0.first : nil }
        runtime = kept
        // An account nobody names any more is forgotten with its members, so
        // what is held stays the size of what Graft describes.
        let named = Set(new.members.map { $0.account ?? $0.id })
        limits = limits.filter { named.contains($0.key) }
        fableRechecks = fableRechecks.filter { key, check in
            guard named.contains(key), (limits[key]?.fableRefusedUntil ?? .distantPast) > now
            else { return false }
            if case .awaitingNewThread(_, let until) = check { return until > now }
            return true
        }
        staleProbes = staleProbes.filter { key, probe in
            guard named.contains(key) else { return false }
            if case .awaitingNewThread(_, _, let until) = probe { return until > now }
            return true
        }
    }

    func recheckFable(_ id: String, now: Date = Date()) {
        guard let configuration, configuration.enabled,
              let member = configuration.members.first(where: { $0.id == id }) else { return }
        let original = member.borrowsFrom != nil && !pausedProfiles.contains(id)
            && member.identify.contains { memberByDigest[$0] == id }
        let lendable = member.token != nil && runtime[id]?.refusedToken == nil
        guard original || lendable else { return }
        let key = member.account ?? id
        guard fableRechecks[key] == nil,
              let reading = limits[key], (reading.fableRefusedUntil ?? .distantPast) > now,
              PoolPolicy.hasRoom(reading, now: now) else { return }
        fableRechecks[key] = .queued
    }

    func finishFableRecheck(_ id: String, ticket: UUID, newThreadFor session: String? = nil,
                            threadMissing: Bool = false, now: Date = Date()) {
        let key = accountKey(id)
        guard case .sending(ticket) = fableRechecks[key] else { return }
        fableRechecks[key] = threadMissing ? .awaitingNewThread(session: session, until: now + 60) : nil
    }

    func finishStaleProbe(_ id: String, ticket: UUID, newThreadFor session: String? = nil,
                          model: String? = nil, threadMissing: Bool = false, now: Date = Date()) {
        let key = accountKey(id)
        guard case .sending(ticket) = staleProbes[key] else { return }
        staleProbes[key] = threadMissing
            ? .awaitingNewThread(session: session, modelFamily: PoolRequest.modelFamily(model), until: now + 60)
            : nil
    }

    /// Which member a token belongs to. Every request carrying one counts as
    /// that Claude being connected, whatever the request was for.
    func member(for bearer: String, now: Date = Date()) -> (id: String, restricted: Bool)? {
        guard let id = memberByDigest[UsagePool.digest(bearer)] else { return nil }
        runtime[id, default: Runtime()].lastSeen = now
        return (id, policy.selections[id] != nil)
    }

    /// The sender first, then the accounts it was given, each account once. A
    /// lender on the sender's own account is no lender at all: borrowing from
    /// it spends the very allowance the request was going to spend anyway.
    /// An account given under two names is counted under the first that can
    /// lend: a Claude's own login lapses while it stays closed, and the same
    /// account signed in through Graft lasts a year.
    static func candidates(for sender: PoolMember, in members: [PoolMember],
                           canLend: (PoolMember) -> Bool = { $0.token != nil }) -> [PoolMember] {
        var out = [sender]
        var place: [String: Int] = [sender.account ?? sender.id: 0]
        for id in sender.borrowsFrom ?? [] {
            guard id != sender.id, let lender = members.first(where: { $0.id == id }) else { continue }
            let account = lender.account ?? lender.id
            if let index = place[account] {
                if index > 0, !canLend(out[index]), canLend(lender) { out[index] = lender }
            } else {
                place[account] = out.count
                out.append(lender)
            }
        }
        return out
    }

    /// `bound` is a request only the account that last answered the
    /// conversation can take as it stands: one carrying reasoning that account
    /// wrote (`PoolRequest.carriesBoundReasoning`), or continuing a thread
    /// stored there (`PoolRequest.continuesThread`).
    func requestPlan(own: String, session: String?, pinned: Bool, bound: Bool, model: String?,
                     continuing: Bool, inspectedChoice: Bool) -> (attempts: [Attempt], selection: AccountPolicyStore.Selection?) {
        let choice = policy.selections[own]
        guard choice == nil || inspectedChoice else { return ([], choice) }
        return (plan(own: own, session: session, pinned: pinned, bound: bound, model: model, continuing: continuing), choice)
    }

    private func plan(own: String, session: String?, pinned: Bool, bound: Bool = false, model: String? = nil,
              continuing: Bool = false, now: Date = Date()) -> [Attempt] {
        guard policy.readError == nil else { return [] }
        let choice = policy.selections[own]
        if let choice {
            guard let sender = validatedMember(own, account: choice.profileAccount), sender.borrowsFrom != nil,
                  validatedMember(choice.member, account: choice.memberAccount) != nil else { return [] }
            if bound {
                let held = session.flatMap { conversations[$0] }
                if let held, let account = held.servedAccount {
                    guard held.from == own, account == choice.memberAccount else { return [] }
                    if continuing, !held.threaded, choice.member != own { return [] }
                } else if choice.member != own {
                    return []
                }
            }
        }
        let asSent = choice == nil || choice?.member == own ? [Attempt(member: own, token: nil)] : []
        guard let configuration, configuration.enabled, !pinned, !pausedProfiles.contains(own),
              let sender = configuration.members.first(where: { $0.id == own })
        else { return asSent }
        func canLend(_ member: PoolMember) -> Bool {
            member.token != nil && runtime[member.id]?.refusedToken != lendingDigest[member.id]
        }
        let candidates = Self.candidates(for: sender, in: configuration.members, canLend: canLend)
        guard candidates.count > 1 || fableRechecks[accountKey(own)] != nil else { return asSent }
        var recheck: String?
        var probeTarget: String?
        let modelFamily = PoolRequest.modelFamily(model)
        let pageDirectory = Graft.applicationSupport
            .appending(path: "ClaudeSwitcher").appending(path: "display-usage")
        let accounts = candidates.map { member in
            let key = member.account ?? member.id
            var reading = limits[key]
            for identifier in [member.account, member.id].compactMap({ $0 }) {
                guard let current = reading,
                      let page = IncludedAllowancePage.load(account: identifier, from: pageDirectory, now: now)
                else { continue }
                let corrected = page.corrected(current, now: now)
                if corrected != current {
                    limits[key] = corrected
                    reading = corrected
                }
                break
            }
            if recheck == nil, choice == nil || choice?.member == member.id,
               PoolRequest.usesIncludedAllowance(model), member.id == own || canLend(member),
               (reading?.fableRefusedUntil ?? .distantPast) > now, PoolPolicy.hasRoom(reading, now: now),
               let requested = fableRechecks[key] {
                switch requested {
                case .queued:
                    recheck = member.id
                case .awaitingNewThread(let expected, let until) where !continuing && expected == session && until > now:
                    recheck = member.id
                default:
                    break
                }
                if recheck == member.id { reading?.fableRefusedUntil = nil }
            }
            if probeTarget == nil, recheck == nil, choice == nil, member.id != own, canLend(member),
               case .awaitingNewThread(let expected, let expectedFamily, let until) = staleProbes[key],
               !continuing, expected == session, expectedFamily == modelFamily, until > now {
                probeTarget = member.id
                reading = nil
            }
            return PoolPolicy.Account(id: member.id, limits: reading, usable: member.id == own || canLend(member))
        }
        // One account is one candidate whichever name it came under, so a
        // name the relay did not count stands for the one it did: a choice
        // made in the dropdown, and equally the name that last answered, once
        // a Claude's own login lapsed and the same account signed in here took
        // its place.
        func counted(_ id: String) -> String? {
            let account = configuration.members.first { $0.id == id }.map { $0.account ?? $0.id } ?? id
            return candidates.first { ($0.account ?? $0.id) == account }?.id
        }
        let primaryFirst = configuration.primaryFirst ?? true
        var prefer: [String] = []
        var holder: String?
        if let session {
            let held = conversations[session]
            if let chosen = configuration.assignments?[session], let id = counted(chosen) {
                prefer.append(id)
            }
            if let last = held?.servedBy,
               bound || (!primaryFirst && now.timeIntervalSince(held!.lastAt) < held!.cacheLifetime) {
                // Reasoning outlives the cache: it is lost on any other account
                // however long the conversation sat. So it stays until its
                // account has no room, and then stays wherever it went, which
                // loses the reasoning once rather than on every move. A person
                // moving it from the dropdown is that one move, made on purpose.
                holder = counted(last)
                if let holder { prefer.append(holder) }
            }
        }
        // Nothing says where a conversation the relay has not seen wrote its
        // reasoning — one from before the relay last started, one with no
        // session, or one last answered by an account no longer lent — and
        // the sender's own account is where it began.
        if bound, holder == nil { prefer.append(own) }
        if let recheck { prefer.insert(recheck, at: 0) }
        if let probeTarget { prefer.insert(probeTarget, at: 0) }
        var ids = PoolPolicy.order(own: own, accounts: accounts, prefer: prefer, now: now,
                                   model: model, primaryFirst: primaryFirst)
        // If no backup has room under cached observations, an inference-only
        // backup whose last reading is stale can still have been reset early.
        // Probe the stalest such backup once rather than failing on a 429.
        if choice == nil, recheck == nil, probeTarget == nil, !ids.contains(where: { $0 != own }) {
            let staleBackup = candidates
                .filter { member in
                    guard member.id != own, canLend(member) else { return false }
                    let key = member.account ?? member.id
                    guard staleProbes[key] == nil, let reading = limits[key] else { return false }
                    return now.timeIntervalSince(reading.observed) >= Self.staleProbeInterval
                }
                .min { (limits[$0.account ?? $0.id]?.observed ?? .distantFuture) < (limits[$1.account ?? $1.id]?.observed ?? .distantFuture) }
            if let staleBackup {
                probeTarget = staleBackup.id
                let ownReading = accounts.first { $0.id == own }?.limits
                let ownHasRoom = PoolPolicy.hasRoom(ownReading, now: now, model: model, useMargin: !primaryFirst)
                ids = ownHasRoom ? [own, staleBackup.id, own] : [staleBackup.id, own]
            }
        }
        // The last word is always the sender's own account, asked again if it
        // was asked already: whatever the lent accounts answered last — a
        // refused login, a plan without the model, a limit with their own
        // reset times — is about a login Claude Code never sent.
        if ids.last != own { ids.append(own) }
        if let choice { ids = ids.contains(choice.member) ? [choice.member] : [] }
        return ids.map { id in
            let token = id == own ? nil : candidates.first { $0.id == id }?.token
            var attempt = Attempt(member: id, token: token)
            if id == recheck {
                recheck = nil
                let ticket = UUID()
                fableRechecks[accountKey(id)] = .sending(ticket)
                attempt.fableRecheck = ticket
            }
            if id == probeTarget {
                probeTarget = nil
                let ticket = UUID()
                staleProbes[accountKey(id)] = .sending(ticket)
                attempt.staleProbe = ticket
            }
            return attempt
        }
    }

    // A general usage poll or a successful answer on another model says
    // nothing about a model-specific refusal that the service has already timed.
    private func preserveCooldowns(in reading: inout PoolLimits, from previous: PoolLimits?, now: Date,
                                   clearingModel: String? = nil, clearAccountWide: Bool = false) {
        let clearingIncluded = clearingModel != nil && PoolRequest.usesIncludedAllowance(clearingModel)
        let clearingFamily = PoolRequest.modelFamily(clearingModel)
        if !clearingIncluded, let until = previous?.fableRefusedUntil, until > now {
            reading.fableRefusedUntil = max(until, reading.fableRefusedUntil ?? .distantPast)
        }
        if let previousModels = previous?.modelRefusedUntil {
            var merged = reading.modelRefusedUntil ?? [:]
            for (family, until) in previousModels where until > now && family != clearingFamily {
                merged[family] = max(until, merged[family] ?? .distantPast)
            }
            reading.modelRefusedUntil = merged.isEmpty ? nil : merged
        }
        if !clearAccountWide, let until = previous?.refusedUntil, until > now {
            reading.refusedUntil = max(until, reading.refusedUntil ?? .distantPast)
        }
    }

    func observe(_ member: String, _ headers: [(String, String)], status: Int, borrowed: Bool,
                 model: String?, recheck: UUID? = nil, staleProbe: UUID? = nil,
                 now: Date = Date()) -> PoolPolicy.Outcome {
        let key = accountKey(member)
        let succeeded = (200..<300).contains(status)
        let probeAnswered = succeeded || status == 429
        // Discard the old forecast only when the provider has answered the
        // requested recheck or stale probe with fresh allowance evidence.
        if let recheck, case .sending(recheck) = fableRechecks[key], probeAnswered {
            limits[key]?.fableRefusedUntil = nil
        }
        if let staleProbe, case .sending(staleProbe) = staleProbes[key], probeAnswered {
            limits[key]?.clearRefusals(for: model)
        }
        let previous = limits[key]
        if var parsed = PoolLimits.parse(headers, now: now, model: model, rateLimited: status == 429) {
            // Refusals sometimes omit one or both regular usage figures.
            // Missing data must not reopen an exhausted general window.
            let names = Set(headers.map { $0.0.lowercased() })
            if let previous {
                if !names.contains("anthropic-ratelimit-unified-5h-utilization") {
                    parsed.fiveHour = previous.fiveHour
                    parsed.fiveHourReset = parsed.fiveHourReset ?? previous.fiveHourReset
                }
                if !names.contains("anthropic-ratelimit-unified-7d-utilization") {
                    parsed.week = previous.week
                    parsed.weekReset = parsed.weekReset ?? previous.weekReset
                }
            }
            preserveCooldowns(in: &parsed, from: previous, now: now,
                              clearingModel: succeeded ? model : nil,
                              clearAccountWide: succeeded)
            limits[key] = parsed
        } else if succeeded {
            limits[key]?.clearRefusals(for: model)
            limits[key]?.observed = now
        }
        let outcome = PoolPolicy.outcome(status: status, headers: headers, borrowed: borrowed,
                                         now: now, model: model)
        switch outcome {
        case .deliver, .refusedForAccount:
            break
        case .exhausted(let until), .fableExhausted(let until), .modelExhausted(_, let until):
            var known = limits[key]
                ?? PoolLimits(fiveHour: 0, fiveHourReset: nil, week: 0, weekReset: nil,
                              refusedUntil: nil, observed: now)
            known.observed = now
            switch outcome {
            case .fableExhausted:
                known.fableRefusedUntil = max(until, known.fableRefusedUntil ?? .distantPast)
            case .modelExhausted(let family, _):
                var map = known.modelRefusedUntil ?? [:]
                map[family] = max(until, map[family] ?? .distantPast)
                known.modelRefusedUntil = map
            default:
                known.refusedUntil = max(until, known.refusedUntil ?? .distantPast)
            }
            limits[key] = known
        case .loginRefused:
            runtime[member, default: Runtime()].refusedToken = lendingDigest[member]
        }
        return outcome
    }

    func served(by member: String, from own: String, session: String?, status: Int,
                passedOver: [PoolPass], model: String?, cacheLifetime: TimeInterval,
                threaded: Bool = false, starts: Bool = false, prompted: Bool = false,
                now: Date = Date()) {
        runtime[member, default: Runtime()].served += 1
        runtime[member, default: Runtime()].lastServed = now
        if let session {
            var held = conversations[session]
                ?? Conversation(from: own, lastAt: now, startedAt: starts ? now : nil)
            held.from = own
            held.requests += 1
            if prompted { held.promptedAt = now }
            if threaded || !held.threaded {
                held.lastAt = now
                held.model = model ?? held.model
                held.passedOver = passedOver
                // A failed answer wrote no cache anywhere, so it moves nothing.
                if (200..<300).contains(status) {
                    held.servedBy = member
                    held.servedAccount = accountKey(member)
                    held.cacheLifetime = cacheLifetime
                    held.threaded = held.threaded || threaded
                }
            }
            conversations[session] = held
            if conversations.count > 256 {
                conversations = conversations.filter {
                    now.timeIntervalSince($0.value.lastAt) < Self.conversationMemory
                }
            }
        }
        recent.append(PoolRouting(at: now, from: own, servedBy: member, status: status,
                                  passedOver: passedOver, model: model, session: session))
        if recent.count > 40 { recent.removeFirst(recent.count - 40) }
    }

    func status(binary: String, pid: Int32, started: Date, change: PoolAccountPolicyChange? = nil,
                now: Date = Date()) -> PoolStatus {
        let policyError = change.flatMap(setAccountPolicy) ?? policy.readError
        let configuredMembers = configuration?.members ?? []
        var selectable: [String: [String]] = [:]
        for sender in configuredMembers where sender.borrowsFrom != nil {
            selectable[sender.id] = selectableAccounts(for: sender, in: configuredMembers).map(\.id)
        }
        let members = (configuration?.members ?? []).map { member in
            let state = runtime[member.id]
            return PoolMemberStatus(id: member.id, limits: limits[member.account ?? member.id],
                                    served: state?.served ?? 0, lastServed: state?.lastServed,
                                    lastSeen: state?.lastSeen,
                                    tokenRefused: state?.refusedToken != nil,
                                    fableRecheckPending: fableRechecks[member.account ?? member.id] == nil ? nil : true)
        }
        let sessions = conversations
            .filter { now.timeIntervalSince($0.value.lastAt) < Self.conversationMemory }
            .sorted { $0.value.lastAt > $1.value.lastAt }
            .prefix(64)
            .map { id, held in
                PoolSession(id: id, from: held.from, servedBy: held.servedBy, lastAt: held.lastAt,
                            requests: held.requests, model: held.model,
                            cachedUntil: held.servedBy == nil ? nil
                                : held.lastAt.addingTimeInterval(held.cacheLifetime),
                            passedOver: held.passedOver, startedAt: held.startedAt,
                            promptedAt: held.promptedAt)
            }
        return PoolStatus(binary: binary, pid: pid, started: started,
                          enabled: configuration?.enabled ?? false,
                          configured: configuration != nil, members: members,
                          recent: recent, sessions: Array(sessions), openExchanges: clients.inFlight,
                          activeRoutes: Array(activeRoutes.values.sorted { $0.startedAt > $1.startedAt }.prefix(64)),
                          exclusiveAccounts: policy.readError == nil ? policy.selections.mapValues(\.member) : nil,
                          selectableAccounts: policy.readError == nil ? selectable : nil,
                          accountPolicyError: policyError)
    }
}
