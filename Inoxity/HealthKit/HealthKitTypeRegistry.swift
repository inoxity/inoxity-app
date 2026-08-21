import HealthKit

/// How `HealthKitService.query(_:interval:)` should read a metadata entry's recent local value
/// for the "See My Data" / diagnostics summary — replaces what used to be three separate
/// identifier-string switches (one per call site) with one data-driven field on the registry
/// entry itself. `.none` is used for sample kinds this strategy doesn't apply to (correlation,
/// which is sync-only in this pass — see HealthKitTypeMetadata's doc comment).
enum HealthKitAggregationStrategy: String, Sendable {
    /// Sum all samples in the window, then report today/yesterday/7-day-average (steps, active
    /// energy, exercise time, nutrition, and anything else that's naturally a running total).
    case cumulativeDaily
    /// Report the most recent sample's value plus a recent average (heart rate, body
    /// measurements, vitals — anything that's a point-in-time reading, not a running total).
    case latestValue
    /// Just count how many samples exist in the window (sleep, workouts, and every category
    /// type — symptoms, reproductive health, heart-rhythm events — which don't have a
    /// meaningful "total" or "latest value" the way a quantity does).
    case sampleCount
    case none
}

struct HealthKitTypeMetadata {
    let identifier: String
    let displayLabel: String
    let objectType: HKObjectType
    let unit: HKUnit?
    let sampleKind: HealthKitSampleKind
    /// Doubles as both the machine-readable unit string `HealthKitSampleNormalizer` validates
    /// uploads against AND the human-readable unit label shown in local summaries — nothing
    /// downstream actually stores this string anywhere (the SQL side bakes the unit into each
    /// table's column name instead, e.g. `bpm`/`kcal`), so one shared string safely serves both
    /// roles rather than needing two kept in sync by hand.
    let canonicalUploadUnit: String?
    /// SF Symbol shown next to this metric in local summaries (`SeeMyDataView`) — previously
    /// hardcoded per-metric directly in that view; centralized here so the view can render any
    /// configured identifier generically instead of one hardcoded line per metric.
    let symbol: String
    let aggregationStrategy: HealthKitAggregationStrategy
    /// Decimal places for local-summary number formatting. 0 for count-like values (steps,
    /// flights climbed), 1 for most continuous quantities — a reasonable default rather than
    /// hand-tuned precision per identifier, which isn't practical at this catalog's size.
    let displayPrecision: Int
    /// The dedicated Study Backend table this identifier's samples land in — see
    /// supabase/study_backend_template/migrations/005_healthkit_samples.sql and
    /// inoxity-dashboard/src/lib/generate-backend-sql.ts, which must both stay in
    /// sync with this mapping.
    let tableName: String
}

enum HealthKitTypeRegistry {
    static let supportedIdentifiers: Set<String> = Set(metadata.keys)

    static func type(for identifier: String) throws -> HealthKitTypeMetadata {
        guard let value = metadata[identifier] else {
            throw HealthKitServiceError.unsupportedIdentifier(identifier)
        }
        return value
    }

    static func types(for identifiers: Set<String>) throws -> [HealthKitTypeMetadata] {
        try identifiers.sorted().map(type(for:))
    }

