//
//  ALVideoCoder.swift
//  Pods
//
//  Created by Sander on 9/29/18.
//

import Foundation
import Photos

private struct ProgressItem {
    var progress: Progress
    var durationSeconds: Int
}

protocol AssetSource {
    var durationSeconds: Int { get }
    func getAVAsset(_ handler: @escaping (AVAsset?) -> Void)
}

extension PHAsset: AssetSource {
    
    var durationSeconds: Int {
        return Int(duration)
    }
    
    func getAVAsset(_ handler: @escaping (AVAsset?) -> Void) {
        let options = PHVideoRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        
        PHImageManager.default().requestAVAsset(forVideo: self, options: options) { (asset, audioMix, info) in
            handler(asset)
        }
    }
}
extension AVAsset: AssetSource {
    
     var durationSeconds: Int {
        return Int(CMTimeGetSeconds(duration))
    }
    func getAVAsset(_ handler: @escaping (AVAsset?) -> Void) {
        handler(self)
    }
}

@objc public class ALVideoCoder: NSObject {
    
    // EXPORT PROGRESS VALUES
    private var exportingVideoSessions = [AVAssetWriter]()
    private var progressItems = [ProgressItem]()
    private var mainProgress: Progress?
    
    @objc public func convert(phAssets: [PHAsset], baseVC: UIViewController, completion: @escaping ([String]?) -> Void) {
        convert(videoAssets: phAssets, baseVC: baseVC, completion: completion)
    }
    
    @objc public func convert(avAssets: [AVURLAsset], baseVC: UIViewController, completion: @escaping ([String]?) -> Void) {
        convert(videoAssets: avAssets, baseVC: baseVC, completion: completion)
    }
    
    func convert(videoAssets: [AssetSource], baseVC: UIViewController, completion: @escaping ([String]?) -> Void) {
        
        let exportVideo = { [weak self] in
            self?.exportMultipleVideos(videoAssets, exportStarted: { [weak self] in
                self?.showProgressAlert(on: baseVC)
            }, completion: { [weak vc = baseVC] paths in
                // preventing crash for short video, with the controller that would attempt to dismiss while being presented
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(400)) {
                    vc?.dismiss(animated: true)
                }
                completion(paths)
            })
        }
        
        if ALApplozicSettings.is5MinVideoLimitInGalleryEnabled(), videoAssets.first(where: { $0.durationSeconds > 300 }) != nil {
            
            let message = NSLocalizedString("The video you’re attempting to send exceeds the 5 minutes limit. If you proceed, only a 5 minutes of the video will be selected and the rest will be trimmed out.", comment: "")
            let alertView = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alertView.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default, handler: { _ in
                exportVideo()
            }))
            alertView.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel, handler: { _ in
                completion(nil)
            }))
            baseVC.present(alertView, animated: true)
        } else {
            exportVideo()
        }
    }
}

// MARK: PRIVATE API
extension ALVideoCoder {
    
