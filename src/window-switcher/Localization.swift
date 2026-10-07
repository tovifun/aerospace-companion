import Foundation

func localized(_ english: String, _ chinese: String) -> String {
    let preferredLanguage = Locale.preferredLanguages.first ?? "en"
    return preferredLanguage.hasPrefix("zh") ? chinese : english
}