    private static let metadata: [String: HealthKitTypeMetadata] = {
        func quantity(
            _ identifier: HKQuantityTypeIdentifier, _ configured: String, _ label: String, _ unit: HKUnit,
            _ canonical: String, _ symbol: String, _ aggregation: HealthKitAggregationStrategy,
            _ precision: Int, _ table: String
        ) -> HealthKitTypeMetadata {
            HealthKitTypeMetadata(identifier: configured, displayLabel: label,
                objectType: HKObjectType.quantityType(forIdentifier: identifier)!, unit: unit, sampleKind: .quantity,
                canonicalUploadUnit: canonical, symbol: symbol, aggregationStrategy: aggregation,
                displayPrecision: precision, tableName: table)
        }
        func category(
            _ identifier: HKCategoryTypeIdentifier, _ configured: String, _ label: String, _ symbol: String, _ table: String
        ) -> HealthKitTypeMetadata {
            HealthKitTypeMetadata(identifier: configured, displayLabel: label,
                objectType: HKObjectType.categoryType(forIdentifier: identifier)!, unit: nil, sampleKind: .category,
                canonicalUploadUnit: nil, symbol: symbol, aggregationStrategy: .sampleCount,
                displayPrecision: 0, tableName: table)
        }
        func correlation(
            _ identifier: HKCorrelationTypeIdentifier, _ configured: String, _ label: String, _ symbol: String,
            _ unitLabel: String, _ table: String
        ) -> HealthKitTypeMetadata {
            // unit stays nil (unlike quantity types) — a correlation isn't itself a single
            // quantity, HealthKitSampleQuerying reads its two sub-quantities directly. unitLabel
            // is still populated (unlike category types) purely for display/documentation, since
            // there genuinely is one shared unit (mmHg) for both of blood pressure's values.
            HealthKitTypeMetadata(identifier: configured, displayLabel: label,
                objectType: HKObjectType.correlationType(forIdentifier: identifier)!, unit: nil, sampleKind: .correlation,
                canonicalUploadUnit: unitLabel, symbol: symbol, aggregationStrategy: .none,
                displayPrecision: 0, tableName: table)
        }

        var entries: [String: HealthKitTypeMetadata] = [
            // MARK: Original 10 — table names, units, and behavior unchanged.
            "sleepAnalysis": .init(identifier: "sleepAnalysis", displayLabel: "Sleep",
                objectType: HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!, unit: nil, sampleKind: .category,
                canonicalUploadUnit: nil, symbol: "moon.stars", aggregationStrategy: .sampleCount,
                displayPrecision: 0, tableName: "sleep_samples"),
            "stepCount": quantity(.stepCount, "stepCount", "Steps", .count(), "steps", "figure.walk", .cumulativeDaily, 0, "step_count_samples"),
            "restingHeartRate": quantity(.restingHeartRate, "restingHeartRate", "Resting heart rate", HKUnit.count().unitDivided(by: .minute()), "beats/min", "heart.circle", .latestValue, 0, "resting_heart_rate_samples"),
            "heartRate": quantity(.heartRate, "heartRate", "Heart rate", HKUnit.count().unitDivided(by: .minute()), "beats/min", "heart", .latestValue, 0, "heart_rate_samples"),
            "heartRateVariabilitySDNN": quantity(.heartRateVariabilitySDNN, "heartRateVariabilitySDNN", "Heart rate variability", .secondUnit(with: .milli), "ms", "waveform.path.ecg", .latestValue, 0, "heart_rate_variability_samples"),
            "activeEnergyBurned": quantity(.activeEnergyBurned, "activeEnergyBurned", "Active energy", .kilocalorie(), "kcal", "flame", .cumulativeDaily, 0, "active_energy_samples"),
            "appleExerciseTime": quantity(.appleExerciseTime, "appleExerciseTime", "Exercise time", .minute(), "min", "figure.run", .cumulativeDaily, 0, "exercise_time_samples"),
            "respiratoryRate": quantity(.respiratoryRate, "respiratoryRate", "Respiratory rate", HKUnit.count().unitDivided(by: .minute()), "breaths/min", "lungs", .latestValue, 1, "respiratory_rate_samples"),
            "timeInDaylight": quantity(.timeInDaylight, "timeInDaylight", "Time in daylight", .minute(), "min", "sun.max", .cumulativeDaily, 0, "daylight_samples"),
            "workout": .init(identifier: "workout", displayLabel: "Workouts",
                objectType: HKObjectType.workoutType(), unit: nil, sampleKind: .workout, canonicalUploadUnit: "s",
                symbol: "figure.mixed.cardio", aggregationStrategy: .sampleCount, displayPrecision: 0, tableName: "workout_samples"),
        ]

        // MARK: Activity & fitness
        let activity: [HealthKitTypeMetadata] = [
            quantity(.distanceWalkingRunning, "distanceWalkingRunning", "Walking + running distance", .mile(), "mi", "figure.walk", .cumulativeDaily, 1, "distance_walking_running_samples"),
            quantity(.distanceCycling, "distanceCycling", "Cycling distance", .mile(), "mi", "bicycle", .cumulativeDaily, 1, "distance_cycling_samples"),
            quantity(.distanceSwimming, "distanceSwimming", "Swimming distance", .mile(), "mi", "figure.pool.swim", .cumulativeDaily, 1, "distance_swimming_samples"),
            quantity(.distanceWheelchair, "distanceWheelchair", "Wheelchair distance", .mile(), "mi", "figure.roll", .cumulativeDaily, 1, "distance_wheelchair_samples"),
            quantity(.flightsClimbed, "flightsClimbed", "Flights climbed", .count(), "count", "figure.stairs", .cumulativeDaily, 0, "flights_climbed_samples"),
            quantity(.pushCount, "pushCount", "Push count", .count(), "count", "figure.roll", .cumulativeDaily, 0, "push_count_samples"),
            quantity(.swimmingStrokeCount, "swimmingStrokeCount", "Swimming strokes", .count(), "count", "figure.pool.swim", .cumulativeDaily, 0, "swimming_stroke_count_samples"),
            quantity(.basalEnergyBurned, "basalEnergyBurned", "Resting energy", .kilocalorie(), "kcal", "flame", .cumulativeDaily, 0, "basal_energy_samples"),
            quantity(.appleStandTime, "appleStandTime", "Stand time", .minute(), "min", "figure.stand", .cumulativeDaily, 0, "stand_time_samples"),
            quantity(.walkingSpeed, "walkingSpeed", "Walking speed", HKUnit.meter().unitDivided(by: .second()), "m/s", "figure.walk", .latestValue, 2, "walking_speed_samples"),
            quantity(.walkingStepLength, "walkingStepLength", "Walking step length", .meter(), "m", "ruler", .latestValue, 2, "walking_step_length_samples"),
            quantity(.walkingAsymmetryPercentage, "walkingAsymmetryPercentage", "Walking asymmetry", .percent(), "%", "figure.walk", .latestValue, 1, "walking_asymmetry_samples"),
            quantity(.walkingDoubleSupportPercentage, "walkingDoubleSupportPercentage", "Walking double support", .percent(), "%", "figure.walk", .latestValue, 1, "walking_double_support_samples"),
            quantity(.sixMinuteWalkTestDistance, "sixMinuteWalkTestDistance", "Six-minute walk distance", .meter(), "m", "figure.walk", .latestValue, 1, "six_minute_walk_samples"),
            quantity(.stairAscentSpeed, "stairAscentSpeed", "Stair ascent speed", HKUnit.meter().unitDivided(by: .second()), "m/s", "figure.stairs", .latestValue, 2, "stair_ascent_speed_samples"),
            quantity(.stairDescentSpeed, "stairDescentSpeed", "Stair descent speed", HKUnit.meter().unitDivided(by: .second()), "m/s", "figure.stairs", .latestValue, 2, "stair_descent_speed_samples"),
        ]

        // MARK: Body measurements
        let bodyMeasurements: [HealthKitTypeMetadata] = [
            quantity(.height, "height", "Height", .meter(), "m", "ruler", .latestValue, 2, "height_samples"),
            quantity(.bodyMass, "bodyMass", "Body mass", .gramUnit(with: .kilo), "kg", "scalemass", .latestValue, 1, "body_mass_samples"),
            quantity(.bodyMassIndex, "bodyMassIndex", "Body mass index", .count(), "count", "figure", .latestValue, 1, "body_mass_index_samples"),
            quantity(.leanBodyMass, "leanBodyMass", "Lean body mass", .gramUnit(with: .kilo), "kg", "figure.arms.open", .latestValue, 1, "lean_body_mass_samples"),
            quantity(.bodyFatPercentage, "bodyFatPercentage", "Body fat percentage", .percent(), "%", "figure", .latestValue, 1, "body_fat_percentage_samples"),
            quantity(.waistCircumference, "waistCircumference", "Waist circumference", .meter(), "m", "ruler", .latestValue, 2, "waist_circumference_samples"),
            quantity(.bodyTemperature, "bodyTemperature", "Body temperature", .degreeCelsius(), "degC", "thermometer", .latestValue, 1, "body_temperature_samples"),
            quantity(.basalBodyTemperature, "basalBodyTemperature", "Basal body temperature", .degreeCelsius(), "degC", "thermometer", .latestValue, 1, "basal_body_temperature_samples"),
            quantity(.electrodermalActivity, "electrodermalActivity", "Electrodermal activity", HKUnit.siemenUnit(with: .micro), "uS", "bolt", .latestValue, 2, "electrodermal_activity_samples"),
        ]

        // MARK: Vitals
        let vitals: [HealthKitTypeMetadata] = [
            quantity(.oxygenSaturation, "oxygenSaturation", "Blood oxygen", .percent(), "%", "lungs", .latestValue, 1, "oxygen_saturation_samples"),
            quantity(.bloodGlucose, "bloodGlucose", "Blood glucose", HKUnit(from: "mg/dL"), "mg/dL", "drop", .latestValue, 0, "blood_glucose_samples"),
            quantity(.forcedVitalCapacity, "forcedVitalCapacity", "Forced vital capacity", .liter(), "L", "lungs", .latestValue, 2, "forced_vital_capacity_samples"),
            quantity(.forcedExpiratoryVolume1, "forcedExpiratoryVolume1", "Forced expiratory volume", .liter(), "L", "lungs", .latestValue, 2, "forced_expiratory_volume_samples"),
            quantity(.peakExpiratoryFlowRate, "peakExpiratoryFlowRate", "Peak expiratory flow", HKUnit.liter().unitDivided(by: .minute()), "L/min", "lungs", .latestValue, 1, "peak_expiratory_flow_samples"),
            quantity(.inhalerUsage, "inhalerUsage", "Inhaler usage", .count(), "count", "lungs", .cumulativeDaily, 0, "inhaler_usage_samples"),
            quantity(.insulinDelivery, "insulinDelivery", "Insulin delivery", .internationalUnit(), "IU", "syringe", .cumulativeDaily, 1, "insulin_delivery_samples"),
            quantity(.numberOfTimesFallen, "numberOfTimesFallen", "Falls", .count(), "count", "figure.fall", .cumulativeDaily, 0, "falls_samples"),
        ]

        // MARK: Hearing
        let hearing: [HealthKitTypeMetadata] = [
            quantity(.environmentalAudioExposure, "environmentalAudioExposure", "Environmental sound", .decibelAWeightedSoundPressureLevel(), "dBASPL", "ear", .latestValue, 0, "environmental_audio_exposure_samples"),
            quantity(.headphoneAudioExposure, "headphoneAudioExposure", "Headphone audio", .decibelAWeightedSoundPressureLevel(), "dBASPL", "airpods", .latestValue, 0, "headphone_audio_exposure_samples"),
        ]

        // MARK: Environment
        let environment: [HealthKitTypeMetadata] = [
            quantity(.uvExposure, "uvExposure", "UV exposure", .count(), "count", "sun.max", .cumulativeDaily, 0, "uv_exposure_samples"),
            quantity(.waterTemperature, "waterTemperature", "Water temperature", .degreeCelsius(), "degC", "thermometer", .latestValue, 1, "water_temperature_samples"),
            quantity(.underwaterDepth, "underwaterDepth", "Underwater depth", .meter(), "m", "water.waves", .latestValue, 1, "underwater_depth_samples"),
        ]

        // MARK: Nutrition — all cumulative daily totals.
        let nutrition: [HealthKitTypeMetadata] = [
            quantity(.dietaryEnergyConsumed, "dietaryEnergyConsumed", "Dietary energy", .kilocalorie(), "kcal", "fork.knife", .cumulativeDaily, 0, "dietary_energy_samples"),
            quantity(.dietaryProtein, "dietaryProtein", "Protein", .gram(), "g", "fork.knife", .cumulativeDaily, 1, "dietary_protein_samples"),
            quantity(.dietaryCarbohydrates, "dietaryCarbohydrates", "Carbohydrates", .gram(), "g", "fork.knife", .cumulativeDaily, 1, "dietary_carbohydrates_samples"),
            quantity(.dietaryFiber, "dietaryFiber", "Fiber", .gram(), "g", "fork.knife", .cumulativeDaily, 1, "dietary_fiber_samples"),
            quantity(.dietarySugar, "dietarySugar", "Sugar", .gram(), "g", "fork.knife", .cumulativeDaily, 1, "dietary_sugar_samples"),
            quantity(.dietaryFatTotal, "dietaryFatTotal", "Total fat", .gram(), "g", "fork.knife", .cumulativeDaily, 1, "dietary_fat_total_samples"),
            quantity(.dietaryFatSaturated, "dietaryFatSaturated", "Saturated fat", .gram(), "g", "fork.knife", .cumulativeDaily, 1, "dietary_fat_saturated_samples"),
            quantity(.dietaryFatMonounsaturated, "dietaryFatMonounsaturated", "Monounsaturated fat", .gram(), "g", "fork.knife", .cumulativeDaily, 1, "dietary_fat_monounsaturated_samples"),
            quantity(.dietaryFatPolyunsaturated, "dietaryFatPolyunsaturated", "Polyunsaturated fat", .gram(), "g", "fork.knife", .cumulativeDaily, 1, "dietary_fat_polyunsaturated_samples"),
            quantity(.dietaryCholesterol, "dietaryCholesterol", "Cholesterol", .gramUnit(with: .milli), "mg", "fork.knife", .cumulativeDaily, 0, "dietary_cholesterol_samples"),
            quantity(.dietarySodium, "dietarySodium", "Sodium", .gramUnit(with: .milli), "mg", "fork.knife", .cumulativeDaily, 0, "dietary_sodium_samples"),
            quantity(.dietaryPotassium, "dietaryPotassium", "Potassium", .gramUnit(with: .milli), "mg", "fork.knife", .cumulativeDaily, 0, "dietary_potassium_samples"),
            quantity(.dietaryCalcium, "dietaryCalcium", "Calcium", .gramUnit(with: .milli), "mg", "fork.knife", .cumulativeDaily, 0, "dietary_calcium_samples"),
            quantity(.dietaryIron, "dietaryIron", "Iron", .gramUnit(with: .milli), "mg", "fork.knife", .cumulativeDaily, 1, "dietary_iron_samples"),
            quantity(.dietaryMagnesium, "dietaryMagnesium", "Magnesium", .gramUnit(with: .milli), "mg", "fork.knife", .cumulativeDaily, 0, "dietary_magnesium_samples"),
            quantity(.dietaryZinc, "dietaryZinc", "Zinc", .gramUnit(with: .milli), "mg", "fork.knife", .cumulativeDaily, 1, "dietary_zinc_samples"),
            quantity(.dietaryVitaminA, "dietaryVitaminA", "Vitamin A", .gramUnit(with: .micro), "ug", "fork.knife", .cumulativeDaily, 0, "dietary_vitamin_a_samples"),
            quantity(.dietaryVitaminC, "dietaryVitaminC", "Vitamin C", .gramUnit(with: .milli), "mg", "fork.knife", .cumulativeDaily, 0, "dietary_vitamin_c_samples"),
            quantity(.dietaryVitaminD, "dietaryVitaminD", "Vitamin D", .gramUnit(with: .micro), "ug", "fork.knife", .cumulativeDaily, 0, "dietary_vitamin_d_samples"),
            quantity(.dietaryVitaminE, "dietaryVitaminE", "Vitamin E", .gramUnit(with: .milli), "mg", "fork.knife", .cumulativeDaily, 1, "dietary_vitamin_e_samples"),
            quantity(.dietaryVitaminK, "dietaryVitaminK", "Vitamin K", .gramUnit(with: .micro), "ug", "fork.knife", .cumulativeDaily, 0, "dietary_vitamin_k_samples"),
            quantity(.dietaryVitaminB6, "dietaryVitaminB6", "Vitamin B6", .gramUnit(with: .milli), "mg", "fork.knife", .cumulativeDaily, 1, "dietary_vitamin_b6_samples"),
            quantity(.dietaryVitaminB12, "dietaryVitaminB12", "Vitamin B12", .gramUnit(with: .micro), "ug", "fork.knife", .cumulativeDaily, 1, "dietary_vitamin_b12_samples"),
            quantity(.dietaryCaffeine, "dietaryCaffeine", "Caffeine", .gramUnit(with: .milli), "mg", "cup.and.saucer", .cumulativeDaily, 0, "dietary_caffeine_samples"),
            quantity(.dietaryWater, "dietaryWater", "Water", .literUnit(with: .milli), "mL", "drop", .cumulativeDaily, 0, "dietary_water_samples"),
        ]

        // MARK: Heart rhythm events (category)
        let heartEvents: [HealthKitTypeMetadata] = [
            category(.highHeartRateEvent, "highHeartRateEvent", "High heart rate events", "waveform.path.ecg", "high_heart_rate_event_samples"),
            category(.lowHeartRateEvent, "lowHeartRateEvent", "Low heart rate events", "waveform.path.ecg", "low_heart_rate_event_samples"),
            category(.irregularHeartRhythmEvent, "irregularHeartRhythmEvent", "Irregular rhythm events", "waveform.path.ecg", "irregular_heart_rhythm_event_samples"),
        ]

        // MARK: Mindfulness
        let mindfulness: [HealthKitTypeMetadata] = [
            category(.mindfulSession, "mindfulSession", "Mindful minutes", "brain.head.profile", "mindful_session_samples"),
        ]

        // MARK: Reproductive health (category)
        let reproductiveHealth: [HealthKitTypeMetadata] = [
            category(.menstrualFlow, "menstrualFlow", "Menstrual flow", "drop", "menstrual_flow_samples"),
            category(.intermenstrualBleeding, "intermenstrualBleeding", "Intermenstrual bleeding", "drop", "intermenstrual_bleeding_samples"),
            category(.sexualActivity, "sexualActivity", "Sexual activity", "heart", "sexual_activity_samples"),
            category(.ovulationTestResult, "ovulationTestResult", "Ovulation test results", "testtube.2", "ovulation_test_samples"),
            category(.contraceptive, "contraceptive", "Contraceptive use", "pills", "contraceptive_samples"),
            category(.pregnancy, "pregnancy", "Pregnancy", "figure.2", "pregnancy_samples"),
            category(.pregnancyTestResult, "pregnancyTestResult", "Pregnancy test results", "testtube.2", "pregnancy_test_samples"),
            category(.lactation, "lactation", "Lactation", "drop", "lactation_samples"),
            category(.cervicalMucusQuality, "cervicalMucusQuality", "Cervical mucus quality", "drop", "cervical_mucus_quality_samples"),
        ]

        // MARK: Symptoms (category)
        let symptoms: [HealthKitTypeMetadata] = [
            category(.abdominalCramps, "abdominalCramps", "Abdominal cramps", "exclamationmark.circle", "symptom_abdominal_cramps_samples"),
            category(.bloating, "bloating", "Bloating", "exclamationmark.circle", "symptom_bloating_samples"),
            category(.constipation, "constipation", "Constipation", "exclamationmark.circle", "symptom_constipation_samples"),
            category(.diarrhea, "diarrhea", "Diarrhea", "exclamationmark.circle", "symptom_diarrhea_samples"),
            category(.dizziness, "dizziness", "Dizziness", "exclamationmark.circle", "symptom_dizziness_samples"),
            category(.fatigue, "fatigue", "Fatigue", "exclamationmark.circle", "symptom_fatigue_samples"),
            category(.fever, "fever", "Fever", "thermometer", "symptom_fever_samples"),
            category(.generalizedBodyAche, "generalizedBodyAche", "Body ache", "exclamationmark.circle", "symptom_body_ache_samples"),
            category(.headache, "headache", "Headache", "exclamationmark.circle", "symptom_headache_samples"),
            category(.heartburn, "heartburn", "Heartburn", "exclamationmark.circle", "symptom_heartburn_samples"),
            category(.lossOfSmell, "lossOfSmell", "Loss of smell", "exclamationmark.circle", "symptom_loss_of_smell_samples"),
            category(.lossOfTaste, "lossOfTaste", "Loss of taste", "exclamationmark.circle", "symptom_loss_of_taste_samples"),
            category(.nausea, "nausea", "Nausea", "exclamationmark.circle", "symptom_nausea_samples"),
            category(.rapidPoundingOrFlutteringHeartbeat, "rapidPoundingOrFlutteringHeartbeat", "Rapid or fluttering heartbeat", "waveform.path.ecg", "symptom_rapid_heartbeat_samples"),
            category(.runnyNose, "runnyNose", "Runny nose", "exclamationmark.circle", "symptom_runny_nose_samples"),
            category(.shortnessOfBreath, "shortnessOfBreath", "Shortness of breath", "lungs", "symptom_shortness_of_breath_samples"),
            category(.sinusCongestion, "sinusCongestion", "Sinus congestion", "exclamationmark.circle", "symptom_sinus_congestion_samples"),
            category(.soreThroat, "soreThroat", "Sore throat", "exclamationmark.circle", "symptom_sore_throat_samples"),
            category(.vomiting, "vomiting", "Vomiting", "exclamationmark.circle", "symptom_vomiting_samples"),
            category(.wheezing, "wheezing", "Wheezing", "lungs", "symptom_wheezing_samples"),
            category(.coughing, "coughing", "Coughing", "exclamationmark.circle", "symptom_coughing_samples"),
            category(.chills, "chills", "Chills", "exclamationmark.circle", "symptom_chills_samples"),
            category(.chestTightnessOrPain, "chestTightnessOrPain", "Chest tightness or pain", "exclamationmark.circle", "symptom_chest_tightness_samples"),
            category(.moodChanges, "moodChanges", "Mood changes", "face.smiling", "symptom_mood_changes_samples"),
            category(.sleepChanges, "sleepChanges", "Sleep changes", "moon.zzz", "symptom_sleep_changes_samples"),
            category(.memoryLapse, "memoryLapse", "Memory lapse", "exclamationmark.circle", "symptom_memory_lapse_samples"),
            category(.hotFlashes, "hotFlashes", "Hot flashes", "thermometer", "symptom_hot_flashes_samples"),
            category(.lowerBackPain, "lowerBackPain", "Lower back pain", "exclamationmark.circle", "symptom_lower_back_pain_samples"),
            category(.appetiteChanges, "appetiteChanges", "Appetite changes", "fork.knife", "symptom_appetite_changes_samples"),
            category(.bladderIncontinence, "bladderIncontinence", "Bladder incontinence", "exclamationmark.circle", "symptom_bladder_incontinence_samples"),
        ]

        // MARK: Correlations
        // Sync-only in this pass: bloodPressure's two-value shape (systolic+diastolic) is
        // wired into HealthKitSampleQuerying/HealthKitSampleNormalizer/the upload pipeline, but
        // deliberately NOT into HealthSummaryService's local "See My Data" summaries yet — that
        // pipeline's QuantityMetricSummary/DailyMetricSummary shapes assume one value, not two.
        // `unit`/`canonicalUploadUnit` stay nil (unlike quantity types) since a correlation isn't
        // itself a single quantity — HealthKitSampleQuerying reads its two sub-quantities directly.
        let correlations: [HealthKitTypeMetadata] = [
            correlation(.bloodPressure, "bloodPressure", "Blood pressure", "heart.text.square", "mmHg", "blood_pressure_samples"),
        ]

        for group in [activity, bodyMeasurements, vitals, hearing, environment, nutrition, heartEvents,
                      mindfulness, reproductiveHealth, symptoms, correlations] {
            for item in group { entries[item.identifier] = item }
        }
        return entries
    }()
}
