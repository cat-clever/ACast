import ReplayKit

class SampleHandler: RPBroadcastSampleHandler {

    override func broadcastStarted(withSetupInfo setupInfo: [String : NSObject]?) {
        // 用户在控制中心启动屏幕广播
        NSLog("[ACast] 屏幕与音频广播推流已启动")
    }

    override func broadcastPaused() {
        // 投屏暂停
    }

    override func broadcastResumed() {
        // 投屏恢复
    }

    override func broadcastFinished() {
        // 投屏结束
        NSLog("[ACast] 屏幕广播推流已结束")
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case .video:
            // 处理视频帧 (经 VideoToolbox 硬件编码为 H.264 推流)
            break
        case .audioApp:
            // 处理系统内部播放声音样本
            break
        case .audioMic:
            // 处理麦克风声音
            break
        @unknown default:
            break
        }
    }
}
