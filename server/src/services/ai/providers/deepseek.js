/**
 * DeepSeek Provider
 *
 * 使用 openai npm SDK + 自定义 baseURL。
 * apiEndpoint: https://api.deepseek.com/v1/chat/completions
 */

const OpenAI = require('openai');
const ProviderBase = require('../providerBase');
const logger = require('../../../utils/logger');

class DeepSeekProvider extends ProviderBase {
  constructor({ apiKey }) {
    super({
      apiEndpoint: 'https://api.deepseek.com/v1/chat/completions',
      apiKey,
    });

    this.client = new OpenAI({
      apiKey,
      baseURL: 'https://api.deepseek.com/v1',
    });
  }

  /**
   * 流式对话
   */
  async *chat(messages, options = {}) {
    const model = options.model || 'deepseek-chat';

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
      logger.error(`[DeepSeek] 流式调用失败: ${err.message}`);
      throw err;
    }
  }

  /**
   * 非流式对话
   */
  async chatSync(messages, options = {}) {
    const model = options.model || 'deepseek-chat';

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
      logger.error(`[DeepSeek] 同步调用失败: ${err.message}`);
      throw err;
    }
  }

  getModels() {
    return ['deepseek-chat', 'deepseek-coder'];
  }
}

module.exports = DeepSeekProvider;
