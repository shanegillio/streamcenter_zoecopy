import Foundation

struct SourceCredentials: Codable {
  var username: String
  var password: String
}

enum CredentialStore {
  static func credentials(for domain: String) -> SourceCredentials? {
    guard let data = UserDefaults.standard.data(forKey: storeKey(domain)),
          let creds = try? JSONDecoder().decode(SourceCredentials.self, from: data) else { return nil }
    return creds
  }

  static func save(_ credentials: SourceCredentials, for domain: String) {
    guard let data = try? JSONEncoder().encode(credentials) else { return }
    UserDefaults.standard.set(data, forKey: storeKey(domain))
  }

  static func remove(for domain: String) {
    UserDefaults.standard.removeObject(forKey: storeKey(domain))
  }

  private static func storeKey(_ domain: String) -> String { "source_credentials_\(domain)" }
}
