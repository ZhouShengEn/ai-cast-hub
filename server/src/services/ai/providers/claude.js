/**
 * Claude (Anthropic) Provider
 *
 * 使用 @anthropic-ai/sdk 调用 Anthropic Messages API。
 * 需要将 OpenAI 格式的 messages 转换为 Anthropic 格式。
 */

const Anthropic = require('@anthropic-ai/sdk');
const ProviderBase = require('../providerBase');
const logger = require('../../../utils/logger');

class ClaudeProvider extends ProviderBase {
  constructor({ apiKey }) {
    super({
      apiEndpoint: 'https://api.anthropic.com/v1/messages',
      apiKey,
    });
    this.client = new Anthropic({ apiKey });
  }

  /**
   * 将 OpenAI 格式消息转为 Anthropic 格式
   * @param {Array<object>} messages - [{role, content}]
   * @returns {{ system: string|null, messages: Array<object> }}
   */
  _convertMessages(messages) {
    let system = null;
    const converted = [];

    for (const msg of messages) {
      if (msg.role === 'system') {
        system = msg.content;
        continue;
      }
      converted.push({
        role: msg.role === 'assistant' ? 'assistant' : 'user',
        content: msg.content,
      });
    }

    return { system, messages: converted };
  }

  /**
   * 流式对话
   * @param {Array<object>} messages
   * @param {object} options
   * @returns {AsyncGenerator<string>}
   */
  async *chat(messages, options = {}) {
    const model = options.model || 'claude-3-5-sonnet-20241022';
    const { system, messages: convertedMessages } = this._convertMessages(messages);

    try {
      const stream = await this.client.messages.create({
        model,
        max_tokens: options.max_tokens || 4096,
        temperature: options.temperature !== undefined ? options.temperature : 0.7,
        system: system || undefined,
        messages: convertedMessages,
        stream: true,
      });

      for await (const event of stream) {
        if (
          event.type === 'content_block_delta' &&
          event.delta &&
          event.delta.type === 'text_delta' &&
          event.delta.text
        ) {
          yield event.delta.text;
        }
      }
    } catch (err) {
      logger.error(`[Claude] 流式调用失败: ${err.message}`);
      throw err;
    }
  }

  /**
   * 非流式对话
   * @param {Array<object>} messages
   * @param {object} options
   * @returns {Promise<string>}
   */
  async chatSync(messages, options = {}) {
    const model = options.model || 'claude-3-5-sonnet-20241022';
    const { system, messages: convertedMessages } = this._convertMessages(messages);

    try {
      const response = await this.client.messages.create({
        model,
        max_tokens: options.max_tokens || 4096,
        temperature: options.temperature !== undefined ? options.temperature : 0.7,
        system: system || undefined,
        messages: convertedMessages,
        stream: false,
      });

      // 提取文本内容
      const textBlocks = response.content.filter(block => block.type === 'text');
      return textBlocks.map(block => block.text).join('');
    } catch (err) {
      logger.error(`[Claude] 同步调用失败: ${err.message}`);
      throw err;
    }
  }

  /**
   * 使用 Anthropic API 精确计数 Token
   * @param {Array<object>} messages
   * @param {string} model
   * @returns {Promise<number>}
   */
  async countTokens(messages, model) {
    try {
      const { system, messages: convertedMessages } = this._convertMessages(messages);
      const result = await this.client.messages.countTokens({
        model: model || 'claude-3-5-sonnet-20241022',
        system: system || undefined,
        messages: convertedMessages,
      });
      return result.input_tokens;
    } catch {
      // 降级估算
      let totalChars = 0;
      for (const msg of messages) {
        totalChars += (msg.content || '').length;
      }
      return Math.ceil(totalChars / 4);
    }
  }

  /**
   * 返回支持的模型列表
   * @returns {Array<string>}
   */
  getModels() {
    return ['claude-3-5-sonnet-20241022', 'claude-3-opus-20240229'];
  }
}

module.exports = ClaudeProvider;
