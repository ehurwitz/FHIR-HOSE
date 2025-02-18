//
//  FetchHealthKit.swift
//  FHIR-HOSE
//
//  Created by Eric Hurwitz on 12/3/24.
//

import HealthKit

class HealthKitManager {
    let healthStore = HKHealthStore()
    
    func requestAuthorization(completion: @escaping (Bool, Error?) -> Void) {
        let typesToRead: Set<HKObjectType> = [
            HKObjectType.characteristicType(forIdentifier: .dateOfBirth)!,
            HKObjectType.characteristicType(forIdentifier: .biologicalSex)!
        ]
        
        healthStore.requestAuthorization(toShare: nil, read: typesToRead) { success, error in
            completion(success, error)
        }
    }
    
    func fetchNameAndBirthday() -> (name: String?, birthday: Date?)? {
        do {
            // Get birthday
            let birthday = try healthStore.dateOfBirth()
            let name = "HealthKit User" // Placeholder - Healthkit does not natively provide method for fetching user name
            return (name: name, birthday: birthday)
        } catch {
            print("Error retrieving name or birthday: \(error.localizedDescription)")
            return nil
        }
    }
}


