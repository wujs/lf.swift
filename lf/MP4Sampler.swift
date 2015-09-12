import Foundation

struct MP4SampleTable: CustomStringConvertible {
    var trak:MP4Box

    private var cursor:Int = 0

    var currentOffset:UInt64 {
        return UInt64(offset[cursor])
    }

    var currentIsKeyframe:Bool {
        return keyframe[cursor] != nil
    }

    var currentDuration:Double {
        return Double(totalTimeToSample) * 1000 / Double(timeScale)
    }

    var currentTimeToSample:Double {
        return Double(timeToSample[cursor]) * 1000 / Double(timeScale)
    }

    var currentSampleSize:Int {
        return Int((sampleSize.count == 1) ? sampleSize[0] : sampleSize[cursor])
    }

    var offset:[UInt32] = []
    var keyframe:[Int:Bool] = [:]
    var timeScale:UInt32 = 0
    var sampleSize:[UInt32] = []
    var timeToSample:[UInt32] = []
    var totalTimeToSample:UInt32 = 0

    var description:String {
        var description:String = "MP4SampleTable{"
        description += "offset:" + offset.description + ","
        description += "keyframe:" + keyframe.description + ","
        description += "timeScale:" + timeScale.description + ","
        description += "sampleSize:" + sampleSize.description + ","
        description += "timeToSample:" + timeToSample.description + "}"
        return description
    }

    init (trak:MP4Box) {
        
        self.trak = trak
        
        let mdhd:MP4Box? = trak.getBoxesByName("mdhd").first
        if let mdhd:MP4MediaHeaderBox = mdhd as? MP4MediaHeaderBox {
            timeScale = mdhd.timeScale
        }

        let stss:MP4Box? = trak.getBoxesByName("stss").first
        if let stss:MP4SyncSampleBox = stss as? MP4SyncSampleBox {
            var keyframes:[UInt32] = stss.entries
            for i in 0..<keyframes.count {
                keyframe[Int(keyframes[i])] = true
            }
        }

        let stts:MP4Box? = trak.getBoxesByName("stts").first
        if let stts:MP4TimeToSampleBox = stts as? MP4TimeToSampleBox {
            var timeToSample:[MP4TimeToSampleBox.Entry] = stts.entries
            for i in 0..<timeToSample.count {
                let entry:MP4TimeToSampleBox.Entry = timeToSample[i]
                for _ in 0..<entry.sampleCount {
                    self.timeToSample.append(entry.sampleDuration)
                }
            }
        }

        let stsz:MP4Box? = trak.getBoxesByName("stsz").first
        if let stsz:MP4SampleSizeBox = stsz as? MP4SampleSizeBox {
            sampleSize = stsz.entries
        }

        let stco:MP4Box = trak.getBoxesByName("stco").first!
        let stsc:MP4Box = trak.getBoxesByName("stsc").first!
        var offsets:[UInt32] = (stco as! MP4ChunkOffsetBox).entries
        var sampleToChunk:[MP4SampleToChunkBox.Entry] = (stsc as! MP4SampleToChunkBox).entries

        var index:Int = 0
        let count:Int = sampleToChunk.count

        for i in 0..<count {
            var j:Int = Int(sampleToChunk[i].firstChunk) - 1
            let m:Int = (i + 1 < count) ? Int(sampleToChunk[i + 1].firstChunk) - 1 : offsets.count
            for (; j < m; ++j) {
                var offset:UInt32 = offsets[j]
                for _ in 0..<sampleToChunk[i].samplesPerChunk {
                    self.offset.append(offset)
                    offset += sampleSize[index]
                    ++index
                }
            }
        }

        totalTimeToSample = timeToSample[cursor]
    }

    func hasNext() -> Bool {
        return cursor + 1 < offset.count
    }

    mutating func next() {
        ++cursor
        totalTimeToSample += timeToSample[cursor]
    }
}

class MP4Sampler: NSObject, MP4EncoderDelegate {
    var sampleTables:[MP4SampleTable] = []
    var currentFile:MP4File = MP4File()
    private let lockQueue:dispatch_queue_t = dispatch_queue_create("com.github.shogo4405.lf.MP4Sampler.lock", DISPATCH_QUEUE_SERIAL)

    func sampleOutput(index:Int, buffer:NSData, timestamp:Double, keyframe:Bool) {
    }

    func encoderOnFinishWriting(encoder:MP4Encoder, outputURL:NSURL) {
        doSampling(outputURL)
    }

    private func doSampling(url:NSURL) {

        currentFile.url = url
        currentFile.loadFile()

        var videoDuration:Double = 0
        if let mdhd:MP4MediaHeaderBox = currentFile.getBoxesByName("mdhd").first! as? MP4MediaHeaderBox {
            videoDuration = Double(mdhd.duration) / Double(mdhd.timeScale) * 1000
        }
 
        var sampleTables:[MP4SampleTable] = []
        var traks:[MP4Box] = currentFile.getBoxesByName("trak")
        for i in 0..<traks.count {
            sampleTables.append(MP4SampleTable(trak: traks[i]))
        }
        self.sampleTables = sampleTables

        var duration:Double = sampleTables.count == 1 ? videoDuration : 0
        repeat {
            for i in 0..<sampleTables.count {
                if i == 0 {
                    if (duration < sampleTables[i].currentDuration) {
                        continue
                    }
                } else {
                    duration = sampleTables[i].currentDuration
                    if (!sampleTables[i].hasNext()) {
                        duration = videoDuration
                        continue
                    }
                }
                autoreleasepool {
                    currentFile.seekToFileOffset(sampleTables[i].currentOffset)
                    sampleOutput(i,
                        buffer: currentFile.readDataOfLength(sampleTables[i].currentSampleSize),
                        timestamp: sampleTables[i].currentTimeToSample,
                        keyframe: sampleTables[i].currentIsKeyframe
                    )
                }

                sampleTables[i].next()
            }
        }
        while inLoop(sampleTables)
    
        currentFile.closeFile()
        do {
            try NSFileManager.defaultManager().removeItemAtURL(url)
        } catch _ {
        }
    }

    private func inLoop(sampleTables:[MP4SampleTable]) -> Bool{
        for i in sampleTables {
            if (i.hasNext()) {
                return true
            }
        }
        return false
    }
}
