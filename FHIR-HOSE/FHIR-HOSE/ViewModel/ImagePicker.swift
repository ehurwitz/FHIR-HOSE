//
//  ImagePicker.swift
//  FHIR-HOSE
//
//  Created by Eric Hurwitz on 12/3/24.
//

import SwiftUI
import PhotosUI

struct ImagePicker: UIViewControllerRepresentable {
    @ObservedObject var recordStore: HealthRecordStore
    
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.selectionLimit = 1
        config.filter = .images
        
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }
    
    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: ImagePicker
        
        init(_ parent: ImagePicker) {
            self.parent = parent
        }
        
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            
            guard let provider = results.first?.itemProvider else { return }
            
            if provider.canLoadObject(ofClass: UIImage.self) {
                provider.loadObject(ofClass: UIImage.self) { [weak self] image, error in
                    if let image = image as? UIImage {
                        // Save image to documents directory
                        let filename = "image_\(Date().timeIntervalSince1970).jpg"
                        if let data = image.jpegData(compressionQuality: 0.8),
                           let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                            let fileURL = documentsURL.appendingPathComponent(filename)
                            try? data.write(to: fileURL)
                            
                            // Add record to store
                            DispatchQueue.main.async {
                                self?.parent.recordStore.addRecord(filename: filename, type: .image)
                            }
                        }
                    }
                }
            }
        }
    }
}
