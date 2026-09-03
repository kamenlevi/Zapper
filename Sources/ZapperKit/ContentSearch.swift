import Foundation

/// A title found across streaming catalogues, with one entry per service
/// that carries it.
public struct ContentHit: Identifiable, Hashable, Sendable {
    public struct Offer: Hashable, Sendable {
        /// JustWatch's display name for the service ("Netflix", "HBO Max").
        public let providerName: String
        /// The web deep link — carries the title id the TV app needs.
        public let url: String

        public init(providerName: String, url: String) {
            self.providerName = providerName; self.url = url
        }
    }

    public let id: String
    public let title: String
    public let year: Int?
    public let isShow: Bool
    public let offers: [Offer]
    public let posterURL: URL?

    public init(id: String, title: String, year: Int?, isShow: Bool,
                offers: [Offer], posterURL: URL? = nil) {
        self.id = id; self.title = title; self.year = year
        self.isShow = isShow; self.offers = offers; self.posterURL = posterURL
    }
}

/// One episode of a season: its name plus where it can stream.
public struct EpisodeInfo: Sendable, Hashable, Identifiable {
    public let number: Int
    public let title: String
    public let offers: [ContentHit.Offer]
    public var id: Int { number }

    public init(number: Int, title: String, offers: [ContentHit.Offer]) {
        self.number = number; self.title = title; self.offers = offers
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
          content(country: $country, language: "en") { title originalReleaseYear posterUrl }
          ... on MovieOrShow {
            offers(country: $country, platform: WEB) {
              monetizationType standardWebURL package { clearName }
            }
          }
        } }
      }
    }
    """

    private static func request(_ query: String, variables: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: endpoint, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": query, "variables": variables,
        ])
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any]
        else { return [:] }
        return payload
    }

    /// Subscription streams only, one offer per service — the raw list
    /// repeats each service once per resolution tier.
    private static func parseOffers(_ raw: [[String: Any]]?) -> [ContentHit.Offer] {
        var seen = Set<String>()
        return (raw ?? []).compactMap { offer in
            guard (offer["monetizationType"] as? String) == "FLATRATE",
                  let url = offer["standardWebURL"] as? String,
                  let package = offer["package"] as? [String: Any],
                  let name = package["clearName"] as? String,
                  seen.insert(name).inserted
            else { return nil }
            return ContentHit.Offer(providerName: name, url: url)
        }
    }

    /// "/poster/300603462/{profile}/name.{format}" → a fetchable image URL.
    private static func posterURL(_ template: String?) -> URL? {
        guard let template else { return nil }
        let path = template
            .replacingOccurrences(of: "{profile}", with: "s332")
            .replacingOccurrences(of: "{format}", with: "webp")
        return URL(string: "https://images.justwatch.com" + path)
    }

    public static func search(_ text: String, country: String) async throws -> [ContentHit] {
        let payload = try await request(query, variables: ["country": country, "q": text])
        guard let titles = payload["popularTitles"] as? [String: Any],
              let edges = titles["edges"] as? [[String: Any]]
        else { return [] }

        return edges.compactMap { edge in
            guard let node = edge["node"] as? [String: Any],
                  let id = node["id"] as? String,
                  let content = node["content"] as? [String: Any],
                  let title = content["title"] as? String
            else { return nil }

            let offers = parseOffers(node["offers"] as? [[String: Any]])
            guard !offers.isEmpty else { return nil }

            return ContentHit(
                id: id,
                title: title,
                year: content["originalReleaseYear"] as? Int,
                isShow: (node["objectType"] as? String) == "SHOW",
                offers: offers,
                posterURL: posterURL(content["posterUrl"] as? String)
            )
        }
    }

    /// Offers for one specific episode. Services that deep-link per episode
    /// (HBO Max) return an episode URL; ones that don't (Netflix) return the
    /// same show-level URL as the show itself.
    public static func episodeOffers(
        showID: String, season: Int, episode: Int, country: String
    ) async throws -> [ContentHit.Offer] {
        try await seasonEpisodes(showID: showID, season: season, country: country)
            .first { $0.number == episode }?.offers ?? []
    }

    /// Every episode of one season — names and per-service links.
    public static func seasonEpisodes(
        showID: String, season: Int, country: String
    ) async throws -> [EpisodeInfo] {
        let seasonsQuery = """
        query($id: ID!, $country: Country!) {
          node(id: $id) { ... on Show {
            seasons { id content(country: $country, language: "en") { seasonNumber } }
          } }
        }
        """
        let seasonsPayload = try await request(seasonsQuery, variables: ["id": showID, "country": country])
        guard let node = seasonsPayload["node"] as? [String: Any],
              let seasons = node["seasons"] as? [[String: Any]],
              let match = seasons.first(where: {
                  (($0["content"] as? [String: Any])?["seasonNumber"] as? Int) == season
              }),
              let seasonID = match["id"] as? String
        else { return [] }

        let episodesQuery = """
        query($id: ID!, $country: Country!) {
          node(id: $id) { ... on Season {
            episodes {
              content(country: $country, language: "en") { episodeNumber title }
              offers(country: $country, platform: WEB) {
                monetizationType standardWebURL package { clearName }
              }
            }
          } }
        }
        """
        let episodesPayload = try await request(episodesQuery, variables: ["id": seasonID, "country": country])
        guard let seasonNode = episodesPayload["node"] as? [String: Any],
              let episodes = seasonNode["episodes"] as? [[String: Any]]
        else { return [] }

        return episodes.compactMap { entry in
            guard let content = entry["content"] as? [String: Any],
                  let number = content["episodeNumber"] as? Int else { return nil }
            return EpisodeInfo(
                number: number,
                title: (content["title"] as? String) ?? "Episode \(number)",
                offers: parseOffers(entry["offers"] as? [[String: Any]])
            )
        }
    }
}
