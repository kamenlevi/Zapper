import Foundation

/// A title found across streaming catalogues, with one entry per service
/// that carries it.
public struct ContentHit: Identifiable, Hashable, Sendable {
    public struct Offer: Hashable, Sendable {
        /// JustWatch's display name for the service ("Netflix", "HBO Max").
        public let providerName: String
        /// The web deep link — carries the title id the TV app needs.
        public let url: String
    }

    public let id: String
    public let title: String
    public let year: Int?
    public let isShow: Bool
    public let offers: [Offer]

    public init(id: String, title: String, year: Int?, isShow: Bool, offers: [Offer]) {
        self.id = id; self.title = title; self.year = year
        self.isShow = isShow; self.offers = offers
    }
}

/// Streaming availability search backed by JustWatch's public GraphQL
/// endpoint — the same data their site serves, no key required. Unofficial,
/// so failures degrade to "no content suggestions", never to an error.
public enum ContentSearch {

    private static let endpoint = URL(string: "https://apis.justwatch.com/graphql")!

    private static let query = """
    query($country: Country!, $q: String!) {
      popularTitles(country: $country, first: 8, filter: {searchQuery: $q}) {
        edges { node {
          id objectType
          content(country: $country, language: "en") { title originalReleaseYear }
          ... on MovieOrShow {
            offers(country: $country, platform: WEB) {
              monetizationType standardWebURL package { clearName }
            }
          }
        } }
      }
    }
    """

    public static func search(_ text: String, country: String) async throws -> [ContentHit] {
        var request = URLRequest(url: endpoint, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": query,
            "variables": ["country": country, "q": text],
        ])

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any],
              let titles = payload["popularTitles"] as? [String: Any],
              let edges = titles["edges"] as? [[String: Any]]
        else { return [] }

        return edges.compactMap { edge in
            guard let node = edge["node"] as? [String: Any],
                  let id = node["id"] as? String,
                  let content = node["content"] as? [String: Any],
                  let title = content["title"] as? String
            else { return nil }

            // Subscription streams only, one offer per service — the raw list
            // repeats each service once per resolution tier.
            var seen = Set<String>()
            let offers: [ContentHit.Offer] = ((node["offers"] as? [[String: Any]]) ?? []).compactMap { offer in
                guard (offer["monetizationType"] as? String) == "FLATRATE",
                      let url = offer["standardWebURL"] as? String,
                      let package = offer["package"] as? [String: Any],
                      let name = package["clearName"] as? String,
                      seen.insert(name).inserted
                else { return nil }
                return ContentHit.Offer(providerName: name, url: url)
            }
            guard !offers.isEmpty else { return nil }

            return ContentHit(
                id: id,
                title: title,
                year: content["originalReleaseYear"] as? Int,
                isShow: (node["objectType"] as? String) == "SHOW",
                offers: offers
            )
        }
    }
}
