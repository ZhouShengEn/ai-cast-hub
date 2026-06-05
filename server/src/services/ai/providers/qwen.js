/**
 * 通义千问 (Qwen) Provider — 阿里云 DashScope
 *
 * 使用 openai npm SDK + 自定义 baseURL 调用阿里云兼容模式 API。
 * apiEndpoint: https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions
 */

const OpenAI = require('openai');
const ProviderBase = require('../providerBase');
const logger = require('../../../utils/logger');

class QwenProvider extends ProviderBase {
  constructor({ apiKey }) {
    super({
      apiEndpoint: 'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions',
      apiKey,
    });

    this.client = new OpenAI({
      apiKey,
      baseURL: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    });
  }

  buildHeaders() {
    return {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${this.apiKey}`,
      'X-DashScope-SSE': 'enable',
    };
  }

  /**
   * 流式对话
   */
  async *chat(messages, options = {}) {
    const model = options.model || 'qwen-plus';

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
      logger.error(`[Qwen] 流式调用失败: ${err.message}`);
      throw err;
    }
  }

  /**
   * 非流式对话
   */
  async chatSync(messages, options = {}) {
    const model = options.model || 'qwen-plus';

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
      logger.error(`[Qwen] 同步调用失败: ${err.message}`);
      throw err;
    }
  }

  getModels() {
    return ['qwen-plus', 'qwen-max', 'qwen-turbo', 'qwen-plus-latest'];
  }
}

module.exports = QwenProvider;
