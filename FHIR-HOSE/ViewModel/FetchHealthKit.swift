//
//  FetchHealthKit.swift
//  FHIR-HOSE
//
//  Created by Eric Hurwitz on 12/3/24.
//

import HealthKit
import Foundation

private let fileLogger = FileLogger.shared

class HealthKitManager: ObservableObject {
    let healthStore = HKHealthStore()
    
    private let quantityTypes: [HKQuantityTypeIdentifier] = [
        .heartRate,
        .bloodPressureSystolic,
        .bloodPressureDiastolic,
        .bodyTemperature,
        .height,
        .bodyMass,
        .stepCount,
        .distanceWalkingRunning,
        .activeEnergyBurned,
        .bloodGlucose,
        .oxygenSaturation
    ]
    
    private let categoryTypes: [HKCategoryTypeIdentifier] = [
        .sleepAnalysis,
        .mindfulSession,
        .menstrualFlow
    ]
    
    func requestAuthorization(completion: @escaping (Bool, Error?) -> Void) {
        var typesToRead = Set<HKObjectType>()
        
        // Add characteristic types
        typesToRead.insert(HKObjectType.characteristicType(forIdentifier: .dateOfBirth)!)
        typesToRead.insert(HKObjectType.characteristicType(forIdentifier: .biologicalSex)!)
        typesToRead.insert(HKObjectType.characteristicType(forIdentifier: .bloodType)!)
        
        // Add quantity types
        for identifier in quantityTypes {
            if let type = HKObjectType.quantityType(forIdentifier: identifier) {
                typesToRead.insert(type)
            }
        }
        
        // Add category types
        for identifier in categoryTypes {
            if let type = HKObjectType.categoryType(forIdentifier: identifier) {
                typesToRead.insert(type)
            }
        }
        
        // Add clinical record types
        if let clinicalRecordType = HKObjectType.clinicalType(forIdentifier: .allergyRecord) {
            typesToRead.insert(clinicalRecordType)
        }
        if let clinicalRecordType = HKObjectType.clinicalType(forIdentifier: .conditionRecord) {
            typesToRead.insert(clinicalRecordType)
        }
        if let clinicalRecordType = HKObjectType.clinicalType(forIdentifier: .medicationRecord) {
            typesToRead.insert(clinicalRecordType)
        }
        if let clinicalRecordType = HKObjectType.clinicalType(forIdentifier: .procedureRecord) {
            typesToRead.insert(clinicalRecordType)
        }
        if let clinicalRecordType = HKObjectType.clinicalType(forIdentifier: .immunizationRecord) {
            typesToRead.insert(clinicalRecordType)
        }
        if let clinicalRecordType = HKObjectType.clinicalType(forIdentifier: .labResultRecord) {
            typesToRead.insert(clinicalRecordType)
        }
        
        healthStore.requestAuthorization(toShare: nil, read: typesToRead) { success, error in
            completion(success, error)
        }
    }
    
    func fetchAllHealthRecords(completion: @escaping ([HealthRecord]) -> Void) {
        var allRecords: [HealthRecord] = []
        let group = DispatchGroup()
        
        // Fetch characteristics
        group.enter()
        fetchCharacteristics { records in
            allRecords.append(contentsOf: records)
            group.leave()
        }
        
        // Fetch quantity samples
        for identifier in quantityTypes {
            group.enter()
            fetchQuantityData(for: identifier) { records in
                allRecords.append(contentsOf: records)
                group.leave()
            }
        }
        
        // Fetch category samples
        for identifier in categoryTypes {
            group.enter()
            fetchCategoryData(for: identifier) { records in
                allRecords.append(contentsOf: records)
                group.leave()
            }
        }
        
        // Fetch clinical records
        group.enter()
        fetchClinicalRecords { records in
            allRecords.append(contentsOf: records)
            group.leave()
        }
        
        group.notify(queue: .main) {
            completion(allRecords)
        }
    }
    
    private func fetchCharacteristics(completion: @escaping ([HealthRecord]) -> Void) {
        var records: [HealthRecord] = []
        
        do {
            // Date of birth
            if let birthday = try? healthStore.dateOfBirth() {
                let data: [String: Any] = [
                    "type": "dateOfBirth",
                    "value": birthday,
                    "displayName": "Date of Birth"
                ]
                records.append(HealthRecord(healthKitType: "DateOfBirth", data: data, date: birthday))
            }
            
            // Biological sex
            let biologicalSex = try healthStore.biologicalSex()
            let sexData: [String: Any] = [
                "type": "biologicalSex",
                "value": biologicalSex.biologicalSex.rawValue,
                "displayName": "Biological Sex"
            ]
            records.append(HealthRecord(healthKitType: "BiologicalSex", data: sexData))
            
            // Blood type
            let bloodType = try healthStore.bloodType()
            let bloodData: [String: Any] = [
                "type": "bloodType",
                "value": bloodType.bloodType.rawValue,
                "displayName": "Blood Type"
            ]
            records.append(HealthRecord(healthKitType: "BloodType", data: bloodData))
            
        } catch {
            fileLogger.error("Error fetching characteristics: \(error)", category: "HealthKit")
        }
        
        completion(records)
    }
    
