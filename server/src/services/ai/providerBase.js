/**
 * AI Provider 基类 — OpenAI 兼容接口
 *
 * 子类通过继承并覆盖方法来实现不同厂商的 API 调用。
 * 默认实现适配 OpenAI 兼容 API 格式。
 */

const logger = require('../../utils/logger');

class ProviderBase {
  /**
   * @param {object} options
   * @param {string} options.apiEndpoint - API 端点 URL
   * @param {string} options.apiKey - API 密钥（明文）
   */
  constructor({ apiEndpoint, apiKey }) {
    this.apiEndpoint = apiEndpoint;
    this.apiKey = apiKey;
  }

  /**
   * 构建 HTTP 请求头
   * @returns {object} 请求头键值对
   */
  buildHeaders() {
    return {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${this.apiKey}`,
    };
  }

  /**
   * 构建标准 chat completions 请求体
   * @param {Array<object>} messages - 消息数组 [{role, content}]
   * @param {object} options - 可选参数 { model, stream, max_tokens, temperature }
   * @returns {object} 请求体
   */
  buildRequest(messages, options = {}) {
    return {
      model: options.model || 'gpt-3.5-turbo',
      messages,
      stream: options.stream !== false,
      max_tokens: options.max_tokens || 4096,
      temperature: options.temperature !== undefined ? options.temperature : 0.7,
    };
  }

  /**
   * 解析 SSE chunk，提取 delta.content
   * 子类可覆盖以适配不同的响应格式
   * @param {Buffer|string} chunkBuffer - SSE 数据块
   * @returns {string|null} 提取的 token 文本，或 null 表示结束/无内容
   */
  parseStreamChunk(chunkBuffer) {
    const text = chunkBuffer.toString().trim();

    // 标准 SSE data: 行
    if (!text.startsWith('data: ')) {
      return null;
    }

    const data = text.slice(6);

    // 流结束标志
    if (data === '[DONE]') {
      return null;
    }

    try {
      const parsed = JSON.parse(data);
      const content = parsed.choices?.[0]?.delta?.content;
      return content || null;
    } catch {
      return null;
    }
  }

  /**
   * 返回支持的模型列表
   * 子类必须覆盖此方法
   * @returns {Array<string>} 模型名称列表
   */
  getModels() {
    throw new Error('getModels() must be implemented by subclass');
  }

  /**
   * 流式对话（AsyncGenerator）
   * 子类必须覆盖此方法
   * @param {Array<object>} messages - 消息数组
   * @param {object} options - 可选参数
   * @returns {AsyncGenerator<string>} token 生成器
   */
  async *chat(messages, options = {}) {
    throw new Error('chat() must be implemented by subclass');
  }

  /**
   * 非流式对话
   * @param {Array<object>} messages - 消息数组
   * @param {object} options - 可选参数
   * @returns {Promise<string>} 完整响应内容
   */
  async chatSync(messages, options = {}) {
    const chunks = [];
    for await (const token of this.chat(messages, { ...options, stream: false })) {
      chunks.push(token);
    }
    return chunks.join('');
  }

  /**
   * 估算 Token 数量（子类可覆盖以提供精确计数）
   * @param {Array<object>} messages - 消息数组
   * @param {string} model - 模型名称
   * @returns {Promise<number>} 估算的 token 数
   */
  async countTokens(messages, model) {
    // 简单估算: 每个字符约 0.25 个 token
    let totalChars = 0;
    for (const msg of messages) {
      totalChars += (msg.content || '').length;
      totalChars += (msg.role || '').length;
    }
    return Math.ceil(totalChars / 4);
  }
}

module.exports = ProviderBase;
