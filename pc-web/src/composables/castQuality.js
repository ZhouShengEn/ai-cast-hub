/**
 * 投屏画质档位定义（Web → Flutter 共用语义）
 *
 * 每个档位包含目标分辨率、帧率、码率。Web 把这些参数通过 control 通道下发
 * `set_quality`，Flutter 端用 RTCRtpSender.setParameters 实时生效：
 *   - height  → 计算 scaleResolutionDownBy（编码端缩放，不打断投屏）
 *   - fps     → encodings[0].maxFramerate
 *   - bitrate → encodings[0].maxBitrate（bps）
 *
 * 顺序 QUALITY_ORDER 同时用于「弱网自动降级」：索引 +1 即降一档。
 */
export const QUALITY_PROFILES = {
  high: { label: '高清', width: 1920, height: 1080, fps: 30, bitrate: 4000000 },
  medium: { label: '流畅', width: 1280, height: 720, fps: 30, bitrate: 2000000 },
  low: { label: '省流', width: 854, height: 480, fps: 15, bitrate: 800000 },
}

/** 由高到低的档位顺序（也用于弱网自动降级） */
export const QUALITY_ORDER = ['high', 'medium', 'low']

export const DEFAULT_QUALITY = 'high'

export function getProfile(name) {
  return QUALITY_PROFILES[name] || QUALITY_PROFILES[DEFAULT_QUALITY]
}