    private func fetchQuantityData(for identifier: HKQuantityTypeIdentifier, completion: @escaping ([HealthRecord]) -> Void) {
        guard let quantityType = HKObjectType.quantityType(forIdentifier: identifier) else {
            completion([])
            return
        }
        
        let query = HKSampleQuery(
            sampleType: quantityType,
            predicate: nil,
            limit: 100,
            sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
        ) { _, samples, error in
            
            guard let samples = samples as? [HKQuantitySample], error == nil else {
                completion([])
                return
            }
            
            let records = samples.map { sample in
                // Use a common unit for the quantity type
                let unit: HKUnit
                switch identifier {
                case .heartRate:
                    unit = HKUnit.count().unitDivided(by: .minute())
                case .bloodPressureSystolic, .bloodPressureDiastolic:
                    unit = HKUnit.millimeterOfMercury()
                case .bodyTemperature:
                    unit = HKUnit.degreeCelsius()
                case .height:
                    unit = HKUnit.meter()
                case .bodyMass:
                    unit = HKUnit.gramUnit(with: .kilo)
                case .stepCount:
                    unit = HKUnit.count()
                case .distanceWalkingRunning:
                    unit = HKUnit.meter()
                case .activeEnergyBurned:
                    unit = HKUnit.kilocalorie()
                case .bloodGlucose:
                    unit = HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci))
                case .oxygenSaturation:
                    unit = HKUnit.percent()
                default:
                    unit = HKUnit.count()
                }
                
                let data: [String: Any] = [
                    "type": identifier.rawValue,
                    "value": sample.quantity.doubleValue(for: unit),
                    "unit": unit.unitString,
                    "startDate": sample.startDate,
                    "endDate": sample.endDate,
                    "displayName": sample.quantityType.identifier
                ]
                return HealthRecord(healthKitType: identifier.rawValue, data: data, date: sample.startDate)
            }
            
            completion(records)
        }
        
        healthStore.execute(query)
    }
    
    private func fetchCategoryData(for identifier: HKCategoryTypeIdentifier, completion: @escaping ([HealthRecord]) -> Void) {
        guard let categoryType = HKObjectType.categoryType(forIdentifier: identifier) else {
            completion([])
            return
        }
        
        let query = HKSampleQuery(
            sampleType: categoryType,
            predicate: nil,
            limit: 100,
            sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
        ) { _, samples, error in
            
            guard let samples = samples as? [HKCategorySample], error == nil else {
                completion([])
                return
            }
            
            let records = samples.map { sample in
                let data: [String: Any] = [
                    "type": identifier.rawValue,
                    "value": sample.value,
                    "startDate": sample.startDate,
                    "endDate": sample.endDate,
                    "displayName": sample.categoryType.identifier
                ]
                return HealthRecord(healthKitType: identifier.rawValue, data: data, date: sample.startDate)
            }
            
            completion(records)
        }
        
        healthStore.execute(query)
    }
    
    private func fetchClinicalRecords(completion: @escaping ([HealthRecord]) -> Void) {
        var allClinicalRecords: [HealthRecord] = []
        let clinicalTypes: [HKClinicalTypeIdentifier] = [
            .allergyRecord, .conditionRecord, .medicationRecord,
            .procedureRecord, .immunizationRecord, .labResultRecord
        ]
        
        let group = DispatchGroup()
        
        for identifier in clinicalTypes {
            guard let clinicalType = HKObjectType.clinicalType(forIdentifier: identifier) else { continue }
            
            group.enter()
            let query = HKSampleQuery(
                sampleType: clinicalType,
                predicate: nil,
                limit: 100,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
            ) { _, samples, error in
                
                defer { group.leave() }
                
                guard let samples = samples as? [HKClinicalRecord], error == nil else {
                    return
                }
                
                let records = samples.map { sample in
                    let data: [String: Any] = [
                        "type": identifier.rawValue,
                        "displayName": sample.clinicalType.identifier,
                        "startDate": sample.startDate,
                        "endDate": sample.endDate,
                        "fhirResource": sample.fhirResource?.data.base64EncodedString() ?? ""
                    ]
                    return HealthRecord(healthKitType: identifier.rawValue, data: data, date: sample.startDate)
                }
                
                allClinicalRecords.append(contentsOf: records)
            }
            
            healthStore.execute(query)
        }
        
        group.notify(queue: .main) {
            completion(allClinicalRecords)
        }
    }
    
    func fetchNameAndBirthday() -> (name: String?, birthday: Date?)? {
        do {
            // Get birthday
            let birthday = try healthStore.dateOfBirth()
            let name = "HealthKit User" // Placeholder - Healthkit does not natively provide method for fetching user name
            return (name: name, birthday: birthday)
        } catch {
            fileLogger.error("Error retrieving name or birthday: \(error.localizedDescription)", category: "HealthKit")
            return nil
        }
    }
}


