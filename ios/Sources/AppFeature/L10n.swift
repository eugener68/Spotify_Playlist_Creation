import Foundation

enum L10n {
    enum Flow {
        static var signIn: String { localized("flow.sign_in", "Flow step: sign in") }
        static var settings: String { localized("flow.settings", "Flow step: settings") }
        static var build: String { localized("flow.build", "Flow step: build") }
        static var results: String { localized("flow.results", "Flow step: results") }
    }

    enum Builder {
        static var defaultPlaylistName: String { localized("builder.default_playlist_name", "Default playlist field value") }
        static var spotifyAccountTitle: String { localized("builder.spotify_account_title", "Header for Spotify account section") }
        static var latestBuildTitle: String { localized("builder.latest_build_title", "Latest build header") }
        static var uploadOrderTitle: String { localized("builder.upload_order_title", "Upload order header") }
        static var emptyResultsTitle: String { localized("builder.empty_results_title", "Empty state title") }
        static var emptyResultsDescription: String { localized("builder.empty_results_description", "Empty state description") }
        static var buildingButton: String { localized("builder.building_button", "Label shown while build is running") }
        static var runButton: String { localized("builder.run_button", "Label to trigger playlist build") }
        static var playlistNameLabel: String { localized("builder.playlist_name_label", "Playlist name label") }
        static var playlistNamePlaceholder: String { localized("builder.playlist_name_placeholder", "Playlist name placeholder") }
        static var dateStampToggle: String { localized("builder.date_stamp_toggle", "Toggle label for date stamp") }
        static var dryRunToggle: String { localized("builder.dry_run_toggle", "Toggle label for dry run") }
        static var manualArtistListTitle: String { localized("builder.manual_artist_list_title", "Manual artists section title") }
        static var manualArtistHint: String { localized("builder.manual_artist_hint", "Manual artists helper text") }
        static var importArtistList: String { localized("builder.import_csv_button", "Import artist list button") }
        static var pasteArtistList: String { localized("builder.paste_button", "Paste artist list button") }
        static var settingsTitle: String { localized("builder.settings_title", "Settings card title") }
        static var limitPerArtistTitle: String { localized("builder.limit_per_artist_title", "Limit per artist title") }
        static var limitPerArtistSubtitle: String { localized("builder.limit_per_artist_subtitle", "Limit per artist subtitle") }
        static var maxTracksTitle: String { localized("builder.max_tracks_title", "Max tracks title") }
        static var maxTracksSubtitle: String { localized("builder.max_tracks_subtitle", "Max tracks subtitle") }
        static var shuffleTitle: String { localized("builder.shuffle_title", "Shuffle toggle title") }
        static var shuffleSubtitle: String { localized("builder.shuffle_subtitle", "Shuffle toggle subtitle") }
        static var preferOriginalTitle: String { localized("builder.prefer_original_title", "Prefer original toggle title") }
        static var preferOriginalSubtitle: String { localized("builder.prefer_original_subtitle", "Prefer original toggle subtitle") }
    }

    enum Settings {
        static var languageTitle: String { localized("settings.language_title", "Interface language setting title") }
        static var languageSystem: String { localized("settings.language_system", "Option to match device language") }
        static var languageEnglish: String { localized("settings.language_english", "Option to force English UI") }
        static var languageRussian: String { localized("settings.language_russian", "Option to force Russian UI") }
    }

    enum Results {
        static var updatedExisting: String { localized("results.updated_existing", "Label shown when playlist updated") }
        static var createdNew: String { localized("results.created_new", "Label shown when playlist created") }
        static func preparedAndUploaded(prepared: Int, uploaded: Int) -> String {
            String.localizedStringWithFormat(
                localized("results.prepared_uploaded", "Format describing prepared and uploaded counts"),
                prepared,
                uploaded
            )
        }
    }

    enum Auth {
        static var statusChecking: String { localized("auth.status_checking", "Auth status - checking") }
        static var statusSigningIn: String { localized("auth.status_signing_in", "Auth status - signing in") }
        static var cancel: String { localized("auth.cancel", "Cancel auth button") }
        static var signedIn: String { localized("auth.signed_in", "Signed in label") }
        static var openDashboard: String { localized("auth.open_dashboard", "Open dashboard button") }
        static var signOut: String { localized("auth.sign_out", "Sign out button") }
        static var signIn: String { localized("auth.sign_in", "Sign in button") }
        static var unavailable: String { localized("auth.unavailable", "Auth unavailable copy") }
    }

    enum ArtistInput {
        static var clipboardEmpty: String { localized("artist_input.clipboard_empty", "Clipboard empty message") }
        static func clipboardAdded(_ count: Int) -> String {
            String.localizedStringWithFormat(
                localized("artist_input.clipboard_added", "Clipboard import success message"),
                count
            )
        }
        static var clipboardNone: String { localized("artist_input.clipboard_none", "Clipboard no-op message") }
        static func importPermissionDenied(_ fileName: String) -> String {
            String.localizedStringWithFormat(
                localized("artist_input.import_permission_denied", "Import permission error"),
                fileName
            )
        }
        static func importReadFailed(_ fileName: String) -> String {
            String.localizedStringWithFormat(
                localized("artist_input.import_could_not_read", "Import read error"),
                fileName
            )
        }
        static func importAddedFromFile(_ count: Int, fileName: String) -> String {
            String.localizedStringWithFormat(
                localized("artist_input.import_added_from_file", "Import success from file"),
                count,
                fileName
            )
        }
        static func importNoneInFile(_ fileName: String) -> String {
            String.localizedStringWithFormat(
                localized("artist_input.import_none_in_file", "Import no artists found"),
                fileName
            )
        }
        static func importFailed(_ message: String) -> String {
            String.localizedStringWithFormat(
                localized("artist_input.import_failed", "Import generic failure"),
                message
            )
        }
    }

    private static func localized(_ key: String, _ comment: String) -> String {
        LocalizationController.shared.localizedString(forKey: key, comment: comment)
    }
}