    private func showProgressAlert(on vc: UIViewController) {
        let alertView = UIAlertController(title: NSLocalizedString("Optimizing...", comment: ""), message: " ", preferredStyle: .alert)
        alertView.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel, handler: { [weak self] _ in
            self?.exportingVideoSessions.forEach { $0.cancelWriting() }
            self?.progressItems.removeAll()
            alertView.dismiss(animated: true) {
                self?.exportingVideoSessions.removeAll()
            }
        }))
        var mainProgress: Progress?
        if #available(iOS 9.0, *) {
            
            let totalDuration = progressItems.reduce(0) { $0 + $1.durationSeconds }
            mainProgress = Progress(totalUnitCount: Int64(totalDuration))
            
            for item in progressItems {
                mainProgress?.addChild(item.progress, withPendingUnitCount: Int64(item.durationSeconds))
            }
            self.mainProgress = mainProgress
        }
        
        vc.present(alertView, animated: true, completion: {
            if #available(iOS 9.0, *) {
                let margin: CGFloat = 8.0
                let rect = CGRect(x: margin, y: 62.0, width: alertView.view.frame.width - margin * 2.0, height: 2.0)
                let progressView = UIProgressView(frame: rect)
                progressView.observedProgress = mainProgress
                progressView.tintColor = UIColor.blue
                alertView.view.addSubview(progressView)
            }
        })
    }
    
    private func exportMultipleVideos(_ assets: [AssetSource], exportStarted: @escaping () -> Void, completion: @escaping ([String]) -> Void) {
        
        guard !assets.isEmpty else {
            completion([])
            return
        }
        
        let dispatchExportStartedGroup = DispatchGroup()
        let dispatchExportCompletedGroup = DispatchGroup()
        
        var videoPaths: [String] = []
        for video in assets {
            
            dispatchExportStartedGroup.enter()
            dispatchExportCompletedGroup.enter()
            exportVideoAsset(video, exportStarted: dispatchExportStartedGroup.leave(), completion: { path in
                if let videoPath = path {
                    videoPaths.append(videoPath)
                }
                dispatchExportCompletedGroup.leave()
            })
        }
        
        dispatchExportStartedGroup.notify(queue: .main, execute: exportStarted)
        dispatchExportCompletedGroup.notify(queue: .main) {
            completion(videoPaths)
        }
    }
    
    private func exportVideoAsset(_ asset: AssetSource, exportStarted: @autoclosure @escaping () -> Void, completion: @escaping (String?) -> Void) {
        let filename = String(format: "VID-%f.mp4", Date().timeIntervalSince1970*1000)
        let documentsUrl = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        
        let filePath = documentsUrl.absoluteString.appending(filename)
        guard var fileurl = URL(string: filePath) else {
            completion(nil)
            return
        }
        print("exporting video to ", fileurl)
        fileurl = fileurl.standardizedFileURL
        
        
        let options = PHVideoRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        
        // remove any existing file at that location
        do {
            try FileManager.default.removeItem(at: fileurl)
        }
        catch {
            // most likely, the file didn't exist.  Don't sweat it
        }
        
        asset.getAVAsset { [weak self] (asset) in
            guard let urlAsset = asset as? AVURLAsset else {
                exportStarted()
                completion(nil)
                return
            }
            
            var duratiomCMTime = urlAsset.duration
            if CMTimeGetSeconds(duratiomCMTime) > 300 {
                duratiomCMTime = CMTimeMakeWithSeconds(300, preferredTimescale: duratiomCMTime.timescale)
            }
            let range = CMTimeRangeMake(start: .zero, duration: duratiomCMTime)
            ALVideoCoder.convertVideoToLowQuailtyWithInputURL(inputURL: urlAsset.url, outputURL: fileurl, duration: range, started: { progress, writer in
                self?.exportingVideoSessions.append(writer)
                self?.progressItems.append(ProgressItem(progress: progress, durationSeconds: Int(CMTimeGetSeconds(duratiomCMTime))))
                exportStarted()
            }, completed: {
                completion(fileurl.path)
            })
        }
    }
    
    // video processing
    private class func convertVideoToLowQuailtyWithInputURL(inputURL: URL, outputURL: URL, duration: CMTimeRange, started: (Progress, AVAssetWriter) -> Void, completed: @escaping () -> Void) {
        //setup video writer
        let videoAsset = AVURLAsset(url: inputURL as URL, options: nil)
        let durationTime = Double(CMTimeGetSeconds(duration.duration))
        let progress = Progress(totalUnitCount: Int64(durationTime))
        
        let videoTrack = videoAsset.tracks(withMediaType: AVMediaType.video)[0]
        let videoSize = videoTrack.naturalSize
        
        let widthIsBigger = max(videoSize.height, videoSize.width) == videoSize.width
        let ratio = (widthIsBigger ? videoSize.height : videoSize.width) / 480.0
        
        let videoWriterCompressionSettings = [
            AVVideoAverageBitRateKey : 815_000
        ]
        
        let videoWriterSettings:[String : Any] = [
            AVVideoCodecKey : AVVideoCodecH264,
            AVVideoCompressionPropertiesKey : videoWriterCompressionSettings,
            AVVideoWidthKey : Int(videoSize.width/ratio),
            AVVideoHeightKey : Int(videoSize.height/ratio)
        ]
        
        
        let videoWriter = try! AVAssetWriter(outputURL: outputURL, fileType: .mov)
        
        let videoWriterInput = AVAssetWriterInput(mediaType: AVMediaType.video, outputSettings: videoWriterSettings)
        videoWriterInput.expectsMediaDataInRealTime = true
        videoWriterInput.transform = videoTrack.preferredTransform
        videoWriter.add(videoWriterInput)
        //setup video reader
        let videoReaderSettings:[String : Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        ]
        
        let videoReaderOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: videoReaderSettings)
        let videoReader = try! AVAssetReader(asset: videoAsset)
        videoReader.timeRange = duration
        videoReader.add(videoReaderOutput)
        //setup audio writer
        let audioWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
        audioWriterInput.expectsMediaDataInRealTime = false
        videoWriter.add(audioWriterInput)
        //setup audio reader
        let audioTrack = videoAsset.tracks(withMediaType: AVMediaType.audio)[0]
        let audioReaderOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
        let audioReader = try! AVAssetReader(asset: videoAsset)
        audioReader.timeRange = duration
        audioReader.add(audioReaderOutput)
        videoWriter.startWriting()
        
        //start writing from video reader
        videoReader.startReading()
        videoWriter.startSession(atSourceTime: CMTime.zero)
        let processingQueue = DispatchQueue(label: "processingQueue1")
        videoWriterInput.requestMediaDataWhenReady(on: processingQueue) {
            while videoWriterInput.isReadyForMoreMediaData {
                
                if let sampleBuffer = videoReaderOutput.copyNextSampleBuffer(), videoReader.status == .reading {
                    videoWriterInput.append(sampleBuffer)
                    let timeStamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                    progress.completedUnitCount = Int64(timeStamp)
                    NSLog("VIDEO: \(inputURL.lastPathComponent): \(Int(Double(timeStamp)*100/durationTime))")
                } else {
                    videoWriterInput.markAsFinished()
                    if videoReader.status == .completed {
                        //start writing from audio reader
                        audioReader.startReading()
                        videoWriter.startSession(atSourceTime: CMTime.zero)
                        let processingQueue = DispatchQueue(label: "processingQueue2")
                        audioWriterInput.requestMediaDataWhenReady(on: processingQueue) {
                            while audioWriterInput.isReadyForMoreMediaData {
                                
                                if let sampleBuffer = audioReaderOutput.copyNextSampleBuffer(), audioReader.status == .reading {
                                    audioWriterInput.append(sampleBuffer)
                                    //                                    let timeStamp = Double(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)))
                                    //                                    NSLog("AUDIO: \(timeStamp/durationTime)")
                                } else {
                                    audioWriterInput.markAsFinished()
                                    if audioReader.status == .completed {
                                        videoWriter.finishWriting {
                                            completed()
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        started(progress, videoWriter)
    }
}
