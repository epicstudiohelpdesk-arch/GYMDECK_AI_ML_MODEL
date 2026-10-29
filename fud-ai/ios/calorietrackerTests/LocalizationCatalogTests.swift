import Foundation
import Testing
@testable import calorietracker

/// Checks that notification, error, extension and Siri text ships in every app
/// language, and that counted strings follow each language's plural rules.
@MainActor
struct LocalizationCatalogTests {
    static let appLanguages = [
        "ar", "az", "cs", "de", "es", "fr", "hi", "it", "ja", "ko",
        "nl", "pl", "pt-BR", "ro", "ru", "tr", "uk", "zh-Hans",
    ]

    /// Every notification title and body NotificationManager can schedule.
    static let notificationKeys = [
        "Breakfast Time", "Don't forget to log your breakfast!",
        "Lunch Time", "Snap a photo to keep tracking!",
        "Dinner Time", "Log your dinner to stay on track!",
        "Time to Hydrate", "Have some water and log it in Fud AI.",
        "Fasting Goal Reached", "You reached your %@ fasting goal. End the fast when you're ready.",
        "Don't Break Your %lld-Day Streak!", "Log something before the day ends.",
        "Daily Summary", "You ate %lld of %lld kcal today. %lld remaining!",
        "You ate %lld of %lld kJ today. %lld remaining!",
        "Time to Weigh In", "Log today's weight to keep your progress chart accurate.",
        "Body Fat Check-In", "Log today's body fat % to track your composition trend.",
        "Update Available", "Fud AI %@ is ready. Tap to update.",
        "Fud AI is live on Product Hunt 🚀", "We just launched! Tap to vote and help more people find Fud AI.",
        "Rest Complete", "Time for your next set of %@.",
    ]

    /// Every LocalizedError message localized for #507, with its format arguments.
    static let errorKeys = [
        // ChatService.ChatError, SpeechService.SpeechError
        "No API key configured. Add your key in Settings → AI Provider.",
        "Network error: %@",
        "API error: %@",
        "Could not understand the AI response. Please try again.",
        "No API key configured for this speech provider. Add one in Settings → Speech-to-Text.",
        "Could not read the recorded audio file.",
        "Speech API error: %@",
        "Unexpected response from the speech provider.",
        // CloudBackupError
        "This is not a Fud AI backup.",
        "This backup needs a newer Fud AI.",
        "Sign into iCloud in iOS Settings first.",
        "No iCloud backup found.",
        // DiaryImportError
        "This file is too large to import.",
        "This is not a valid Fud AI food diary JSON file.",
        "This food diary format is not supported.",
        "The selected diary does not contain any food or water entries.",
        "The diary contains an invalid date or time: %@.",
        "The diary contains an unknown meal type: %@.",
        "The diary contains an invalid water entry.",
        "The diary contains an invalid food entry: %@.",
        // HostedAIServiceError
        "Invalid hosted AI URL.",
        "Hosted AI could not identify your subscription. Try Restore Purchases.",
        "Could not understand the hosted AI response.",
        "Hosted AI is temporarily unavailable. Please try again shortly.",
        // OnDeviceAIError
        "Apple Intelligence is unavailable: %@",
        // SiriLoggingService
        "Please say a weight, such as 75 kilograms or 165 pounds.",
        "That does not look like a valid weight.",
        "End or cancel your active fast before logging food.",
        // LiveSocketError
        "The provider refused the connection (HTTP %lld).",
        "The connection closed (%@).",
        "The provider sent a message the app can't read.",
    ]

    /// Every Weekly Recap string on Progress (#431).
    static let weeklyRecapKeys = [
        "Weekly Recap", "Previous week", "Next week",
        "Days logged", "Calories on target", "Protein goal reached", "Avg calories", "Workouts",
        "Active burn", "Weight change", "Target %@", "Changes are compared with the previous week.",
        "Nothing logged this week", "Logged every day", "Average calories on target",
        "Best streak: %lld days in a row", "+%lld workouts vs previous week",
        "+%lld days on calorie target vs previous week", "+%lld protein goal days vs previous week",
        "+%lld days logged vs previous week",
    ]

