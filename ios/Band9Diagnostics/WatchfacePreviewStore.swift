import Combine
import Foundation

/// Public catalog artwork only. Device active state always comes from BLE.
final class WatchfacePreviewStore: ObservableObject {
    @Published private(set) var images: [String: URL] = [:]
    @Published private(set) var unavailable = Set<String>()
    @Published private(set) var isLoading = Set<String>()
    var didUpdate: (() -> Void)?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var deviceModel: String?
    private var fetchedAt: [String: Date] = [:]
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 18
        return URLSession(configuration: configuration)
    }()

    func url(for id: String) -> URL? { images[id] }

    func reset() {
        task?.cancel()
        task = nil
        generation = UUID()
        deviceModel = nil
        images = [:]
        unavailable = []
        isLoading = []
        fetchedAt = [:]
    }

    func load(model: String?, faces: [DeviceWatchFace]) {
        guard let model = model, model.hasPrefix("miwear."), model.utf8.count <= 128 else { return }
        if deviceModel != model { reset(); deviceModel = model }
        let now = Date()
        let identifiers = faces.sorted { $0.isActive && !$1.isActive }.prefix(100).map(\.id)
        let wanted = Set(identifiers)
        images = images.filter { wanted.contains($0.key) }
        let pending = identifiers.filter { id in
            now.timeIntervalSince(fetchedAt[id] ?? .distantPast) > 120
        }
        guard !pending.isEmpty, !pending.allSatisfy({ isLoading.contains($0) }) else { return }
        // A new device/list invalidates the old operation before its completion
        // can put artwork into another device's state.
        task?.cancel()
        generation = UUID()
        let expected = generation
        isLoading = Set(pending)
        task = Task { @MainActor [weak self] in
            guard let self = self else { return }
            for id in pending {
                guard !Task.isCancelled, self.generation == expected else { return }
                let imageURL = try? await self.fetch(model: model, id: id)
                guard !Task.isCancelled, self.generation == expected else { return }
                self.isLoading.remove(id)
                self.fetchedAt[id] = Date()
                if let imageURL = imageURL {
                    self.images[id] = imageURL
                    self.unavailable.remove(id)
                } else {
                    self.images.removeValue(forKey: id)
                    self.unavailable.insert(id)
                }
                self.didUpdate?()
            }
            self.task = nil
        }
    }

    private struct Catalog: Decodable {
        struct Detail: Decodable {
            let id: String?
            let idV2: String?
            let icon: String?
            enum CodingKeys: String, CodingKey { case id, icon; case idV2 = "id_v2" }
        }
        let code: Int
        let data: Detail
    }

    private func fetch(model: String, id: String) async throws -> URL? {
        guard !id.isEmpty, id.utf8.count <= 256 else { return nil }
        var components = URLComponents(string: "https://watch-appstore.iot.mi.com/api/watchface/prize/detail")!
        components.queryItems = [URLQueryItem(name: "model", value: model), URLQueryItem(name: "id", value: id)]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url?.host == "watch-appstore.iot.mi.com",
              response.url?.scheme == "https",
              response.expectedContentLength <= 1_048_576 else { return nil }
        var data = Data()
        for try await byte in bytes {
            if Task.isCancelled { throw CancellationError() }
            guard data.count < 1_048_576 else { return nil }
            data.append(byte)
        }
        let result = try JSONDecoder().decode(Catalog.self, from: data)
        // A 200 response can contain an empty main item and unrelated
        // recommendations. Only the exact requested identity is accepted.
        guard result.code == 200, result.data.id == id || result.data.idV2 == id,
              let icon = result.data.icon, icon.utf8.count <= 8192,
              let image = URL(string: icon), image.scheme == "https",
              image.host == "region-cdn-fds.xiaomiwear.com",
              image.user == nil, image.password == nil else { return nil }
        return image
    }

    deinit { task?.cancel() }
}
