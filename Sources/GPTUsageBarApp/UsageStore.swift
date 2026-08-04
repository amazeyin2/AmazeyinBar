import AppKit
import Foundation
import SwiftUI

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var accountStates: [AccountUsageState] = []
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isImporting = false
    @Published var lastError: String?
    @Published var lastImportMessage: String?

    private let configStore: ConfigStore
    private let service: UsageService
    private let chromeImportService: ChromeImportService
    private let curlImportService: CurlImportService
    private var refreshTask: Task<Void, Never>?

    init(
        configStore: ConfigStore,
        service: UsageService = UsageService(),
        chromeImportService: ChromeImportService = ChromeImportService(),
        curlImportService: CurlImportService = CurlImportService()
    ) {
        self.configStore = configStore
        self.service = service
        self.chromeImportService = chromeImportService
        self.curlImportService = curlImportService
        syncAccountsFromConfig()
        startAutoRefresh()
    }

    deinit {
        refreshTask?.cancel()
    }

    func syncAccountsFromConfig() {
        accountStates = configStore.config.accounts
            .filter(\.enabled)
            .map { existingState(for: $0) ?? AccountUsageState(account: $0) }
    }

    func reloadConfiguration() async {
        do {
            try configStore.reload()
            syncAccountsFromConfig()
            startAutoRefresh()
            await refresh(forceReloadConfig: false)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refresh(forceReloadConfig: Bool = false) async {
        if forceReloadConfig {
            do {
                try configStore.reload()
                syncAccountsFromConfig()
            } catch {
                lastError = error.localizedDescription
                return
            }
        }

        isRefreshing = true
        lastError = nil
        defer { isRefreshing = false }

        let accounts = configStore.config.accounts.filter(\.enabled)
        var nextStates: [AccountUsageState] = []

        for account in accounts {
            do {
                let payload = try await service.fetchUsage(for: account)
                nextStates.append(AccountUsageState(account: account, payload: payload, lastRefresh: .now))
            } catch {
                let previous = existingState(for: account) ?? AccountUsageState(account: account)
                var failedState = previous
                failedState.errorMessage = error.localizedDescription
                failedState.lastRefresh = .now
                nextStates.append(failedState)
            }
        }

        accountStates = nextStates
        lastRefresh = .now
        if let firstError = nextStates.compactMap(\.errorMessage).first {
            lastError = firstError
        }
    }

    func importFromChrome() async {
        await importAccounts {
            let summary = try await chromeImportService.importAccounts(using: configStore.config)
            return summary.importedAccounts
        }
    }

    func importFromClipboardCurl() async {
        await importAccounts {
            guard let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                throw CurlImportError.clipboardEmpty
            }
            return try curlImportService.importAccounts(from: text).importedAccounts
        }
    }

    private func importAccounts(_ loader: () async throws -> [AccountConfig]) async {
        isImporting = true
        lastError = nil
        lastImportMessage = nil
        defer { isImporting = false }

        do {
            var nextConfig = configStore.config
            let importedAccounts = try await loader()
            nextConfig.accounts = mergeAccounts(existing: nextConfig.accounts, imported: importedAccounts)
            try configStore.save(nextConfig)
            syncAccountsFromConfig()
            startAutoRefresh()
            lastImportMessage = "已导入 \(importedAccounts.count) 个账号"
            await refresh(forceReloadConfig: false)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func statusTitle() -> String {
        let mode = configStore.config.titleMode
        if accountStates.isEmpty {
            return "GPT --"
        }

        switch mode {
        case .fiveHour:
            return accountStates.map { "\($0.account.name.shortMenuLabel)\($0.payload?.fiveHour.utilization ?? 0)%" }.joined(separator: " ")
        case .sevenDay:
            return accountStates.map { "\($0.account.name.shortMenuLabel)\($0.payload?.sevenDay.utilization ?? 0)%" }.joined(separator: " ")
        case .compact:
            let healthyCount = accountStates.filter { $0.payload != nil }.count
            return "GPT \(healthyCount)/\(accountStates.count)"
        }
    }

    func statusUsageItems(limit: Int = 2) -> [StatusUsageItem] {
        let mode = configStore.config.titleMode
        return Array(accountStates.prefix(limit)).flatMap { state in
            switch mode {
            case .fiveHour:
                [statusItem(for: state, window: .fiveHour)]
            case .sevenDay:
                [statusItem(for: state, window: .sevenDay)]
            case .compact:
                [
                    statusItem(for: state, window: .fiveHour),
                    statusItem(for: state, window: .sevenDay),
                ]
            }
        }
    }

    func hiddenStatusRingCount(limit: Int = 2) -> Int {
        max(accountStates.count - limit, 0)
    }

    private func startAutoRefresh() {
        refreshTask?.cancel()
        let refreshInterval = max(configStore.config.refreshIntervalSeconds, 60)
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh(forceReloadConfig: false)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(refreshInterval))
                if Task.isCancelled { return }
                await self.refresh(forceReloadConfig: false)
            }
        }
    }

    private func existingState(for account: AccountConfig) -> AccountUsageState? {
        accountStates.first { $0.account.id == account.id }
    }

    private func statusItem(for state: AccountUsageState, window: StatusUsageItem.Window) -> StatusUsageItem {
        let utilization: Int?
        switch window {
        case .fiveHour:
            utilization = state.payload?.fiveHour.utilization
        case .sevenDay:
            utilization = state.payload?.sevenDay.utilization
        }

        return StatusUsageItem(
            id: "\(state.id)-\(window.rawValue)",
            window: window,
            utilization: utilization,
            hasError: state.errorMessage != nil
        )
    }

    private func mergeAccounts(existing: [AccountConfig], imported: [AccountConfig]) -> [AccountConfig] {
        var merged = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for account in imported {
            merged[account.id] = account
        }
        return merged.values.sorted { $0.id < $1.id }
    }
}

struct StatusUsageItem: Identifiable {
    enum Window: String {
        case fiveHour
        case sevenDay
    }

    let id: String
    let window: Window
    let utilization: Int?
    let hasError: Bool
}

private extension String {
    var shortMenuLabel: String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(4))
    }
}