    /// Every rest timer and routine string in the workout log and settings (#433).
    static let restTimerAndRoutineKeys = [
        "Rest Timer", "Off",
        "Counts down after you log a set today. With notifications on, Fud AI alerts you when rest ends in the background.",
        "Rest", "+15s", "Add 15 seconds", "Skip", "Skip rest", "Start rest after set %lld",
        "Start from routine", "Save as routine", "Save Routine", "Routine name",
        "Saves this day's exercises with their planned sets, reps and weights.",
        "Routines", "No Routines Yet", "Log a workout, then choose Save as routine from the + menu.",
        "Adds the routine's exercises to the selected day. Sets you already logged stay as they are.",
        "Rename", "Rename Routine", "Delete Routine?", "Workouts you already logged are kept.",
    ]

    // MARK: - Compiled bundles

    @Test func restTimerAndRoutinesAreTranslatedInEveryLanguage() throws {
        let missing = "\u{0}missing"
        for language in Self.appLanguages {
            let bundle = try Self.languageBundle(language, in: .main)
            for key in Self.restTimerAndRoutineKeys + ["Rest Complete", "Time for your next set of %@."] {
                let translation = bundle.localizedString(forKey: key, value: missing, table: nil)
                #expect(translation != missing, "\(language) is missing \(key)")
                guard translation != missing else { continue }
                #expect(
                    Self.formatArguments(translation) == Self.formatArguments(key),
                    "\(language) \(translation) does not match the arguments of \(key)"
                )
            }
            let body = bundle.localizedString(forKey: "Time for your next set of %@.", value: nil, table: nil)
            #expect(String(format: body, "Bench Press").contains("Bench Press"), "\(language): \(body)")
        }
    }

    @Test func weeklyRecapIsTranslatedInEveryLanguage() throws {
        for language in Self.appLanguages {
            let bundle = try Self.languageBundle(language, in: .main)
            for key in Self.weeklyRecapKeys {
                #expect(Self.hasTranslation(key, in: bundle), "\(language) is missing \(key)")
            }
            let target = bundle.localizedString(forKey: "Target %@", value: nil, table: nil)
            #expect(String(format: target, "2,000").contains("2,000"), "\(language): \(target)")
        }
    }

    @Test func weeklyRecapHighlightsFollowPluralRules() throws {
        let workouts = "+%lld workouts vs previous week"
        #expect(try Self.format(workouts, "en", 1) == "+1 workout vs previous week")
        #expect(try Self.format(workouts, "ru", 1) == "+1 тренировка к предыдущей неделе")
        #expect(try Self.format(workouts, "ru", 3) == "+3 тренировки к предыдущей неделе")
        #expect(try Self.format(workouts, "ru", 5) == "+5 тренировок к предыдущей неделе")
        let streak = "Best streak: %lld days in a row"
        #expect(try Self.format(streak, "pl", 3) == "Najlepsza seria: 3 dni z rzędu")
        #expect(try Self.format(streak, "cs", 5) == "Nejlepší série: 5 dní v řadě")
        #expect(try Self.format(streak, "ro", 21) == "Cea mai bună serie: 21 de zile la rând")
        #expect(try Self.format("+%lld days logged vs previous week", "uk", 2) == "+2 дні із записами до попереднього тижня")
    }

    @Test func notificationTextIsTranslatedInEveryLanguage() throws {
        for language in Self.appLanguages {
            let bundle = try Self.languageBundle(language, in: .main)
            for key in Self.notificationKeys {
                #expect(Self.hasTranslation(key, in: bundle), "\(language) is missing \(key)")
            }
        }
    }

    @Test func streakReminderFollowsPluralRules() throws {
        let key = "Don't Break Your %lld-Day Streak!"
        #expect(try Self.format(key, "ru", 1) == "Не прерывайте серию: 1 день подряд!")
        #expect(try Self.format(key, "ru", 3) == "Не прерывайте серию: 3 дня подряд!")
        #expect(try Self.format(key, "ru", 5) == "Не прерывайте серию: 5 дней подряд!")
        #expect(try Self.format(key, "pl", 22) == "Nie przerywaj serii – 22 dni z rzędu!")
        #expect(try Self.format(key, "es", 1) == "¡No pierdas tu racha de 1 día!")
        #expect(try Self.format(key, "es", 7) == "¡No pierdas tu racha de 7 días!")
    }

    @Test func dailySummaryAgreesWithTheRemainingCount() throws {
        let key = "You ate %lld of %lld kcal today. %lld remaining!"
        #expect(try Self.format(key, "ru", 900, 1_000, 21).hasSuffix("Осталась 21 ккал!"))
        #expect(try Self.format(key, "ru", 900, 1_000, 100).hasSuffix("Осталось 100 ккал!"))
        #expect(try Self.format(key, "cs", 900, 1_000, 3).hasSuffix("Zbývají 3 kcal!"))
        #expect(try Self.format(key, "es", 900, 1_000, 1).hasSuffix("¡Te queda 1!"))
        #expect(try Self.format(key, "es", 900, 1_000, 100).hasSuffix("¡Te quedan 100!"))
        #expect(try Self.format(key, "de", 900, 1_000, 100) == "Du hast heute 900 von 1.000 kcal gegessen. Noch 100 übrig!")
    }

    /// Every label and error on a Coach exercise proposal card, with its format arguments.
    static let coachProposalKeys = [
        "New custom exercise", "Add to workout", "Add", "coach.proposal.dismiss", "Added", "Dismissed",
        "Category: %@", "Equipment: %@", "Primary muscles: %@", "Secondary muscles: %@",
        "Date: %@", "Sets: %lld", "Reps: %lld", "Duration: %lld min",
        "Add %@ to your exercise library", "Add %@ to your workout diary", "Dismiss the suggestion for %@",
        "This exercise is no longer in your library.", "An exercise with this name is already in your library.",
        "Couldn't save this change. Try again.",
    ]

    @Test func coachProposalCardIsTranslatedInEveryLanguage() throws {
        let missing = "\u{0}missing"
        for language in Self.appLanguages {
            let bundle = try Self.languageBundle(language, in: .main)
            for key in Self.coachProposalKeys {
                let translation = bundle.localizedString(forKey: key, value: missing, table: nil)
                #expect(translation != missing, "\(language) is missing \(key)")
                guard translation != missing else { continue }
                #expect(
                    Self.formatArguments(translation) == Self.formatArguments(key),
                    "\(language) \(translation) does not match the arguments of \(key)"
                )
            }
        }
    }

    /// Every string on onboarding's welcome-back screen and the link to it.
    static let returningUserKeys = [
        "Used Fud AI before?", "Welcome back", "Pick what to bring back. You can choose both.",
        "Restore from iCloud", "Diary, photos, workouts, and settings from your last backup.",
        "Import from Apple Health", "Meals, weight, body fat, and workout calories Fud AI saved to Health.",
        "Start fresh", "Checking iCloud…", "Restoring…", "Importing from Apple Health…",
        "Backup from %@", "Backup found", "Restored your backup from %@.", "Backup restored.",
        "iCloud restores first, then Apple Health adds only what's missing. Nothing gets overwritten.",
        "Bringing your data back…", "You're all set. Everything is back where you left it.",
        "A short setup and you're in.", "Nothing came back this time. Try again or start fresh.",
        "Open Fud AI", "Try again", "Couldn't read everything from Apple Health. Try again.",
        "This backup doesn't include a finished setup, so let's finish it now.",
        "No iCloud backup found for this Apple ID.", "Couldn't reach iCloud. Check your connection and try again.",
        "Couldn't connect to Apple Health. You can try again later in Settings.",
        "Imported %@.", "Nothing to import from Apple Health yet.", "Continue setup",
    ]

    /// The counted parts of the Apple Health import summary.
    static let returningUserCountKeys = [
        "%lld meals", "%lld weigh-ins", "%lld body-fat readings", "calories for %lld workouts",
    ]

    @Test func returningUserScreenIsTranslatedInEveryLanguage() throws {
        let missing = "\u{0}missing"
        for language in Self.appLanguages {
            let bundle = try Self.languageBundle(language, in: .main)
            for key in Self.returningUserKeys {
                let translation = bundle.localizedString(forKey: key, value: missing, table: nil)
                #expect(translation != missing, "\(language) is missing \(key)")
                guard translation != missing else { continue }
                #expect(
                    Self.formatArguments(translation) == Self.formatArguments(key),
                    "\(language) \(translation) does not match the arguments of \(key)"
                )
                if key.contains("Fud AI") {
                    #expect(translation.contains("Fud AI"), "\(language) translated the app name in \(key)")
                }
            }
            for key in Self.returningUserCountKeys {
                #expect(Self.hasTranslation(key, in: bundle), "\(language) is missing \(key)")
            }
            for key in ["Backup from %@", "Restored your backup from %@."] {
                let date = bundle.localizedString(forKey: key, value: nil, table: nil)
                #expect(String(format: date, "Oct 19, 2026").contains("Oct 19, 2026"), "\(language): \(date)")
            }
        }
    }

    @Test func importSummaryCountsFollowPluralRules() throws {
        #expect(try Self.format("%lld meals", "en", 1) == "1 meal")
        #expect(try Self.format("%lld meals", "en", 120) == "120 meals")
        #expect(try Self.format("%lld meals", "ru", 1) == "1 приём пищи")
        #expect(try Self.format("%lld meals", "ru", 3) == "3 приёма пищи")
        #expect(try Self.format("%lld meals", "ru", 120) == "120 приёмов пищи")
        #expect(try Self.format("%lld weigh-ins", "en", 1) == "1 weigh-in")
        #expect(try Self.format("%lld weigh-ins", "pl", 2) == "2 pomiary wagi")
        #expect(try Self.format("%lld weigh-ins", "pl", 45) == "45 pomiarów wagi")
        #expect(try Self.format("%lld body-fat readings", "uk", 21) == "21 вимір жиру")
        #expect(try Self.format("%lld body-fat readings", "uk", 12) == "12 вимірів жиру")
        #expect(try Self.format("calories for %lld workouts", "en", 1) == "calories for 1 workout")
        #expect(try Self.format("calories for %lld workouts", "cs", 3) == "kalorie za 3 tréninky")
        #expect(try Self.format("calories for %lld workouts", "de", 1) == "Kalorien von 1 Training")
    }

    @Test func kilojouleDailySummaryAgreesWithTheRemainingCount() throws {
        let key = "You ate %lld of %lld kJ today. %lld remaining!"
        // кДж (kilojoule) is masculine where ккал is feminine.
        #expect(try Self.format(key, "ru", 3_766, 8_368, 21).hasSuffix("Остался 21 кДж!"))
        #expect(try Self.format(key, "ru", 3_766, 8_368, 100).hasSuffix("Осталось 100 кДж!"))
        #expect(try Self.format(key, "pl", 3_766, 8_368, 3).hasSuffix("Zostały 3 kJ!"))
        #expect(try Self.format(key, "es", 3_766, 8_368, 1).hasSuffix("¡Te queda 1!"))
        #expect(try Self.format(key, "de", 3_766, 8_368, 100) == "Du hast heute 3.766 von 8.368 kJ gegessen. Noch 100 übrig!")
    }

    @Test func energyUnitSettingIsTranslatedInEveryLanguage() throws {
        let keys = [
            "Energy Unit", "Kilocalories (kcal)", "Kilojoules (kJ)", "Kilojoules", "kcal", "kJ", "%@ kJ",
            "%@ left", "%@ over", "Avg: %@", "Deficit: %@/day", "Surplus: %@/day", "Estimated burn: %@",
        ]
        for language in Self.appLanguages {
            let bundle = try Self.languageBundle(language, in: .main)
            for key in keys {
                #expect(Self.hasTranslation(key, in: bundle), "\(language) is missing \(key)")
            }
        }
        let russian = try Self.languageBundle("ru", in: .main)
        #expect(russian.localizedString(forKey: "%@ kJ", value: nil, table: nil) == "%@ кДж")
    }

    @Test func shareExtensionAlertIsTranslatedInEveryLanguage() throws {
        let share = try Self.embeddedExtension("calorietrackerShare")
        for language in Self.appLanguages {
            let bundle = try Self.languageBundle(language, in: share)
            for key in ["Error", "Unable to process the shared image.", "OK"] {
                #expect(Self.hasTranslation(key, in: bundle), "\(language) is missing \(key)")
            }
        }
    }

    // MARK: - Ukrainian

    @Test func ukrainianShowsUkrainianInsteadOfRussian() throws {
        let bundle = try Self.languageBundle("uk", in: .main)
        let expected = [
            "Error": "Помилка",
            "Skip": "Пропустити",
            "Let's get started!": "Почнімо!",
            "Days on Target": "Днів у цілі",
            "%@ goal": "Ціль %@",
            "Add %lld to Log · %@": "Додати %lld до журналу · %@",
            "AI analysis": "ШІ-аналіз",
        ]
        for (key, value) in expected {
            #expect(bundle.localizedString(forKey: key, value: nil, table: nil) == value, "uk \(key)")
        }
        #expect(bundle.localizedString(forKey: "Error", value: nil, table: "WeeklyChallenge") == "Помилка")
        #expect(bundle.localizedString(forKey: "Edit Public Profile", value: nil, table: "WeeklyChallenge") == "Редагувати публічний профіль")
    }

    @Test func ukrainianCountsFollowPluralRules() throws {
        // Streak tiles on Progress.
        #expect(try Self.format("%lld days", "uk", 1) == "1 день")
        #expect(try Self.format("%lld days", "uk", 3) == "3 дні")
        #expect(try Self.format("%lld days", "uk", 5) == "5 днів")
        #expect(try Self.format("%lld days", "uk", 22) == "22 дні")
        // These had only "one" and "other", so 2–4 read "2 кроків".
        #expect(try Self.format("%lld steps", "uk", 3) == "3 кроки")
        #expect(try Self.format("%lld steps", "uk", 7) == "7 кроків")
        let entries = "%lld entry · tap to view or delete"
        #expect(try Self.format(entries, "uk", 2).hasPrefix("2 записи ·"))
        #expect(try Self.format(entries, "uk", 11).hasPrefix("11 записів ·"))
    }

    // MARK: - Counted labels

    @Test func workoutCountsFollowPluralRules() throws {
        // Calendar days, streak tiles and exercise pickers show a single item too (#507).
        #expect(try Self.format("%lld workouts", "de", 1) == "1 Training")
        #expect(try Self.format("%lld workouts", "de", 3) == "3 Trainings")
        #expect(try Self.format("%lld workouts", "es", 1) == "1 entrenamiento")
        #expect(try Self.format("%lld workouts", "fr", 1) == "1 entraînement")
        #expect(try Self.format("%lld workouts", "nl", 2) == "2 trainingen")
        #expect(try Self.format("%lld days", "de", 1) == "1 Tag")
        #expect(try Self.format("%lld days", "pt-BR", 1) == "1 dia")
        #expect(try Self.format("%lld days", "ro", 21) == "21 de zile")
        #expect(try Self.format("%lld exercises", "it", 1) == "1 esercizio")
        #expect(try Self.format("%lld exercises", "it", 9) == "9 esercizi")
        // The count is the second argument here, after the muscle group name.
        let german = try Self.languageBundle("de", in: .main)
        let format = german.localizedString(forKey: "%@, %lld exercises", value: nil, table: nil)
        let locale = Locale(identifier: "de")
        #expect(String(format: format, locale: locale, arguments: ["Brust", Int64(1)]) == "Brust, 1 Übung")
        #expect(String(format: format, locale: locale, arguments: ["Brust", Int64(12)]) == "Brust, 12 Übungen")
    }

    @Test func allFilterLabelHasNoDanglingArticle() throws {
        // "Todos los 12" read as an unfinished phrase on the workout filter pills.
        #expect(try Self.format("All %lld", "es", 12) == "Todos (12)")
        #expect(try Self.format("All %lld", "fr", 12) == "Tous (12)")
        #expect(try Self.format("All %lld", "pt-BR", 12) == "Todos (12)")
        #expect(try Self.format("All %lld", "ro", 12) == "Toate (12)")
    }

    // MARK: - Error descriptions

    @Test func errorTextIsTranslatedInEveryLanguage() throws {
        let missing = "\u{0}missing"
        for language in Self.appLanguages {
            let bundle = try Self.languageBundle(language, in: .main)
            for key in Self.errorKeys {
                let translation = bundle.localizedString(forKey: key, value: missing, table: nil)
                #expect(translation != missing, "\(language) is missing \(key)")
                guard translation != missing else { continue }
                // A translation that drops or retypes an argument would lose the detail
                // (provider message, file text, status code) or crash String(format:).
                #expect(
                    Self.formatArguments(translation) == Self.formatArguments(key),
                    "\(language) \(translation) does not match the arguments of \(key)"
                )
            }
        }
    }

    @Test func translatedErrorDescriptionsKeepTheirDetails() throws {
        for language in Self.appLanguages {
            let bundle = try Self.languageBundle(language, in: .main)
            let date = bundle.localizedString(forKey: "The diary contains an invalid date or time: %@.", value: nil, table: nil)
            #expect(String(format: date, "2026-13-40").contains("2026-13-40"), "\(language): \(date)")
            let api = bundle.localizedString(forKey: "API error: %@", value: nil, table: nil)
            #expect(String(format: api, "quota hit").contains("quota hit"), "\(language): \(api)")
            let refused = bundle.localizedString(forKey: "The provider refused the connection (HTTP %lld).", value: nil, table: nil)
            #expect(String(format: refused, Int64(402)).contains("402"), "\(language): \(refused)")
        }
    }

    @Test func errorDescriptionsKeepTheirDetails() {
        #expect(DiaryImportError.invalidDate("2026-13-40").errorDescription?.contains("2026-13-40") == true)
        #expect(DiaryImportError.invalidMeal("brunch").errorDescription?.contains("brunch") == true)
        #expect(DiaryImportError.invalidEntry("Rice").errorDescription?.contains("Rice") == true)
        #expect(ChatService.ChatError.apiError("quota hit").errorDescription?.contains("quota hit") == true)
        #expect(SpeechService.SpeechError.apiError("bad audio").errorDescription?.contains("bad audio") == true)
        #expect(HostedAIServiceError.serverError("Plan expired").errorDescription == "Plan expired")
        #expect(LiveSocketError.closed(code: 1000, reason: "bye").errorDescription == "bye")
        // A close code is an identifier: it must not pick up digit grouping like "4,402".
        #expect(LiveSocketError.closed(code: 4402, reason: nil).errorDescription?.contains("4402") == true)
        #expect(LiveSocketError.refused(statusCode: 402).errorDescription?.contains("402") == true)
    }

    // MARK: - Source catalogs

    @Test(.enabled(if: LocalizationCatalogTests.sourceCatalogsAvailable))
    func extensionCatalogsCoverEveryAppLanguage() throws {
        let catalogs = [
            "FudAIWidgets/Localizable.xcstrings",
            "FudAIWatchApp/Localizable.xcstrings",
            "FudAIWatchWidgets/Localizable.xcstrings",
            "calorietrackerShare/Localizable.xcstrings",
        ]
        for catalog in catalogs {
            let strings = try Self.sourceStrings(catalog)
            #expect(!strings.isEmpty, "\(catalog) has no strings")
            for (key, entry) in strings {
                let localizations = entry["localizations"] as? [String: Any] ?? [:]
                for language in Self.appLanguages {
                    let forms = Self.translatedForms(localizations[language])
                    #expect(!forms.isEmpty, "\(catalog): \(language) is missing \(key)")
                    for form in forms {
                        #expect(
                            Self.formatArguments(form) == Self.formatArguments(key),
                            "\(catalog): \(language) \(form) does not match the arguments of \(key)"
                        )
                    }
                }
            }
        }
    }

    @Test(.enabled(if: LocalizationCatalogTests.sourceCatalogsAvailable))
    func appShortcutPhrasesNameTheAppInEveryLanguage() throws {
        let strings = try Self.sourceStrings("calorietracker/AppShortcuts.xcstrings")
        #expect(strings.count >= 7)
        for language in Self.appLanguages + ["en"] {
            var seen = Set<String>()
            for (key, entry) in strings {
                let localizations = entry["localizations"] as? [String: Any] ?? [:]
                let set = (localizations[language] as? [String: Any])?["stringSet"] as? [String: Any]
                let phrases = set?["values"] as? [String] ?? []
                #expect(!phrases.isEmpty, "\(language) has no phrases for \(key)")
                for phrase in phrases {
                    // Siri rejects a phrase that doesn't name the app.
                    #expect(phrase.components(separatedBy: "${applicationName}").count == 2, "\(language): \(phrase)")
                    #expect(seen.insert(phrase).inserted, "\(language) repeats \(phrase)")
                }
            }
        }
    }

    /// Words that are Russian and never Ukrainian. Seeing one in uk text means a value was
    /// copied from the Russian translation (#507).
    static let russianOnlyWords: Set<String> = [
        "ошибка", "ошибки", "пропустить", "будет", "будут", "добавить", "добавлено", "изменить",
        "изменения", "спасибо", "отправить", "поздравляем", "разрешить", "запретить", "дней", "цель",
        "цели", "еда", "еду", "вес", "веса", "что", "это", "чтобы", "сейчас", "нет", "или", "тоже",
        "также", "только", "можно", "нужно", "сначала", "затем", "осталось", "начнём", "записать",
        "сбросить", "получить", "пользователя", "уведомления", "язык", "медленно", "привет",
        "понятно", "проверить", "всего", "единица", "вручную", "минимум", "анализ",
    ]

    @Test(.enabled(if: LocalizationCatalogTests.sourceCatalogsAvailable))
    func ukrainianCatalogsContainNoRussian() throws {
        let catalogs = [
            "calorietracker/Localizable.xcstrings",
            "calorietracker/AIErrorMessages.xcstrings",
            "calorietracker/BarcodeLookup.xcstrings",
            "calorietracker/InfoPlist.xcstrings",
            "calorietracker/LocalModels.xcstrings",
            "calorietracker/WeeklyChallenge.xcstrings",
            "calorietracker/AppShortcuts.xcstrings",
            "FudAIWidgets/Localizable.xcstrings",
            "FudAIWatchApp/Localizable.xcstrings",
            "FudAIWatchWidgets/Localizable.xcstrings",
            "calorietrackerShare/Localizable.xcstrings",
        ]
        var checked = 0
        for catalog in catalogs {
            // Stale keys too: they still compile into the app, and some are still shown.
            for (key, entry) in try Self.sourceStrings(catalog) {
                let localizations = entry["localizations"] as? [String: Any] ?? [:]
                for text in Self.allText(localizations["uk"]) {
                    checked += 1
                    let lowered = text.lowercased()
                    #expect(!lowered.contains(where: { "ыэъё".contains($0) }), "\(catalog): uk \(key) uses Russian letters: \(text)")
                    let words = lowered.components(separatedBy: CharacterSet.letters.inverted)
                        .filter { Self.russianOnlyWords.contains($0) }
                    #expect(words.isEmpty, "\(catalog): uk \(key) is Russian (\(words)): \(text)")
                }
            }
        }
        #expect(checked > 1_500)
    }

    // MARK: - Helpers

    /// Every text in a localization: single values, plural forms and Siri phrase sets.
    static func allText(_ node: Any?) -> [String] {
        guard let node = node as? [String: Any] else { return [] }
        var texts: [String] = []
        if let value = (node["stringUnit"] as? [String: Any])?["value"] as? String {
            texts.append(value)
        }
        texts += ((node["stringSet"] as? [String: Any])?["values"] as? [String]) ?? []
        for (key, child) in node where key != "stringUnit" && key != "stringSet" {
            texts += allText(child)
        }
        return texts
    }

    nonisolated static let iosSourceRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // calorietrackerTests
        .deletingLastPathComponent() // ios

    /// The source catalogs exist only when the tests run next to the checkout.
    nonisolated static var sourceCatalogsAvailable: Bool {
        FileManager.default.fileExists(atPath: iosSourceRoot.appendingPathComponent("FudAIWidgets/Localizable.xcstrings").path)
    }

    static func sourceStrings(_ relativePath: String) throws -> [String: [String: Any]] {
        let data = try Data(contentsOf: iosSourceRoot.appendingPathComponent(relativePath))
        let catalog = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(catalog["strings"] as? [String: [String: Any]])
    }

    /// The translated text of one localization: a single value, or every plural form.
    static func translatedForms(_ localization: Any?) -> [String] {
        guard let localization = localization as? [String: Any] else { return [] }
        if let unit = localization["stringUnit"] as? [String: Any] {
            guard unit["state"] as? String == "translated", let value = unit["value"] as? String else { return [] }
            return [value]
        }
        let plural = (localization["variations"] as? [String: Any])?["plural"] as? [String: Any] ?? [:]
        return plural.values.flatMap { translatedForms($0) }
    }

    /// The format arguments in a string by position, ignoring how they are numbered.
    static func formatArguments(_ text: String) -> [Int: String] {
        let regex = try! NSRegularExpression(pattern: #"%(?:(\d+)\$)?(ll|l)?([@d])"#)
        var arguments: [Int: String] = [:]
        var next = 1
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let position = Range(match.range(at: 1), in: text).flatMap { Int(text[$0]) } ?? next
            let length = Range(match.range(at: 2), in: text).map { String(text[$0]) } ?? ""
            let conversion = Range(match.range(at: 3), in: text).map { String(text[$0]) } ?? ""
            arguments[position] = length + conversion
            next += 1
        }
        return arguments
    }

    static func embeddedExtension(_ name: String) throws -> Bundle {
        let plugIns = try #require(Bundle.main.builtInPlugInsURL)
        return try #require(Bundle(url: plugIns.appendingPathComponent("\(name).appex")))
    }

    static func languageBundle(_ language: String, in bundle: Bundle) throws -> Bundle {
        let path = try #require(bundle.path(forResource: language, ofType: "lproj"), "no \(language).lproj in \(bundle.bundlePath)")
        return try #require(Bundle(path: path))
    }

    static func hasTranslation(_ key: String, in bundle: Bundle) -> Bool {
        let missing = "\u{0}missing"
        return bundle.localizedString(forKey: key, value: missing, table: nil) != missing
    }

    /// Formats a key with integers the way String(localized:) does for that language.
    static func format(_ key: String, _ language: String, _ arguments: Int...) throws -> String {
        let bundle = try languageBundle(language, in: .main)
        let format = bundle.localizedString(forKey: key, value: nil, table: nil)
        return String(format: format, locale: Locale(identifier: language), arguments: arguments.map { Int64($0) as CVarArg })
    }
}
