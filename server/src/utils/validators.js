/**
 * Zod 请求校验 Schema
 *
 * 为各 API 端点提供输入数据校验规则
 */

const { z } = require('zod');

// ---- 设备注册 ----
const deviceRegisterSchema = z.object({
  deviceName: z.string().min(1, '设备名不能为空').max(50, '设备名最多50个字符'),
  platform: z.enum(['android', 'ios', 'web'], {
    errorMap: () => ({ message: '平台类型必须为 android/ios/web' }),
  }),
});

// ---- 对话发送 ----
const chatSendSchema = z.object({
  conversationId: z.string().optional(),
  content: z.string().min(1, '消息内容不能为空').max(10000, '消息内容最多10000个字符'),
  model: z.string().min(1, '模型标识不能为空'),
});

// ---- API Key ----
const apiKeySchema = z.object({
  provider: z.string().min(1, 'Provider 不能为空'),
  apiKey: z.string().min(1, 'API Key 不能为空'),
  label: z.string().optional(),
});

// ---- 文件传输 ----
const TWO_GB = 2 * 1024 * 1024 * 1024;

const fileTransferInitSchema = z.object({
  fileName: z.string().min(1, '文件名不能为空'),
  fileSize: z.number().int().positive().max(TWO_GB, '文件大小不能超过2GB'),
  checksum: z.string().min(1, '校验和不能为空'),
  targetDeviceId: z.string().min(1, '目标设备ID不能为空'),
});

module.exports = {
  deviceRegisterSchema,
  chatSendSchema,
  apiKeySchema,
  fileTransferInitSchema,
};
