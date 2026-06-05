/**
 * OpenAI Provider
 *
 * 使用 openai npm SDK 调用 OpenAI Chat Completions API。
 * apiEndpoint: https://api.openai.com/v1/chat/completions
 */

const OpenAI = require('openai');
const ProviderBase = require('../providerBase');
const logger = require('../../../utils/logger');

class OpenaiProvider extends ProviderBase {
  constructor({ apiKey }) {
    super({
      apiEndpoint: 'https://api.openai.com/v1/chat/completions',
      apiKey,
    });
    this.client = new OpenAI({ apiKey });
  }

  /**
   * 流式对话
   * @param {Array<object>} messages
   * @param {object} options
   * @returns {AsyncGenerator<string>}
   */
  async *chat(messages, options = {}) {
    const model = options.model || 'gpt-4o';

    try {
      const stream = await this.client.chat.completions.create({
        model,
        messages,
        stream: true,
        max_tokens: options.max_tokens || 4096,
        temperature: options.temperature !== undefined ? options.temperature : 0.7,
      });

      for await (const chunk of stream) {
        const content = chunk.choices?.[0]?.delta?.content;
        if (content) {
          yield content;
        }
      }
    } catch (err) {
      logger.error(`[OpenAI] 流式调用失败: ${err.message}`);
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
    const model = options.model || 'gpt-4o';

    try {
      const response = await this.client.chat.completions.create({
        model,
        messages,
        stream: false,
        max_tokens: options.max_tokens || 4096,
        temperature: options.temperature !== undefined ? options.temperature : 0.7,
      });

      return response.choices?.[0]?.message?.content || '';
    } catch (err) {
      logger.error(`[OpenAI] 同步调用失败: ${err.message}`);
      throw err;
    }
  }

  /**
   * Token 估算（使用 tiktoken 近似: chars/4）
   * @param {Array<object>} messages
   * @param {string} model
   * @returns {Promise<number>}
   */
  async countTokens(messages, model) {
    let totalChars = 0;
    for (const msg of messages) {
      totalChars += (msg.content || '').length;
      totalChars += (msg.role || '').length;
    }
    return Math.ceil(totalChars / 4);
  }

  /**
   * 返回支持的模型列表
   * @returns {Array<string>}
   */
  getModels() {
    return ['gpt-4o', 'gpt-4-turbo', 'gpt-3.5-turbo'];
  }
}

module.exports = OpenaiProvider;
